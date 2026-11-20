-- COPY через psql записывает выгрузки на компьютере, где запущен клиент.
\copy (SELECT * FROM v_cleaning ORDER BY rows DESC) TO 'cleaning.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_monthly_sales ORDER BY market, month) TO 'monthly_sales.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_retention ORDER BY cohort, age) TO 'retention.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_second_purchase ORDER BY cohort) TO 'second_purchase.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_customer_segments ORDER BY buyers DESC) TO 'customer_segments.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_product_priority ORDER BY priority) TO 'product_priority.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_largest_product_documents ORDER BY amount DESC, invoice_no LIMIT 8) TO 'product_documents.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_order_mix ORDER BY month, order_type) TO 'order_mix.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_basket_pairs ORDER BY together DESC, lift DESC, stock_a, stock_b) TO 'basket_pairs.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM v_checks ORDER BY name) TO 'checks.csv' WITH (FORMAT csv, HEADER true)

\o dashboard-data.json
WITH pairs AS MATERIALIZED (SELECT * FROM v_basket_pairs)
SELECT JSON_BUILD_OBJECT(
    'summary', (SELECT ROW_TO_JSON(s) FROM v_summary AS s),
    'profile', (SELECT ROW_TO_JSON(p) FROM v_profile AS p),
    'cleaning', (SELECT JSON_AGG(c ORDER BY rows DESC) FROM v_cleaning AS c),
    'monthly', (SELECT JSON_AGG(m ORDER BY market, month) FROM v_monthly_sales AS m),
    'retention', (SELECT JSON_AGG(r ORDER BY cohort, age) FROM v_retention AS r),
    'second_purchase', (SELECT JSON_AGG(b ORDER BY cohort) FROM v_second_purchase AS b),
    'segments', (SELECT JSON_AGG(s ORDER BY buyers DESC) FROM v_customer_segments AS s),
    'priority', (SELECT JSON_AGG(p ORDER BY priority) FROM (
        SELECT * FROM v_product_priority WHERE priority <= 15
    ) AS p),
    'documents', (SELECT JSON_AGG(d ORDER BY amount DESC, invoice_no) FROM (
        SELECT * FROM v_largest_product_documents ORDER BY amount DESC, invoice_no LIMIT 8
    ) AS d),
    'order_mix', (SELECT JSON_AGG(m ORDER BY month, order_type) FROM v_order_mix AS m),
    'basket_coverage', (SELECT ROW_TO_JSON(b) FROM v_basket_coverage AS b),
    'pairs_by_orders', (SELECT JSON_AGG(p ORDER BY together DESC, lift DESC, stock_a, stock_b) FROM (
        SELECT * FROM pairs ORDER BY together DESC, lift DESC, stock_a, stock_b LIMIT 15
    ) AS p),
    'pairs_by_lift', (SELECT JSON_AGG(p ORDER BY lift DESC, together DESC, stock_a, stock_b) FROM (
        SELECT * FROM pairs ORDER BY lift DESC, together DESC, stock_a, stock_b LIMIT 15
    ) AS p),
    'top_products', (SELECT JSON_AGG(p ORDER BY gross DESC, stock_code) FROM (
        SELECT * FROM v_products ORDER BY gross DESC, stock_code LIMIT 15
    ) AS p)
);
\o
