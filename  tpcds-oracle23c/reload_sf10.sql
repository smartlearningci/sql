ALTER SESSION ENABLE PARALLEL DML;

TRUNCATE TABLE date_dim;
INSERT /*+ APPEND PARALLEL(4) */ INTO date_dim
SELECT d_date_sk, d_date_id, TO_DATE(d_date,'YYYY-MM-DD'), d_month_seq, d_week_seq, d_quarter_seq, d_year,
       d_dow, d_moy, d_dom, d_qoy, d_fy_year, d_fy_quarter_seq, d_fy_week_seq,
       TRIM(d_day_name), TRIM(d_quarter_name),
       d_holiday, d_weekend, d_following_holiday,
       d_first_dom, d_last_dom, d_same_day_ly, d_same_day_lq,
       d_current_day, d_current_week, d_current_month, d_current_quarter, d_current_year
FROM ext_date_dim;
COMMIT;

TRUNCATE TABLE customer;
INSERT /*+ APPEND PARALLEL(4) */ INTO customer
SELECT c_customer_sk, c_customer_id, c_current_cdemo_sk, c_current_hdemo_sk, c_current_addr_sk,
       c_first_shipto_date_sk, c_first_sales_date_sk,
       TRIM(c_salutation), TRIM(c_first_name), TRIM(c_last_name),
       c_preferred_cust_flag, c_birth_day, c_birth_month, c_birth_year, TRIM(c_email_address)
FROM ext_customer;
COMMIT;

TRUNCATE TABLE item;
INSERT /*+ APPEND PARALLEL(4) */ INTO item
SELECT i_item_sk, TRIM(i_item_id),
       CASE WHEN i_rec_start_date IS NOT NULL THEN TO_DATE(i_rec_start_date,'YYYY-MM-DD') END,
       CASE WHEN i_rec_end_date   IS NOT NULL THEN TO_DATE(i_rec_end_date  ,'YYYY-MM-DD') END,
       TRIM(i_item_desc), TO_NUMBER(i_current_price), TO_NUMBER(i_wholesale_cost),
       TRIM(i_brand), TRIM(i_class), TRIM(i_category), TRIM(i_manufact),
       TRIM(i_size), TRIM(i_formulation), TRIM(i_color), TRIM(i_units), TRIM(i_container)
FROM ext_item;
COMMIT;

TRUNCATE TABLE store_sales;
INSERT /*+ APPEND PARALLEL(4) */ INTO store_sales
SELECT ss_sold_date_sk, ss_item_sk, ss_customer_sk, ss_ticket_number, ss_quantity,
       TO_NUMBER(ss_sales_price), TO_NUMBER(ss_ext_discount_amt),
       TO_NUMBER(ss_ext_sales_price), TO_NUMBER(ss_net_profit)
FROM ext_store_sales;
COMMIT;

TRUNCATE TABLE store;
INSERT /*+ APPEND PARALLEL(4) */ INTO store
SELECT s_store_sk, TRIM(s_store_id), TRIM(s_store_name),
       s_number_employees, s_floor_space, TRIM(s_hours),
       TRIM(s_store_city), TRIM(s_store_county), TRIM(s_store_state), TRIM(s_store_zip),
       TRIM(s_store_country), TO_NUMBER(s_gmt_offset)
FROM ext_store;
COMMIT;

TRUNCATE TABLE customer_address;
INSERT /*+ APPEND PARALLEL(4) */ INTO customer_address
SELECT ca_address_sk, TRIM(ca_address_id), TRIM(ca_street_number), TRIM(ca_street_name), TRIM(ca_street_type),
       TRIM(ca_suite_number), TRIM(ca_city), TRIM(ca_county), TRIM(ca_state), TRIM(ca_zip),
       TRIM(ca_country), TO_NUMBER(ca_gmt_offset)
FROM ext_customer_address;
COMMIT;

TRUNCATE TABLE household_demographics;
INSERT /*+ APPEND PARALLEL(4) */ INTO household_demographics
SELECT hd_demo_sk, hd_income_band_sk, TRIM(hd_buy_potential), hd_dep_count, hd_vehicle_count
FROM ext_household_demographics;
COMMIT;

TRUNCATE TABLE web_sales;
INSERT /*+ APPEND PARALLEL(4) */ INTO web_sales
SELECT ws_sold_date_sk, ws_item_sk, ws_bill_customer_sk, ws_order_number, ws_quantity,
       TO_NUMBER(ws_sales_price), TO_NUMBER(ws_ext_discount_amt),
       TO_NUMBER(ws_ext_sales_price), TO_NUMBER(ws_net_profit)
FROM ext_web_sales;
COMMIT;

TRUNCATE TABLE catalog_sales;
INSERT /*+ APPEND PARALLEL(4) */ INTO catalog_sales
SELECT cs_sold_date_sk, cs_item_sk, cs_bill_customer_sk, cs_order_number, cs_quantity,
       TO_NUMBER(cs_sales_price), TO_NUMBER(cs_ext_discount_amt),
       TO_NUMBER(cs_ext_sales_price), TO_NUMBER(cs_net_profit)
FROM ext_catalog_sales;
COMMIT;

BEGIN DBMS_STATS.GATHER_SCHEMA_STATS(USER, ESTIMATE_PERCENT=>DBMS_STATS.AUTO_SAMPLE_SIZE); END;
/
