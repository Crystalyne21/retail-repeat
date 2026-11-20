SET search_path TO retail_repeat, pg_catalog;

-- Какие строки вошли в анализ?
SELECT * FROM v_cleaning ORDER BY rows DESC;
SELECT * FROM v_profile;
SELECT * FROM v_checks ORDER BY name;

-- Где изменение продаж связано с числом покупок, а где со средним чеком?
SELECT month, market, orders, ROUND(gross, 2) AS gross_gbp, ROUND(credits, 2) AS credits_gbp,
       ROUND(avg_order, 2) AS avg_order_gbp, ROUND(gross_change, 2) AS gross_change_gbp,
       ROUND(order_effect, 2) AS order_effect_gbp, ROUND(basket_effect, 2) AS basket_effect_gbp
FROM v_monthly_sales
ORDER BY market, month;

-- Сколько наблюдаемых покупателей сделали второй заказ за 60 дней?
SELECT cohort, buyers, eligible, returned,
       ROUND(100.0 * returned / NULLIF(eligible, 0), 2) AS second_purchase_pct
FROM v_second_purchase
ORDER BY cohort;

-- Возвращались ли покупатели в соответствующий календарный месяц?
SELECT cohort, buyers, age AS month_after_first_purchase, active_buyers,
       ROUND(retention_pct, 2) AS retention_pct
FROM v_retention
ORDER BY cohort, age;

-- Сколько покупателей можно включить в гипотезу реактивации?
SELECT segment, buyers, orders, ROUND(gross, 2) AS gross_gbp, avg_days_since_order
FROM v_customer_segments
ORDER BY buyers DESC;

-- Какие товары проверить первыми по сумме кредит-нот?
SELECT priority, stock_code, product, ROUND(gross, 2) AS gross_gbp,
       ROUND(credits, 2) AS credits_gbp, credit_notes, ROUND(credit_pct, 2) AS credit_pct
FROM v_product_priority
WHERE priority <= 15
ORDER BY priority;

-- На чём держится рейтинг первого товара?
SELECT invoice_no, row_type, invoice_at, units, ROUND(amount, 2) AS amount_gbp
FROM v_largest_product_documents
ORDER BY amount DESC, invoice_no
LIMIT 8;

-- Как первые, повторные и неидентифицированные заказы внесли вклад в рост?
SELECT month, order_type, orders, ROUND(gross, 2) AS gross_gbp,
       ROUND(gross_share_pct, 2) AS share_pct, ROUND(gross_change, 2) AS gross_change_gbp
FROM v_order_mix
ORDER BY month, order_type;

-- Какие товары часто встречаются вместе и как часто покупают второй товар?
SELECT * FROM v_basket_coverage;
SELECT stock_a, stock_b, product_a, product_b, together,
       ROUND(support_pct, 2) AS support_pct,
       ROUND(confidence_a_to_b_pct, 2) AS a_to_b_pct,
       ROUND(confidence_b_to_a_pct, 2) AS b_to_a_pct, ROUND(lift, 2) AS lift
FROM v_basket_pairs
ORDER BY together DESC, lift DESC, stock_a, stock_b
LIMIT 15;
