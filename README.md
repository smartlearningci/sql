# 🧩 TPC-DS no Oracle 23c Free (Docker) — Guia Passo‑a‑Passo 100% Reprodutível

Este **README** documenta **todos os passos** (clicar/copiar/colar) para reproduzir o ambiente que montámos:
- VM Ubuntu (Azure) pronta para Oracle
- Docker + Python + DuckDB instalados
- Oracle 23c Free em Docker configurado
- Dados **TPC‑DS completos (24 tabelas)** gerados com DuckDB
- **CTAS completas** no Oracle com tipos corretos, PKs e estatísticas
- Validações e procedimentos de manutenção

Podes seguir **Opção A (Automática — script único)** ou **Opção B (Manual — passo a passo)**. Ambas conduzem ao mesmo resultado.

> ⚠️ Os ficheiros `.dat` **não** vão para o GitHub; são gerados localmente pelo processo.  

---

## 0) Pré‑requisitos e alvo

- Conta Azure (ou outro fornecedor) para criar uma **VM Ubuntu 22.04/24.04**.
- Acesso SSH à VM.
- No mínimo: **2 vCPU, 8 GB RAM, 25 GB disco** (recomendado 4 vCPU/12 GB/50 GB).

---

## 1) Criar VM no Azure (exemplo)

1. No portal Azure → **Create a resource** → **Virtual Machine**  
2. **Imagem**: *Ubuntu Server 22.04 LTS*  
3. **Tamanho**: *Standard B2ms* (2 vCPU, 8 GB RAM) ou superior  
4. **Autenticação**: SSH (recomendado)  
5. **Regras de porta de entrada** (NSG):  
   - `22/tcp` (SSH)
   - `1521/tcp` (Oracle)
   - `5500/tcp` (Oracle EM – opcional)
6. Criar a VM e apontar o **IP público**.

> Depois liga-te:
```bash
ssh azureuser@<IP_DA_VM>
```

---

## 2) Preparação inicial da VM (comandos obrigatórios)

> **Executar todos estes comandos, pela ordem listada.**

```bash
# 2.1 Atualizações e utilitários
sudo apt update && sudo apt -y upgrade
sudo apt -y install git curl wget unzip htop net-tools

# 2.2 Pasta persistente para dados do Oracle e TPC-DS
sudo mkdir -p /opt/oradata/tpcds_data
sudo chmod -R 777 /opt/oradata
```

---

## 3) Duas formas de instalar e carregar TPC‑DS

### ✅ Opção A — Automática (script único)

> Usa o ficheiro `tpcds_oracle_full.sh` deste repositório.  
> Faz **tudo**: Oracle + DuckDB + TPC‑DS + CTAS + validações.

```bash
# 3.A.1 Clonar repo e preparar
git clone https://github.com/<teu_utilizador>/<teu_repo>.git
cd <teu_repo>
chmod +x tpcds_oracle_full.sh

# 3.A.2 (Opcional) Definir variáveis
export SF=1                # fator de escala (1, 10, 50, 100...)
export ORACLE_PWD=SenhaForte_123
export TPCDS_USER=tpcds
export TPCDS_PWD=TPCDS_123
export ORADATA=/opt/oradata

# 3.A.3 Correr o script
./tpcds_oracle_full.sh
```

**O que acontece automaticamente**
1. Instala Docker/Python se faltarem
2. Arranca o container `gvenzl/oracle-free:23.5`
3. Cria o user `tpcds` e `TPCDS_DIR`
4. **Gera 24 ficheiros .dat** com DuckDB (`CALL dsdgen(sf=...)`)
5. Cria **tabelas externas planas** `ext_*_p`
6. Cria **24 CTAS completas** (todas as colunas e tipos corretos)
7. Cria PKs essenciais e recolhe estatísticas
8. Executa validações (contagens e query exemplo)

**Verificação imediata**
```bash
docker exec -i oracle23c sqlplus tpcds/TPCDS_123@//localhost/FREEPDB1 <<'SQL'
SET PAGES 100 LINES 200
SELECT COUNT(*) AS total_tabelas_nativas
FROM user_tables WHERE table_name NOT LIKE 'EXT_%';
SELECT COUNT(*) store_sales FROM store_sales;
SELECT COUNT(*) web_sales   FROM web_sales;
SELECT COUNT(*) catalog_sales FROM catalog_sales;
EXIT
SQL
```

