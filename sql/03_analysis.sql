CREATE VIEW v_monthly_sales AS
WITH lines_by_month AS (
    SELECT DATE_TRUNC('month', invoice_at)::date AS month, market, invoice_no,
           row_type, amount
    FROM v_lines
),
totals AS (
    SELECT
        month, COALESCE(market, 'All') AS market,
        COUNT(DISTINCT invoice_no) FILTER (WHERE row_type = 'sale') AS orders,
        COALESCE(SUM(amount) FILTER (WHERE row_type = 'sale'), 0) AS gross,
        COALESCE(SUM(amount) FILTER (WHERE row_type = 'credit'), 0) AS credits
    FROM lines_by_month
    GROUP BY GROUPING SETS ((month), (month, market))
),
with_previous_month AS (
    SELECT *,
           gross / NULLIF(orders, 0) AS avg_order,
           LAG(month) OVER monthly AS previous_month,
           LAG(gross) OVER monthly AS previous_gross,
           LAG(orders) OVER monthly AS previous_orders
    FROM totals
    WINDOW monthly AS (PARTITION BY market ORDER BY month)
)
SELECT
    month, market, orders, gross, credits, gross - credits AS net, avg_order,
    CASE WHEN previous_month = (month - INTERVAL '1 month')::date AND previous_orders > 0 AND orders > 0
         THEN gross - previous_gross END AS gross_change,
    CASE WHEN previous_month = (month - INTERVAL '1 month')::date AND previous_orders > 0 AND orders > 0
         THEN (orders - previous_orders) * (previous_gross / previous_orders) END AS order_effect,
    CASE WHEN previous_month = (month - INTERVAL '1 month')::date AND previous_orders > 0 AND orders > 0
         THEN orders * (avg_order - previous_gross / previous_orders) END AS basket_effect
FROM with_previous_month;

CREATE VIEW v_buyer_history AS
WITH ranked_orders AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_at, invoice_no) AS position
    FROM v_sale_orders
    WHERE customer_id IS NOT NULL
)
SELECT customer_id,
       MIN(order_at) AS first_order,
       MIN(order_at) FILTER (WHERE position = 2) AS second_order,
       MAX(order_at) AS last_order,
       COUNT(*) AS orders, SUM(gross) AS gross
FROM ranked_orders
GROUP BY customer_id;

CREATE VIEW v_retention AS
WITH cohorts AS (
    SELECT customer_id, DATE_TRUNC('month', first_order)::date AS cohort
    FROM v_buyer_history
),
sizes AS (
    SELECT cohort, COUNT(*) AS buyers FROM cohorts GROUP BY cohort
),
activity AS (
    SELECT cohorts.cohort, DATE_TRUNC('month', orders.order_at)::date AS activity_month,
           COUNT(DISTINCT orders.customer_id) AS active_buyers
    FROM v_sale_orders AS orders JOIN cohorts USING (customer_id)
    GROUP BY cohorts.cohort, DATE_TRUNC('month', orders.order_at)::date
),
grid AS (
    SELECT cohort, buyers, age,
           (cohort + age * INTERVAL '1 month')::date AS activity_month
    FROM sizes CROSS JOIN GENERATE_SERIES(0, 6) AS age
)
SELECT grid.cohort, grid.age, grid.buyers,
       CASE WHEN grid.activity_month < cutoff THEN COALESCE(activity.active_buyers, 0) END AS active_buyers,
       CASE WHEN grid.activity_month < cutoff
            THEN 100.0 * COALESCE(activity.active_buyers, 0) / grid.buyers END AS retention_pct
FROM grid CROSS JOIN v_period
LEFT JOIN activity USING (cohort, activity_month);

CREATE VIEW v_second_purchase AS
SELECT DATE_TRUNC('month', first_order)::date AS cohort,
       COUNT(*) AS buyers,
       COUNT(*) FILTER (WHERE first_order + INTERVAL '60 days' < cutoff) AS eligible,
       COUNT(*) FILTER (WHERE first_order + INTERVAL '60 days' < cutoff
                         AND second_order <= first_order + INTERVAL '60 days') AS returned
