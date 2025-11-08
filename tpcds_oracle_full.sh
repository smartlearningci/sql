#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Script: tpcds_oracle_full.sh
#  Descrição: Configura Oracle 23c Free (Docker) e carrega
#             todas as 24 tabelas TPC-DS completas via DuckDB.
# ============================================================

# ---------- CONFIG ----------
ORACLE_PWD="${ORACLE_PWD:-SenhaForte_123}"
TPCDS_USER="${TPCDS_USER:-tpcds}"
TPCDS_PWD="${TPCDS_PWD:-TPCDS_123}"
CONTAINER="${CONTAINER:-oracle23c}"
ORADATA="${ORADATA:-/opt/oradata}"
TPCDS_DIR_HOST="$ORADATA/tpcds_data"
TPCDS_DIR_CONT="/opt/oracle/oradata/tpcds_data"
DDL_HOST="$TPCDS_DIR_HOST/ddl_tpcds.sql"
DDL_CONT="$TPCDS_DIR_CONT/ddl_tpcds.sql"
SF="${SF:-1}"

echo "=== 🧩 TPC-DS → Oracle 23c Free ==="
echo "SF=$SF  |  CONTAINER=$CONTAINER  |  ORADATA=$ORADATA"
echo

# ---------- PRE-REQS ----------
if ! command -v docker >/dev/null 2>&1; then
  sudo apt update && sudo apt -y install docker.io
fi
if ! command -v python3 >/dev/null 2>&1; then
  sudo apt -y install python3 python3-venv python3-pip
fi

sudo mkdir -p "$TPCDS_DIR_HOST"
sudo chown -R "$(whoami)":"$(whoami)" "$ORADATA"
sudo chmod -R 777 "$ORADATA"

# ---------- ORACLE CONTAINER ----------
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  -p 1521:1521 -p 5500:5500 \
  -e ORACLE_PASSWORD="$ORACLE_PWD" \
  -e ORACLE_CHARACTERSET=AL32UTF8 \
  -v "$ORADATA":/opt/oracle/oradata \
  -v "$TPCDS_DIR_HOST":"$TPCDS_DIR_CONT" \
  gvenzl/oracle-free:23.5

echo -n "⏳ A aguardar Oracle ficar healthy"
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")" = "healthy" ]; do
  sleep 5; echo -n "."
done
echo

# ---------- USER & DIRECTORY ----------
docker exec -i "$CONTAINER" bash -lc "sqlplus -s system/$ORACLE_PWD@//localhost/FREEPDB1 <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER $TPCDS_USER IDENTIFIED BY \"$TPCDS_PWD\" QUOTA UNLIMITED ON USERS';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01920 THEN NULL; END IF; END;
/
GRANT CONNECT, RESOURCE, CREATE TABLE TO $TPCDS_USER;
CREATE OR REPLACE DIRECTORY TPCDS_DIR AS '$TPCDS_DIR_CONT';
GRANT READ, WRITE ON DIRECTORY TPCDS_DIR TO $TPCDS_USER;
EXIT
SQL"

# ---------- DUCKDB: GERAR 24 .dat ----------
if [ ! -d "$HOME/venvs/duck" ]; then
  python3 -m venv "$HOME/venvs/duck"
fi
# shellcheck disable=SC1091
source "$HOME/venvs/duck/bin/activate"
pip -q install --upgrade pip duckdb

python3 - <<PY
import duckdb, os, pathlib
sf = int(os.environ.get("SF","1"))
outdir = pathlib.Path("$TPCDS_DIR_HOST"); outdir.mkdir(parents=True, exist_ok=True)
duckdb.sql("INSTALL tpcds;")
duckdb.sql("LOAD tpcds;")
duckdb.sql(f"CALL dsdgen(sf={sf}, schema='main', overwrite=true);")
tables = [
  "call_center","catalog_page","catalog_returns","catalog_sales","customer",
  "customer_address","customer_demographics","date_dim","household_demographics",
  "income_band","inventory","item","promotion","reason","ship_mode","store",
  "store_returns","store_sales","time_dim","warehouse","web_page","web_returns",
  "web_sales","web_site"
]
for t in tables:
    duckdb.sql(f"COPY {t} TO '{outdir}/{t}.dat' (FORMAT CSV, DELIMITER '|', HEADER false, NULL '');")
print("Exportados", len(tables), "ficheiros .dat (SF =", sf, ")")
PY

sudo chown -R 54321:54321 "$TPCDS_DIR_HOST"
sudo chmod -R 775 "$TPCDS_DIR_HOST"

# ---------- GERAR DDL COMPLETO (externas planas + CTAS completas) ----------
python3 - <<'PY' > "$DDL_HOST"
import duckdb, os

tables = [
  "call_center","catalog_page","catalog_returns","catalog_sales","customer",
  "customer_address","customer_demographics","date_dim","household_demographics",
  "income_band","inventory","item","promotion","reason","ship_mode","store",
  "store_returns","store_sales","time_dim","warehouse","web_page","web_returns",
  "web_sales","web_site"
]

duckdb.sql("INSTALL tpcds;")
duckdb.sql("LOAD tpcds;")
sf = int(os.environ.get("SF","1"))
duckdb.sql(f"CALL dsdgen(sf={sf}, schema='main', overwrite=true);")

