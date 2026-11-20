CREATE VIEW v_profile AS
SELECT
    COUNT(*) AS source_rows,
    COUNT(*) FILTER (WHERE customer_id IS NULL) AS source_rows_without_id,
    COUNT(*) FILTER (WHERE description IS NULL) AS source_rows_without_description,
    COUNT(*) FILTER (WHERE copy_number > 1) AS potential_duplicate_rows,
    MIN(invoice_at)::date AS first_date,
    MAX(invoice_at)::date AS last_date,
    COUNT(*) FILTER (WHERE row_type IN ('sale', 'credit')
                      AND (invoice_at < start_date OR invoice_at >= cutoff)) AS outside_period_rows,
    SUM(quantity * unit_price) FILTER (
        WHERE row_type = 'duplicate' AND quantity > 0 AND unit_price > 0
          AND invoice_no ~ '^[0-9]{6}$'
          AND (stock_code ~ '^[0-9]{5}[A-Z0-9]*$' OR stock_code = 'PADS')
          AND invoice_at >= start_date AND invoice_at < cutoff
    ) AS potential_duplicate_gross
FROM classified_lines CROSS JOIN v_period;

CREATE VIEW v_checks AS
WITH s AS (SELECT * FROM v_summary)
SELECT name, ok IS TRUE AS ok
FROM (
    SELECT 'source_row_count' AS name, source_rows = 541909 AS ok FROM s
    UNION ALL
    SELECT 'all_rows_classified', source_rows = (SELECT SUM(rows) FROM v_cleaning) FROM s
    UNION ALL
    SELECT 'audit_to_analysis', analysis_rows + outside_period_rows =
        (SELECT SUM(rows) FROM v_cleaning WHERE row_type IN ('sale', 'credit'))
    FROM v_profile CROSS JOIN s
    UNION ALL
    SELECT 'valid_line_amounts', NOT EXISTS (SELECT 1 FROM v_lines WHERE amount <= 0)
    UNION ALL
    SELECT 'sales_have_correct_sign', NOT EXISTS (
        SELECT 1 FROM v_lines WHERE (row_type = 'sale') <> (quantity > 0)
    )
    UNION ALL
    SELECT 'invoice_totals_match_sales', gross = (SELECT SUM(gross) FROM v_sale_orders) FROM s
    UNION ALL
    SELECT 'no_duplicate_clean_lines', NOT EXISTS (
        SELECT 1 FROM v_lines JOIN classified_lines USING (line_id) WHERE copy_number > 1
    )
    UNION ALL
    SELECT 'monthly_period_complete', COUNT(*) = 12 FROM v_monthly_sales WHERE market = 'All'
    UNION ALL
    SELECT 'monthly_total_matches',
        gross = (SELECT SUM(gross) FROM v_monthly_sales WHERE market = 'All')
        AND credits = (SELECT SUM(credits) FROM v_monthly_sales WHERE market = 'All') FROM s
    UNION ALL
    SELECT 'change_decomposition', NOT EXISTS (
        SELECT 1 FROM v_monthly_sales WHERE ABS(gross_change - order_effect - basket_effect) > 0.01
    )
    UNION ALL
    SELECT 'product_totals_match', net = (SELECT SUM(net) FROM v_products) FROM s
    UNION ALL
    SELECT 'cohort_start', NOT EXISTS (
        SELECT 1 FROM v_retention WHERE age = 0 AND active_buyers IS DISTINCT FROM buyers
    )
    UNION ALL
    SELECT 'no_unobservable_retention', NOT EXISTS (
        SELECT 1 FROM v_retention CROSS JOIN v_period
        WHERE (cohort + age * INTERVAL '1 month' >= cutoff) <> (active_buyers IS NULL)
           OR active_buyers > buyers
    )
    UNION ALL
    SELECT 'second_purchase_bounds', NOT EXISTS (
        SELECT 1 FROM v_second_purchase WHERE returned > eligible OR eligible > buyers
    )
    UNION ALL
    SELECT 'segments_match_known_buyers', buyers = (SELECT SUM(buyers) FROM v_customer_segments) FROM s
    UNION ALL
    SELECT 'order_mix_reconciles_by_month', NOT EXISTS (
        SELECT 1
        FROM (SELECT month, SUM(orders) AS orders, SUM(gross) AS gross
              FROM v_order_mix GROUP BY month) AS mix
        FULL JOIN (SELECT month, orders, gross FROM v_monthly_sales WHERE market = 'All') AS sales
            USING (month)
        WHERE mix.orders IS DISTINCT FROM sales.orders OR mix.gross IS DISTINCT FROM sales.gross
    )
    UNION ALL
    SELECT 'first_orders_match_buyers', buyers =
        (SELECT SUM(orders) FROM v_order_mix WHERE order_type = 'first') FROM s
    UNION ALL
    SELECT 'order_mix_changes_reconcile', NOT EXISTS (
        SELECT 1 FROM (SELECT month, SUM(gross_change) AS gross_change FROM v_order_mix GROUP BY month) AS mix
        JOIN v_monthly_sales AS sales USING (month)
        WHERE sales.market = 'All' AND mix.gross_change IS DISTINCT FROM sales.gross_change
    )
    UNION ALL
    SELECT 'basket_coverage_is_valid',
           eligible_orders > 0 AND single_item_orders <= eligible_orders AND eligible_orders <= all_orders
    FROM v_basket_coverage
    UNION ALL
    SELECT 'basket_size_at_most_50', NOT EXISTS (
        SELECT invoice_no FROM basket_items GROUP BY invoice_no HAVING COUNT(*) > 50
    )
    UNION ALL
    SELECT 'pair_counts_fit_margins', NOT EXISTS (
        SELECT 1 FROM v_basket_pairs
        WHERE stock_a >= stock_b OR together < 25 OR together > LEAST(orders_a, orders_b)
           OR GREATEST(orders_a, orders_b) > eligible_orders
           OR lift <= 0 OR support_pct > 100
    )
) AS checks;

DO $$
DECLARE failed_checks text;
BEGIN
    SELECT STRING_AGG(name, ', ' ORDER BY name) INTO failed_checks FROM v_checks WHERE NOT ok;
    IF failed_checks IS NOT NULL THEN
        RAISE EXCEPTION 'Не пройдены проверки %', failed_checks;
    END IF;
END;
$$;