FROM v_buyer_history CROSS JOIN v_period
GROUP BY DATE_TRUNC('month', first_order)::date;

CREATE VIEW v_customer_segments AS
WITH segmented AS (
    SELECT *,
        CASE
            WHEN orders >= 3 AND cutoff - last_order::date <= 60 THEN 'Активные, 3+ заказа'
            WHEN orders = 2 AND cutoff - last_order::date <= 60 THEN 'Активные, 2 заказа'
            WHEN orders >= 2 THEN 'Повторные, без покупок свыше 60 дней'
            WHEN cutoff - last_order::date <= 60 THEN 'Одна недавняя покупка'
            ELSE 'Одна покупка свыше 60 дней назад'
        END AS segment
    FROM v_buyer_history CROSS JOIN v_period
)
SELECT segment, COUNT(*) AS buyers, SUM(orders) AS orders, SUM(gross) AS gross,
       ROUND(AVG(cutoff - last_order::date), 1) AS avg_days_since_order
FROM segmented GROUP BY segment;

CREATE VIEW v_products AS
WITH names AS (
    SELECT DISTINCT ON (stock_code) stock_code, description
    FROM v_lines
    WHERE row_type = 'sale' AND description IS NOT NULL
    GROUP BY stock_code, description
    ORDER BY stock_code, COUNT(*) DESC, description
),
totals AS (
    SELECT stock_code,
           COALESCE(SUM(amount) FILTER (WHERE row_type = 'sale'), 0) AS gross,
           COALESCE(SUM(amount) FILTER (WHERE row_type = 'credit'), 0) AS credits,
           COUNT(DISTINCT invoice_no) FILTER (WHERE row_type = 'credit') AS credit_notes
    FROM v_lines GROUP BY stock_code
)
SELECT stock_code, COALESCE(description, stock_code) AS product,
       gross, credits, gross - credits AS net, credit_notes,
       100.0 * credits / NULLIF(gross, 0) AS credit_pct
FROM totals LEFT JOIN names USING (stock_code);

CREATE VIEW v_product_priority AS
SELECT ROW_NUMBER() OVER (ORDER BY credits DESC, gross DESC, stock_code) AS priority,
       v_products.*
FROM v_products
WHERE gross >= 1000 AND credit_notes >= 5;

CREATE VIEW v_largest_product_documents AS
SELECT invoice_no, row_type, MIN(invoice_at) AS invoice_at,
       SUM(quantity) AS units, SUM(amount) AS amount
FROM v_lines
WHERE stock_code = (SELECT stock_code FROM v_product_priority WHERE priority = 1)
GROUP BY invoice_no, row_type;

CREATE VIEW v_summary AS
SELECT
    (SELECT COUNT(*) FROM raw_lines) AS source_rows,
    COUNT(*) AS analysis_rows,
    COUNT(*) FILTER (WHERE row_type = 'sale' AND customer_id IS NULL) AS sales_lines_without_id,
    COUNT(*) FILTER (WHERE row_type = 'sale') AS sales_lines,
    SUM(amount) FILTER (WHERE row_type = 'sale' AND customer_id IS NULL) AS sales_without_id,
    (SELECT COUNT(*) FROM v_sale_orders) AS orders,
    (SELECT COUNT(*) FROM v_buyer_history) AS buyers,
    (SELECT SUM(eligible) FROM v_second_purchase) AS eligible_60,
    (SELECT SUM(returned) FROM v_second_purchase) AS returned_60,
    SUM(amount) FILTER (WHERE row_type = 'sale') AS gross,
    SUM(amount) FILTER (WHERE row_type = 'credit') AS credits,
    SUM(CASE WHEN row_type = 'sale' THEN amount ELSE -amount END) AS net
FROM v_lines;