---

### 🪜 Opção B — Manual (passo a passo exacto)

> Segue cuidadosamente. Cada bloco é para **copiar/colar**.

#### 3.B.1 Instalar Docker e Python

```bash
sudo apt -y install docker.io python3 python3-venv python3-pip
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
# termina a sessão SSH e volta a entrar
exit
# (reconectar)
ssh azureuser@<IP_DA_VM>
```

Criar e ativar venv do DuckDB:
```bash
python3 -m venv $HOME/venvs/duck
source $HOME/venvs/duck/bin/activate
pip install --upgrade pip duckdb
```

#### 3.B.2 Subir Oracle 23c Free em Docker

```bash
docker rm -f oracle23c 2>/dev/null || true
docker run -d --name oracle23c \
  -p 1521:1521 -p 5500:5500 \
  -e ORACLE_PASSWORD=SenhaForte_123 \
  -e ORACLE_CHARACTERSET=AL32UTF8 \
  -v /opt/oradata:/opt/oracle/oradata \
  gvenzl/oracle-free:23.5
```

Aguardar que esteja *healthy*:
```bash
until [ "$(docker inspect -f '{{.State.Health.Status}}' oracle23c)" = "healthy" ]; do
  sleep 5; echo -n "."
done
echo
```

#### 3.B.3 Criar utilizador e diretório no Oracle

```bash
docker exec -i oracle23c sqlplus system/SenhaForte_123@//localhost/FREEPDB1 <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER tpcds IDENTIFIED BY "TPCDS_123" QUOTA UNLIMITED ON USERS';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01920 THEN NULL; END IF; END;
/
GRANT CONNECT, RESOURCE, CREATE TABLE TO tpcds;
CREATE OR REPLACE DIRECTORY TPCDS_DIR AS '/opt/oracle/oradata/tpcds_data';
GRANT READ, WRITE ON DIRECTORY TPCDS_DIR TO tpcds;
EXIT
SQL
```

#### 3.B.4 Gerar os 24 `.dat` TPC‑DS com DuckDB

```bash
sudo mkdir -p /opt/oradata/tpcds_data && sudo chmod -R 777 /opt/oradata/tpcds_data
source $HOME/venvs/duck/bin/activate
python3 - <<'PY'
import duckdb, pathlib
outdir = pathlib.Path("/opt/oradata/tpcds_data"); outdir.mkdir(parents=True, exist_ok=True)
duckdb.sql("INSTALL tpcds;"); duckdb.sql("LOAD tpcds;")
duckdb.sql("CALL dsdgen(sf=1, schema='main', overwrite=true);")
tables = [
  "call_center","catalog_page","catalog_returns","catalog_sales","customer",
  "customer_address","customer_demographics","date_dim","household_demographics",
  "income_band","inventory","item","promotion","reason","ship_mode","store",
  "store_returns","store_sales","time_dim","warehouse","web_page","web_returns",
  "web_sales","web_site"
]
for t in tables:
    duckdb.sql(f"COPY {t} TO '{outdir}/{t}.dat' (FORMAT CSV, DELIMITER '|', HEADER false, NULL '');")
print("OK: 24 ficheiros .dat exportados para", outdir)
PY
```

Dar permissões para o utilizador `oracle` do container:
```bash
sudo chown -R 54321:54321 /opt/oradata/tpcds_data
sudo chmod -R 775 /opt/oradata/tpcds_data
```

#### 3.B.5 Criar **tabelas externas planas** + **CTAS completas**

> Nesta versão manual, vamos usar o **gerador de DDL** integrado no script (mas corrido à parte).  
> Gera as externas planas `ext_*_p` e as **24 CTAS completas** com tipos certos.