def ora_cast(idx1, dtyp, name):
    c = f"c{idx1}"
    dtyp = (dtyp or '').upper()
    name = name.upper()
    if any(x in dtyp for x in ("DECIMAL","NUMERIC","INT","BIGINT","IDENTIFIER","DOUBLE")):
        return f"TO_NUMBER(NULLIF({c},'')) AS {name}"
    if "DATE" in dtyp:
        return f"TO_DATE(NULLIF({c},''),'YYYY-MM-DD') AS {name}"
    if "TIMESTAMP" in dtyp:
        return f"TO_TIMESTAMP_NTZ(NULLIF({c},'')) AS {name}"
    return f"NULLIF({c},'') AS {name}"

def emit(s): print(s)

emit("SET ECHO ON FEEDBACK ON PAGES 100 LINES 200")
emit("WHENEVER SQLERROR EXIT SQL.SQLCODE")

emit(\"\"\"
DECLARE
  PROCEDURE drop_if_exists(p VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE '||p||' PURGE';
  EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN NULL; END IF; END;
BEGIN
\"\"\".lstrip())
for t in tables:
    emit(f"  drop_if_exists('{t}');")
    emit(f"  drop_if_exists('ext_{t}_p');")
emit("END;")
emit("/")
emit("")

for t in tables:
    cols = duckdb.sql(f"PRAGMA table_info('{t}')").fetchall()  # (cid, name, type, notnull, dflt_value, pk)
    n = len(cols)

    emit(f"-- === {t} : externa plana ({n} colunas) ===")
    emit(f"CREATE TABLE ext_{t}_p (")
    emit(",\\n".join([f"  c{i} VARCHAR2(4000)" for i in range(1, n+1)]))
    emit(")")
    emit("ORGANIZATION EXTERNAL (")
    emit("  TYPE ORACLE_LOADER")
    emit("  DEFAULT DIRECTORY TPCDS_DIR")
    emit("  ACCESS PARAMETERS (")
    emit("    RECORDS DELIMITED BY NEWLINE")
    emit("    FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL")
    emit("    (" + ",".join([f"c{i}" for i in range(1, n+1)]) + ")")
    emit("  )")
    emit(f"  LOCATION ('{t}.dat')")
    emit(") REJECT LIMIT UNLIMITED;")
    emit("")

    select_list = []
    for i, (_cid, name, dtyp, *_rest) in enumerate(cols, start=1):
        select_list.append(ora_cast(i, dtyp, name))
    emit(f"-- === {t} : CTAS completa ===")
    emit(f"CREATE TABLE {t} NOLOGGING /*+ APPEND */ AS")
    emit("SELECT")
    emit("  " + ",\\n  ".join(select_list))
    emit(f"FROM ext_{t}_p;")
    emit("")

emit(\"\"\"
BEGIN
  EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_date_dim ON date_dim(d_date_sk)';
  EXECUTE IMMEDIATE 'ALTER TABLE date_dim ADD CONSTRAINT pk_date_dim PRIMARY KEY (d_date_sk)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END;
/
BEGIN
  EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_item ON item(i_item_sk)';
  EXECUTE IMMEDIATE 'ALTER TABLE item ADD CONSTRAINT pk_item PRIMARY KEY (i_item_sk)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END;
/
BEGIN
  EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_customer ON customer(c_customer_sk)';
  EXECUTE IMMEDIATE 'ALTER TABLE customer ADD CONSTRAINT pk_customer PRIMARY KEY (c_customer_sk)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END;
/
BEGIN
  EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_store ON store(s_store_sk)';
  EXECUTE IMMEDIATE 'ALTER TABLE store ADD CONSTRAINT pk_store PRIMARY KEY (s_store_sk)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END;
/
BEGIN
  EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_customer_address ON customer_address(ca_address_sk)';
  EXECUTE IMMEDIATE 'ALTER TABLE customer_address ADD CONSTRAINT pk_customer_address PRIMARY KEY (ca_address_sk)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END;
/
BEGIN DBMS_STATS.GATHER_SCHEMA_STATS(USER); END;
/
\"\"\".lstrip())
PY

# ---------- EXECUTAR DDL NO ORACLE ----------
docker exec -i "$CONTAINER" bash -lc "sqlplus -s $TPCDS_USER/$TPCDS_PWD@//localhost/FREEPDB1 @$DDL_CONT"

# ---------- VALIDAÇÕES ----------
docker exec -i "$CONTAINER" bash -lc "sqlplus -s $TPCDS_USER/$TPCDS_PWD@//localhost/FREEPDB1 <<'SQL'
SET PAGES 100 LINES 200
PROMPT === Nº de tabelas nativas (esperado: 24) ===
SELECT COUNT(*) AS total FROM user_tables WHERE table_name NOT LIKE 'EXT_%';

PROMPT === Amostra de contagens ===
SELECT 'STORE_SALES',   (SELECT COUNT(*) FROM store_sales) FROM dual
UNION ALL SELECT 'WEB_SALES',     (SELECT COUNT(*) FROM web_sales) FROM dual
UNION ALL SELECT 'CATALOG_SALES', (SELECT COUNT(*) FROM catalog_sales) FROM dual;

PROMPT === Exemplo: Top 10 lojas ===
SELECT s.s_store_name, SUM(ss.ss_sales_price) AS total
FROM store_sales ss
JOIN store s ON s.s_store_sk = ss.ss_store_sk
GROUP BY s.s_store_name
ORDER BY total DESC
FETCH FIRST 10 ROWS ONLY;
EXIT
SQL"

echo
echo "✅ TPC-DS completo (24 tabelas) carregado no Oracle (SF=$SF)."
echo "   Liga-te: Host=<IP_VM> Porta=1521 Service=FREEPDB1  User=$TPCDS_USER  Pass=$TPCDS_PWD"
