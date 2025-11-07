#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURAÇÃO
# ──────────────────────────────────────────────────────────────────────────────
ORACLE_PASSWORD="SenhaForte_123"
ORACLE_USER="tpcds"
ORACLE_USER_PWD="TPCDS_123"
ORADATA_HOST_DIR="/opt/oradata"
TPCDS_DIR_HOST="${ORADATA_HOST_DIR}/tpcds_data"
CONTAINER_NAME="oracle23c"
PDB_SERVICE="FREEPDB1"

# ──────────────────────────────────────────────────────────────────────────────
# 1) PACOTES DE SISTEMA + DOCKER
# ──────────────────────────────────────────────────────────────────────────────
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release git build-essential python3-venv python3-pip

# Docker repo oficial
sudo install -m 0755 -d /etc/apt/keyrings || true
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# permitir Docker sem sudo (sair e voltar a entrar depois deste script, se necessário)
sudo usermod -aG docker "$USER" || true

# ──────────────────────────────────────────────────────────────────────────────
# 2) PASTAS DE DADOS
# ──────────────────────────────────────────────────────────────────────────────
sudo mkdir -p "$TPCDS_DIR_HOST"
sudo chmod -R 775 "$ORADATA_HOST_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# 3) ORACLE 23c FREE EM CONTAINER
# ──────────────────────────────────────────────────────────────────────────────
docker pull gvenzl/oracle-free:23-slim || true

# Se já existir, remove
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d --name "${CONTAINER_NAME}" \
  -p 1521:1521 -p 5500:5500 \
  -e ORACLE_PASSWORD="${ORACLE_PASSWORD}" \
  -e ORACLE_CHARACTERSET=AL32UTF8 \
  -v "${ORADATA_HOST_DIR}":/opt/oracle/oradata \
  --health-cmd="bash -lc '/opt/oracle/runOracle.sh status || exit 1'" \
  --health-interval=30s --health-timeout=20s --health-retries=20 \
  gvenzl/oracle-free:23-slim

echo "➡️ A aguardar a BD arrancar (isto pode demorar alguns minutos)..."
until [ "$(docker inspect -f '{{.State.Health.Status}}' ${CONTAINER_NAME})" = "healthy" ]; do
  sleep 10
  docker logs --tail 5 "${CONTAINER_NAME}" 2>/dev/null || true
done
echo "✅ Oracle está pronto."

# ──────────────────────────────────────────────────────────────────────────────
# 4) DUCKDB (venv) + GERAR TPC-DS SF=1
# ──────────────────────────────────────────────────────────────────────────────
python3 -m venv ~/venvs/duck
source ~/venvs/duck/bin/activate
pip install --upgrade pip
pip install duckdb

mkdir -p ~/tpcds_out

python - <<'PY'
import duckdb, os
outdir = os.path.expanduser("~/tpcds_out")
os.makedirs(outdir, exist_ok=True)
duckdb.sql("INSTALL tpcds;")
duckdb.sql("LOAD tpcds;")
duckdb.sql("CALL dsdgen(sf=1, schema='main', overwrite=true);")
tables = ["date_dim","customer","item","store_sales","store","customer_address","household_demographics","web_sales","catalog_sales"]
for t in tables:
    duckdb.sql(f"COPY {t} TO '{outdir}/{t}.dat' (FORMAT CSV, DELIMITER '|', HEADER false, NULL '');")
    print("Exportado:", f"{outdir}/{t}.dat")
PY