```bash
# Gerar DDL no host
python3 - <<'PY' > /opt/oradata/tpcds_data/ddl_tpcds.sql
import duckdb, os
tables = [
  "call_center","catalog_page","catalog_returns","catalog_sales","customer",
  "customer_address","customer_demographics","date_dim","household_demographics",
  "income_band","inventory","item","promotion","reason","ship_mode","store",
  "store_returns","store_sales","time_dim","warehouse","web_page","web_returns",
  "web_sales","web_site"
]
duckdb.sql("INSTALL tpcds;"); duckdb.sql("LOAD tpcds;")
duckdb.sql("CALL dsdgen(sf=1, schema='main', overwrite=true);")

def ora_cast(idx1, dtyp, name):
    c = f"c{idx1}"; dtyp=(dtyp or '').upper(); name=name.upper()
    if any(x in dtyp for x in ("DECIMAL","NUMERIC","INT","BIGINT","IDENTIFIER","DOUBLE")):
        return f"TO_NUMBER(NULLIF({c},'')) AS {name}"
    if "DATE" in dtyp:     return f"TO_DATE(NULLIF({c},''),'YYYY-MM-DD') AS {name}"
    if "TIMESTAMP" in dtyp:return f"TO_TIMESTAMP_NTZ(NULLIF({c},'')) AS {name}"
    return f"NULLIF({c},'') AS {name}"

def emit(s): print(s)

emit("SET ECHO ON FEEDBACK ON PAGES 100 LINES 200")
emit("WHENEVER SQLERROR EXIT SQL.SQLCODE")
emit("DECLARE PROCEDURE drop_if_exists(p VARCHAR2) IS BEGIN EXECUTE IMMEDIATE 'DROP TABLE '||p||' PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN NULL; END IF; END; BEGIN")
for t in tables:
    emit(f"  drop_if_exists('{t}'); drop_if_exists('ext_{t}_p');")
emit("END;"); emit("/"); emit("")

for t in tables:
    cols = duckdb.sql(f"PRAGMA table_info('{t}')").fetchall()
    n = len(cols)
    emit(f"-- {t}: externa plana ({n} colunas)")
    emit(f"CREATE TABLE ext_{t}_p (")
    emit(",\n".join([f"  c{i} VARCHAR2(4000)" for i in range(1, n+1)]))
    emit(") ORGANIZATION EXTERNAL (")
    emit("  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR")
    emit("  ACCESS PARAMETERS ( RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL (" + ",".join([f"c{i}" for i in range(1,n+1)]) + ") )")
    emit(f"  LOCATION ('{t}.dat') ) REJECT LIMIT UNLIMITED;"); emit("")
    select_list = [ora_cast(i, d, n) for i,(_cid,n,d,*_) in enumerate(cols,1)]
    emit(f"CREATE TABLE {t} NOLOGGING /*+ APPEND */ AS SELECT")
    emit("  " + ",\n  ".join(select_list))
    emit(f"FROM ext_{t}_p;"); emit("")

emit("BEGIN")
emit("  EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_date_dim ON date_dim(d_date_sk)';")
emit("  EXECUTE IMMEDIATE 'ALTER TABLE date_dim ADD CONSTRAINT pk_date_dim PRIMARY KEY (d_date_sk)';")
emit("EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END; /")
emit("BEGIN EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_item ON item(i_item_sk)'; EXECUTE IMMEDIATE 'ALTER TABLE item ADD CONSTRAINT pk_item PRIMARY KEY (i_item_sk)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END; /")
emit("BEGIN EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_customer ON customer(c_customer_sk)'; EXECUTE IMMEDIATE 'ALTER TABLE customer ADD CONSTRAINT pk_customer PRIMARY KEY (c_customer_sk)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END; /")
emit("BEGIN EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_store ON store(s_store_sk)'; EXECUTE IMMEDIATE 'ALTER TABLE store ADD CONSTRAINT pk_store PRIMARY KEY (s_store_sk)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END; /")
emit("BEGIN EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX pk_customer_address ON customer_address(ca_address_sk)'; EXECUTE IMMEDIATE 'ALTER TABLE customer_address ADD CONSTRAINT pk_customer_address PRIMARY KEY (ca_address_sk)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955,-2260) THEN NULL; END IF; END; /")
emit("BEGIN DBMS_STATS.GATHER_SCHEMA_STATS(USER); END; /")
PY

# Executar o DDL no Oracle
docker exec -i oracle23c bash -lc "sqlplus -s tpcds/TPCDS_123@//localhost/FREEPDB1 @/opt/oracle/oradata/tpcds_data/ddl_tpcds.sql"
```

