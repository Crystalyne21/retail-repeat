-- line_id сохраняет позицию строки в CSV и помогает найти исключённые строки.
CREATE TABLE classified_lines AS
WITH normalized AS (
    SELECT
        line_id,
        UPPER(BTRIM(invoice_no)) AS invoice_no,
        UPPER(BTRIM(stock_code)) AS stock_code,
        NULLIF(BTRIM(description), '') AS description,
        CASE WHEN PG_INPUT_IS_VALID(BTRIM(quantity), 'integer')
             THEN BTRIM(quantity)::integer END AS quantity,
        CASE WHEN PG_INPUT_IS_VALID(BTRIM(invoice_date), 'timestamp without time zone')
             THEN BTRIM(invoice_date)::timestamp END AS invoice_at,
        CASE WHEN BTRIM(unit_price) ~ '^-?[0-9]+([.][0-9]+)?$'
             THEN BTRIM(unit_price)::numeric END AS unit_price,
        CASE WHEN BTRIM(customer_id) ~ '^[0-9]{5}([.]0+)?$'
             THEN SPLIT_PART(BTRIM(customer_id), '.', 1) END AS customer_id,
        COALESCE(NULLIF(BTRIM(country), ''), 'Unknown') AS country
    FROM raw_lines
),
flagged AS (
    SELECT
        normalized.*,
        ROW_NUMBER() OVER (
            PARTITION BY invoice_no, stock_code, description, quantity, invoice_at,
                         unit_price, customer_id, country
            ORDER BY line_id
        ) AS copy_number
    FROM normalized
)
SELECT
    flagged.*,
    CASE
        WHEN invoice_at IS NULL OR quantity IS NULL OR unit_price IS NULL
             OR COALESCE(stock_code, '') = '' THEN 'invalid'
        WHEN copy_number > 1 THEN 'duplicate'
        WHEN COALESCE(invoice_no, '') !~ '^C?[0-9]{6}$' THEN 'adjustment'
        WHEN stock_code !~ '^[0-9]{5}[A-Z0-9]*$' AND stock_code <> 'PADS' THEN 'service'
        WHEN unit_price <= 0 THEN 'nonpositive_price'
        WHEN invoice_no LIKE 'C%' AND quantity < 0 THEN 'credit'
        WHEN invoice_no NOT LIKE 'C%' AND quantity > 0 THEN 'sale'
        ELSE 'sign_mismatch'
    END AS row_type
FROM flagged;

ALTER TABLE classified_lines ADD PRIMARY KEY (line_id);
ANALYZE classified_lines;

CREATE VIEW v_cleaning AS
SELECT row_type, COUNT(*) AS rows
FROM classified_lines
GROUP BY row_type;

CREATE VIEW v_lines AS
SELECT
    line_id, invoice_no, stock_code, description, invoice_at, customer_id, country,
    CASE WHEN country = 'United Kingdom' THEN 'UK' ELSE 'Other' END AS market,
    quantity, unit_price, row_type, ABS(quantity::numeric * unit_price) AS amount
FROM classified_lines
CROSS JOIN v_period
WHERE row_type IN ('sale', 'credit')
  AND invoice_at >= start_date AND invoice_at < cutoff;

CREATE VIEW v_sale_orders AS
SELECT
    invoice_no,
    MIN(invoice_at) AS order_at,
    CASE WHEN COUNT(DISTINCT customer_id) = 1 THEN MIN(customer_id) END AS customer_id,
    SUM(amount) AS gross
FROM v_lines
WHERE row_type = 'sale'
GROUP BY invoice_no;
