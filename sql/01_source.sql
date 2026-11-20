CREATE SCHEMA IF NOT EXISTS retail_repeat;
SET search_path TO retail_repeat, pg_catalog;

DROP VIEW IF EXISTS v_checks, v_basket_pairs, v_basket_coverage, v_order_mix,
    v_profile, v_summary, v_largest_product_documents,
    v_product_priority, v_products, v_customer_segments,
    v_second_purchase, v_retention, v_buyer_history, v_monthly_sales,
    v_cleaning, v_sale_orders, v_lines, v_period RESTRICT;
DROP TABLE IF EXISTS basket_pair_counts, basket_items, classified_lines, raw_lines RESTRICT;

CREATE TABLE raw_lines (
    line_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_no text,
    stock_code text,
    description text,
    quantity text,
    invoice_date text,
    unit_price text,
    customer_id text,
    country text
);

CREATE VIEW v_period AS
SELECT DATE '2010-12-01' AS start_date, DATE '2011-12-01' AS cutoff;