#### 3.B.6 Validações finais

```bash
docker exec -i oracle23c sqlplus tpcds/TPCDS_123@//localhost/FREEPDB1 <<'SQL'
SET PAGES 100 LINES 200
SELECT COUNT(*) AS total_tabelas_nativas
FROM user_tables WHERE table_name NOT LIKE 'EXT_%';
SELECT 'STORE_SALES', (SELECT COUNT(*) FROM store_sales) FROM dual
UNION ALL SELECT 'WEB_SALES', (SELECT COUNT(*) FROM web_sales) FROM dual
UNION ALL SELECT 'CATALOG_SALES', (SELECT COUNT(*) FROM catalog_sales) FROM dual;
SELECT s.s_store_name, SUM(ss.ss_sales_price) AS total
FROM store_sales ss JOIN store s ON s.s_store_sk = ss.ss_store_sk
GROUP BY s.s_store_name ORDER BY total DESC FETCH FIRST 10 ROWS ONLY;
EXIT
SQL
```

---

## 4) Ligar‑se ao Oracle

| Parâmetro | Valor |
|---|---|
| Host | IP público da VM |
| Porta | 1521 |
| Service | FREEPDB1 |
| User | tpcds |
| Pass | TPCDS_123 |

Clientes compatíveis: SQL*Plus, SQL Developer, DBeaver, DataGrip.

---

## 5) Escalar dados (Scale Factor)

Para gerar mais linhas (ex.: 10×):

**Opção A (script):**
```bash
export SF=10
./tpcds_oracle_full.sh
```

**Opção B (manual):**
- Repetir a secção **3.B.4** (gerar `.dat` com `sf=10`) e **3.B.5** (recriar CTAS).

---

## 6) Manutenção, backup e limpeza

**Ver estado do container**
```bash
docker ps
docker inspect -f '{{.State.Health.Status}}' oracle23c
docker logs --tail 200 oracle23c
```

**Parar/Remover**
```bash
docker stop oracle23c
docker rm oracle23c
```

**Backup (Data Pump, dentro do container)**
```bash
docker exec -it oracle23c bash -lc "
  expdp tpcds/TPCDS_123@//localhost/FREEPDB1 schemas=TPCDS \
    directory=DATA_PUMP_DIR dumpfile=tpcds_%U.dmp logfile=tpcds_exp.log parallel=2
"
```

---

## 7) Gestão dos `.dat`

- Gerados em `/opt/oradata/tpcds_data/` (host) e montados em `/opt/oracle/oradata/tpcds_data` (container).
- **Não** subir para GitHub (ficheiros grandes).  
- Para partilhar:
```bash
sudo tar czvf tpcds_data_sf1.tar.gz /opt/oradata/tpcds_data
```

---

## 8) Resolução de problemas (erros reais que evitámos)

| Erro | Causa | Solução |
|---|---|---|
| `Catalog Error: dbgen_version does not exist` | Tabela não faz parte das 24 | Usar lista de 24 tabelas oficial (sem `dbgen_version`) |
| `ORA-01722` (invalid number) | Conversão de texto para número com valores vazios | Usar `NULLIF(cN,'')` antes de `TO_NUMBER(...)` (CTAS já inclui) |
| `ORA-29913` em externas | Permissões/UID dos ficheiros | `chown -R 54321:54321 /opt/oradata/tpcds_data` e `chmod 775` |
| `ORA-01031` | Falta de privilégios | `GRANT CREATE TABLE TO tpcds;` (já aplicado) |
| Sessão “presa” | Carga pesada a correr | Abrir nova shell; opcionalmente matar sessão via `v$session` |

---

## 9) Estrutura do repositório (recomendada)

```
.
├── README.md
├── tpcds_oracle_full.sh
├── .env.example
└── docs/  (opcional: exercícios SQL, screenshots, etc.)
```

---

## 10) Licença e créditos

Licença sugerida: **MIT**  
Autor: *(o teu nome/entidade)*  
Ano: 2025