# mover para a pasta que o Oracle vê
sudo mv ~/tpcds_out/*.dat "${TPCDS_DIR_HOST}/"
# o utilizador do Oracle dentro do container tem UID 54321
sudo chown -R 54321:54321 "${TPCDS_DIR_HOST}"
sudo chmod -R 775 "${TPCDS_DIR_HOST}"

# ──────────────────────────────────────────────────────────────────────────────
# 5) CRIAR UTILIZADOR + DIRECTORY + CARREGAR TPC-DS (SF=1)
# ──────────────────────────────────────────────────────────────────────────────
cat > /tmp/load_tpcds.sql <<'SQL'
SET ECHO ON FEEDBACK ON PAGES 1000 LINES 200

-- utilizador e directory
BEGIN EXECUTE IMMEDIATE q'[CREATE USER tpcds IDENTIFIED BY "TPCDS_123" QUOTA UNLIMITED ON USERS]'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
GRANT CONNECT, RESOURCE TO tpcds;
CREATE OR REPLACE DIRECTORY TPCDS_DIR AS '/opt/oracle/oradata/tpcds_data';
GRANT READ, WRITE ON DIRECTORY TPCDS_DIR TO tpcds;

-- mudar para tpcds
CONN tpcds/"TPCDS_123"

-- === DATE_DIM ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_date_dim'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_date_dim (
  d_date_sk NUMBER, d_date_id VARCHAR2(16), d_date VARCHAR2(10),
  d_month_seq NUMBER, d_week_seq NUMBER, d_quarter_seq NUMBER, d_year NUMBER,
  d_dow NUMBER, d_moy NUMBER, d_dom NUMBER, d_qoy NUMBER,
  d_fy_year NUMBER, d_fy_quarter_seq NUMBER, d_fy_week_seq NUMBER,
  d_day_name VARCHAR2(9), d_quarter_name VARCHAR2(6),
  d_holiday VARCHAR2(1), d_weekend VARCHAR2(1), d_following_holiday VARCHAR2(1),
  d_first_dom NUMBER, d_last_dom NUMBER, d_same_day_ly NUMBER, d_same_day_lq NUMBER,
  d_current_day VARCHAR2(1), d_current_week VARCHAR2(1), d_current_month VARCHAR2(1),
  d_current_quarter VARCHAR2(1), d_current_year VARCHAR2(1)
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('date_dim.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE date_dim PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE date_dim NOLOGGING AS
SELECT d_date_sk, d_date_id, TO_DATE(d_date,'YYYY-MM-DD') AS d_date,
       d_month_seq, d_week_seq, d_quarter_seq, d_year,
       d_dow, d_moy, d_dom, d_qoy,
       d_fy_year, d_fy_quarter_seq, d_fy_week_seq,
       TRIM(d_day_name) d_day_name, TRIM(d_quarter_name) d_quarter_name,
       d_holiday, d_weekend, d_following_holiday,
       d_first_dom, d_last_dom, d_same_day_ly, d_same_day_lq,
       d_current_day, d_current_week, d_current_month, d_current_quarter, d_current_year
FROM ext_date_dim;

CREATE UNIQUE INDEX pk_date_dim ON date_dim(d_date_sk);
ALTER TABLE date_dim ADD CONSTRAINT pk_date_dim PRIMARY KEY (d_date_sk);

-- === CUSTOMER ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_customer'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_customer (
  c_customer_sk NUMBER, c_customer_id VARCHAR2(16),
  c_current_cdemo_sk NUMBER, c_current_hdemo_sk NUMBER, c_current_addr_sk NUMBER,
  c_first_shipto_date_sk NUMBER, c_first_sales_date_sk NUMBER,
  c_salutation VARCHAR2(10), c_first_name VARCHAR2(20), c_last_name VARCHAR2(30),
  c_preferred_cust_flag VARCHAR2(1), c_birth_day NUMBER, c_birth_month NUMBER, c_birth_year NUMBER,
  c_email_address VARCHAR2(50)
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('customer.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE customer PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE customer NOLOGGING AS
SELECT c_customer_sk, c_customer_id,
       c_current_cdemo_sk, c_current_hdemo_sk, c_current_addr_sk,
       c_first_shipto_date_sk, c_first_sales_date_sk,
       TRIM(c_salutation) c_salutation, TRIM(c_first_name) c_first_name,
       TRIM(c_last_name) c_last_name, c_preferred_cust_flag,
       c_birth_day, c_birth_month, c_birth_year, TRIM(c_email_address) c_email_address
FROM ext_customer;

CREATE UNIQUE INDEX pk_customer ON customer(c_customer_sk);
ALTER TABLE customer ADD CONSTRAINT pk_customer PRIMARY KEY (c_customer_sk);

-- === ITEM ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_item'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_item (
  i_item_sk NUMBER, i_item_id VARCHAR2(16),
  i_rec_start_date VARCHAR2(10), i_rec_end_date VARCHAR2(10),
  i_item_desc VARCHAR2(200),
  i_current_price VARCHAR2(20), i_wholesale_cost VARCHAR2(20),
  i_brand VARCHAR2(50), i_class VARCHAR2(50), i_category VARCHAR2(50), i_manufact VARCHAR2(50),
  i_size VARCHAR2(20), i_formulation VARCHAR2(20), i_color VARCHAR2(20), i_units VARCHAR2(10), i_container VARCHAR2(10)
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('item.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE item PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE item NOLOGGING AS
SELECT i_item_sk, TRIM(i_item_id) i_item_id,
       CASE WHEN i_rec_start_date IS NOT NULL THEN TO_DATE(i_rec_start_date,'YYYY-MM-DD') END AS i_rec_start_date,
       CASE WHEN i_rec_end_date   IS NOT NULL THEN TO_DATE(i_rec_end_date  ,'YYYY-MM-DD') END AS i_rec_end_date,
       TRIM(i_item_desc) i_item_desc,
       TO_NUMBER(i_current_price)  i_current_price,
       TO_NUMBER(i_wholesale_cost) i_wholesale_cost,
       TRIM(i_brand) i_brand, TRIM(i_class) i_class, TRIM(i_category) i_category, TRIM(i_manufact) i_manufact,
       TRIM(i_size) i_size, TRIM(i_formulation) i_formulation, TRIM(i_color) i_color, TRIM(i_units) i_units, TRIM(i_container) i_container
FROM ext_item;

CREATE UNIQUE INDEX pk_item ON item(i_item_sk);
ALTER TABLE item ADD CONSTRAINT pk_item PRIMARY KEY (i_item_sk);

-- === STORE_SALES ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_store_sales'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_store_sales (
  ss_sold_date_sk NUMBER, ss_sold_time_sk NUMBER, ss_item_sk NUMBER, ss_customer_sk NUMBER,
  ss_cdemo_sk NUMBER, ss_hdemo_sk NUMBER, ss_addr_sk NUMBER, ss_store_sk NUMBER, ss_promo_sk NUMBER,
  ss_ticket_number NUMBER, ss_quantity NUMBER,
  ss_wholesale_cost VARCHAR2(20), ss_list_price VARCHAR2(20), ss_sales_price VARCHAR2(20),
  ss_ext_discount_amt VARCHAR2(20), ss_ext_sales_price VARCHAR2(20), ss_ext_wholesale_cost VARCHAR2(20),
  ss_ext_list_price VARCHAR2(20), ss_ext_tax VARCHAR2(20), ss_coupon_amt VARCHAR2(20),
  ss_net_paid VARCHAR2(20), ss_net_paid_inc_tax VARCHAR2(20), ss_net_profit VARCHAR2(20)
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('store_sales.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE store_sales PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE store_sales NOLOGGING AS
SELECT ss_sold_date_sk, ss_item_sk, ss_customer_sk, ss_ticket_number, ss_quantity,
       TO_NUMBER(ss_sales_price) ss_sales_price,
       TO_NUMBER(ss_ext_discount_amt) ss_ext_discount_amt,
       TO_NUMBER(ss_ext_sales_price)  ss_ext_sales_price,
       TO_NUMBER(ss_net_profit)       ss_net_profit
FROM ext_store_sales;

CREATE INDEX ix_ss_item ON store_sales(ss_item_sk);
CREATE INDEX ix_ss_cust ON store_sales(ss_customer_sk);
CREATE INDEX ix_ss_date ON store_sales(ss_sold_date_sk);

-- === STORE ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_store'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_store (
  s_store_sk NUMBER, s_store_id VARCHAR2(16), s_store_name VARCHAR2(50),
  s_number_employees NUMBER, s_floor_space NUMBER, s_hours VARCHAR2(20),
  s_store_city VARCHAR2(60), s_store_county VARCHAR2(30), s_store_state VARCHAR2(2),
  s_store_zip VARCHAR2(10), s_store_country VARCHAR2(20), s_gmt_offset VARCHAR2(20)
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('store.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE store PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE store NOLOGGING AS
SELECT s_store_sk, TRIM(s_store_id) s_store_id, TRIM(s_store_name) s_store_name,
       s_number_employees, s_floor_space, TRIM(s_hours) s_hours,
       TRIM(s_store_city) s_store_city, TRIM(s_store_county) s_store_county, TRIM(s_store_state) s_store_state,
       TRIM(s_store_zip) s_store_zip, TRIM(s_store_country) s_store_country,
       TO_NUMBER(s_gmt_offset) s_gmt_offset
FROM ext_store;

CREATE UNIQUE INDEX pk_store ON store(s_store_sk);
ALTER TABLE store ADD CONSTRAINT pk_store PRIMARY KEY (s_store_sk);

-- === CUSTOMER_ADDRESS ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_customer_address'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_customer_address (
  ca_address_sk NUMBER, ca_address_id VARCHAR2(16),
  ca_street_number VARCHAR2(10), ca_street_name VARCHAR2(60), ca_street_type VARCHAR2(20),
  ca_suite_number VARCHAR2(10), ca_city VARCHAR2(60), ca_county VARCHAR2(30), ca_state VARCHAR2(2),
  ca_zip VARCHAR2(10), ca_country VARCHAR2(20), ca_gmt_offset VARCHAR2(20)
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('customer_address.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE customer_address PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE customer_address NOLOGGING AS
SELECT ca_address_sk, TRIM(ca_address_id) ca_address_id,
       TRIM(ca_street_number) ca_street_number, TRIM(ca_street_name) ca_street_name, TRIM(ca_street_type) ca_street_type,
       TRIM(ca_suite_number) ca_suite_number, TRIM(ca_city) ca_city, TRIM(ca_county) ca_county, TRIM(ca_state) ca_state,
       TRIM(ca_zip) ca_zip, TRIM(ca_country) ca_country, TO_NUMBER(ca_gmt_offset) ca_gmt_offset
FROM ext_customer_address;

CREATE UNIQUE INDEX pk_customer_address ON customer_address(ca_address_sk);
ALTER TABLE customer_address ADD CONSTRAINT pk_customer_address PRIMARY KEY (ca_address_sk);

-- === HOUSEHOLD_DEMOGRAPHICS ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_household_demographics'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_household_demographics (
  hd_demo_sk NUMBER, hd_income_band_sk NUMBER, hd_buy_potential VARCHAR2(20),
  hd_dep_count NUMBER, hd_vehicle_count NUMBER
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('household_demographics.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE household_demographics PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE household_demographics NOLOGGING AS
SELECT hd_demo_sk, hd_income_band_sk, TRIM(hd_buy_potential) hd_buy_potential,
       hd_dep_count, hd_vehicle_count
FROM ext_household_demographics;

CREATE UNIQUE INDEX pk_household_demographics ON household_demographics(hd_demo_sk);
ALTER TABLE household_demographics ADD CONSTRAINT pk_household_demographics PRIMARY KEY (hd_demo_sk);

-- === WEB_SALES ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_web_sales'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_web_sales (
  ws_sold_date_sk NUMBER, ws_item_sk NUMBER, ws_bill_customer_sk NUMBER, ws_order_number NUMBER,
  ws_quantity NUMBER, ws_sales_price VARCHAR2(20), ws_ext_discount_amt VARCHAR2(20),
  ws_ext_sales_price VARCHAR2(20), ws_net_profit VARCHAR2(20)
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('web_sales.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE web_sales PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE web_sales NOLOGGING AS
SELECT ws_sold_date_sk, ws_item_sk, ws_bill_customer_sk, ws_order_number, ws_quantity,
       TO_NUMBER(ws_sales_price) ws_sales_price,
       TO_NUMBER(ws_ext_discount_amt) ws_ext_discount_amt,
       TO_NUMBER(ws_ext_sales_price)  ws_ext_sales_price,
       TO_NUMBER(ws_net_profit)       ws_net_profit
FROM ext_web_sales;

CREATE INDEX ix_ws_item ON web_sales(ws_item_sk);
CREATE INDEX ix_ws_cust ON web_sales(ws_bill_customer_sk);
CREATE INDEX ix_ws_date ON web_sales(ws_sold_date_sk);

-- === CATALOG_SALES ===
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ext_catalog_sales'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ext_catalog_sales (
  cs_sold_date_sk NUMBER, cs_item_sk NUMBER, cs_bill_customer_sk NUMBER, cs_order_number NUMBER,
  cs_quantity NUMBER, cs_sales_price VARCHAR2(20), cs_ext_discount_amt VARCHAR2(20),
  cs_ext_sales_price VARCHAR2(20), cs_net_profit VARCHAR2(20)
) ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER DEFAULT DIRECTORY TPCDS_DIR
  ACCESS PARAMETERS (RECORDS DELIMITED BY NEWLINE FIELDS TERMINATED BY '|' MISSING FIELD VALUES ARE NULL)
  LOCATION ('catalog_sales.dat')
) REJECT LIMIT UNLIMITED;

BEGIN EXECUTE IMMEDIATE 'DROP TABLE catalog_sales PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE catalog_sales NOLOGGING AS
SELECT cs_sold_date_sk, cs_item_sk, cs_bill_customer_sk, cs_order_number, cs_quantity,
       TO_NUMBER(cs_sales_price) cs_sales_price,
       TO_NUMBER(cs_ext_discount_amt) cs_ext_discount_amt,
       TO_NUMBER(cs_ext_sales_price)  cs_ext_sales_price,
       TO_NUMBER(cs_net_profit)       cs_net_profit
FROM ext_catalog_sales;

CREATE INDEX ix_cs_item ON catalog_sales(cs_item_sk);
CREATE INDEX ix_cs_cust ON catalog_sales(cs_bill_customer_sk);
CREATE INDEX ix_cs_date ON catalog_sales(cs_sold_date_sk);

-- estatísticas para o otimizador
BEGIN DBMS_STATS.GATHER_SCHEMA_STATS(USER, ESTIMATE_PERCENT=>DBMS_STATS.AUTO_SAMPLE_SIZE); END;
/

PROMPT === ROW COUNTS (início) ===
SELECT 'DATE_DIM' t, COUNT(*) c FROM date_dim
UNION ALL SELECT 'CUSTOMER', COUNT(*) FROM customer
UNION ALL SELECT 'ITEM', COUNT(*) FROM item
UNION ALL SELECT 'STORE_SALES', COUNT(*) FROM store_sales
UNION ALL SELECT 'STORE', COUNT(*) FROM store
UNION ALL SELECT 'CUSTOMER_ADDRESS', COUNT(*) FROM customer_address
UNION ALL SELECT 'HOUSEHOLD_DEMOGRAPHICS', COUNT(*) FROM household_demographics
UNION ALL SELECT 'WEB_SALES', COUNT(*) FROM web_sales
UNION ALL SELECT 'CATALOG_SALES', COUNT(*) FROM catalog_sales;
SQL

docker exec -i "${CONTAINER_NAME}" sqlplus system/"${ORACLE_PASSWORD}"@//localhost/${PDB_SERVICE} @/tmp/load_tpcds.sql

echo "✅ Carga TPC-DS concluída."
echo "Agora podes ligar com DBeaver: host=<IP público VM> porta=1521 service=${PDB_SERVICE} user=${ORACLE_USER} pass=${ORACLE_USER_PWD}"
