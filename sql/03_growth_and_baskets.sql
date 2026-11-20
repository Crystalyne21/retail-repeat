-- Покупатель может перейти из первых заказов в повторные в течение одного месяца.
CREATE VIEW v_order_mix AS
WITH ranked_orders AS (
    SELECT invoice_no, order_at, customer_id, gross,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_at, invoice_no) AS order_number
    FROM v_sale_orders
),
classified_orders AS (
    SELECT DATE_TRUNC('month', order_at)::date AS month, gross,
           CASE
               WHEN customer_id IS NULL THEN 'unidentified'
               WHEN order_number = 1 THEN 'first'
               ELSE 'repeat'
           END AS order_type
    FROM ranked_orders
),
monthly_totals AS (
    SELECT month, order_type, COUNT(*) AS orders, SUM(gross) AS gross
    FROM classified_orders
    GROUP BY month, order_type
),
month_grid AS (
    SELECT month::date AS month, order_type
    FROM v_period
    CROSS JOIN LATERAL GENERATE_SERIES(start_date, cutoff - INTERVAL '1 month', INTERVAL '1 month') AS month
    CROSS JOIN (VALUES ('first'), ('repeat'), ('unidentified')) AS groups(order_type)
),
filled AS (
    SELECT month, order_type, COALESCE(orders, 0) AS orders, COALESCE(gross, 0) AS gross
    FROM month_grid LEFT JOIN monthly_totals USING (month, order_type)
)
SELECT month, order_type, orders, gross,
       100.0 * gross / NULLIF(SUM(gross) OVER (PARTITION BY month), 0) AS gross_share_pct,
       gross - LAG(gross) OVER (PARTITION BY order_type ORDER BY month) AS gross_change
FROM filled;

-- В корзине товар учитывается один раз, даже если он записан в нескольких строках.
-- Счета с одним товаром входят в знаменатель, хотя пары в них отсутствуют.
CREATE TABLE basket_items AS
WITH unique_items AS (
    SELECT DISTINCT invoice_no, stock_code FROM v_lines WHERE row_type = 'sale'
),
with_size AS (
    SELECT *, COUNT(*) OVER (PARTITION BY invoice_no) AS basket_size
    FROM unique_items
)
SELECT invoice_no, stock_code
FROM with_size WHERE basket_size <= 50;

ALTER TABLE basket_items ADD PRIMARY KEY (invoice_no, stock_code);
ANALYZE basket_items;

CREATE VIEW v_basket_coverage AS
SELECT (SELECT COUNT(*) FROM v_sale_orders) AS all_orders,
       COUNT(*) AS eligible_orders,
       COUNT(*) FILTER (WHERE items = 1) AS single_item_orders
FROM (
    SELECT invoice_no, COUNT(*) AS items FROM basket_items GROUP BY invoice_no
) AS eligible;

-- Сравнение кодов исключает пару товара с самим собой и обратный дубль.
CREATE TABLE basket_pair_counts AS
SELECT a.stock_code AS stock_a, b.stock_code AS stock_b, COUNT(*) AS together
FROM basket_items AS a
JOIN basket_items AS b ON a.invoice_no = b.invoice_no AND a.stock_code < b.stock_code
GROUP BY a.stock_code, b.stock_code
HAVING COUNT(*) >= 25;

ALTER TABLE basket_pair_counts ADD PRIMARY KEY (stock_a, stock_b);
ANALYZE basket_pair_counts;

CREATE VIEW v_basket_pairs AS
WITH item_orders AS (
    SELECT stock_code, COUNT(*) AS orders FROM basket_items GROUP BY stock_code
)
SELECT p.stock_a, p.stock_b, product_a.product AS product_a, product_b.product AS product_b,
       p.together, a.orders AS orders_a, b.orders AS orders_b, coverage.eligible_orders,
       100.0 * p.together / coverage.eligible_orders AS support_pct,
       100.0 * p.together / a.orders AS confidence_a_to_b_pct,
       100.0 * p.together / b.orders AS confidence_b_to_a_pct,
       1.0 * p.together * coverage.eligible_orders / (a.orders * b.orders) AS lift
FROM basket_pair_counts AS p
JOIN item_orders AS a ON a.stock_code = p.stock_a
JOIN item_orders AS b ON b.stock_code = p.stock_b
JOIN v_products AS product_a ON product_a.stock_code = p.stock_a
JOIN v_products AS product_b ON product_b.stock_code = p.stock_b
CROSS JOIN v_basket_coverage AS coverage;
