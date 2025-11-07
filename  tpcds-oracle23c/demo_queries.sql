-- Ativar estatísticas na sessão (para planos com ALLSTATS)
ALTER SESSION SET statistics_level = ALL;

-- Query 1: top categorias por canal e ano
SELECT /*+ parallel(4) */ ch, d.d_year, i.i_category, SUM(amount) total_amount
FROM (
  SELECT /*+ parallel(4) */ 'STORE' ch, ss.ss_sold_date_sk sold_date_sk, ss.ss_item_sk item_sk, ss.ss_ext_sales_price amount FROM store_sales ss
  UNION ALL
  SELECT /*+ parallel(4) */ 'WEB'   , ws.ws_sold_date_sk, ws.ws_item_sk, ws.ws_ext_sales_price FROM web_sales ws
  UNION ALL
  SELECT /*+ parallel(4) */ 'CATALOG', cs.cs_sold_date_sk, cs.cs_item_sk, cs.cs_ext_sales_price FROM catalog_sales cs
) u
JOIN date_dim d ON d.d_date_sk = u.sold_date_sk
JOIN item i     ON i.i_item_sk = u.item_sk
WHERE d.d_year BETWEEN 2001 AND 2002
GROUP BY ch, d.d_year, i.i_category
ORDER BY d.d_year, ch, total_amount DESC
FETCH FIRST 50 ROWS ONLY;

-- Plano real do cursor
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST +ALIAS'));

-- Query 2: heavy spenders (ranking)
SELECT /*+ parallel(4) */ *
FROM (
  SELECT c.c_customer_sk, c.c_last_name,
         SUM(ss.ss_ext_sales_price) AS total_spend,
         RANK() OVER (ORDER BY SUM(ss.ss_ext_sales_price) DESC) AS rnk
  FROM store_sales ss
  JOIN customer c ON c.c_customer_sk = ss.ss_customer_sk
  JOIN date_dim d ON d.d_date_sk = ss.ss_sold_date_sk
  WHERE d.d_year = 2002
  GROUP BY c.c_customer_sk, c.c_last_name
) t
WHERE rnk <= 100;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST +ALIAS'));
