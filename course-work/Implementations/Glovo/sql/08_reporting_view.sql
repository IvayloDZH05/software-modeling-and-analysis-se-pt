-- Glovo coursework / PostgreSQL 18
-- Run after 07_dw_load.sql. This view reads only the analytical schema dw.
-- Grain: exactly one row per order, including cancelled orders.
-- Aggregate items/payments BEFORE joining the facts to avoid double counting.
-- completed_order_value_eur is customer order value, not Glovo's own revenue
-- or profit: the source model does not contain commission or cost data.

BEGIN;

CREATE OR REPLACE VIEW dw.vw_bi_orders AS
WITH item_totals AS (
    SELECT
        order_id,
        order_date_key,
        customer_key,
        restaurant_key,
        location_key,
        order_status,
        COUNT(*)::INTEGER AS item_line_count,
        SUM(quantity)::BIGINT AS total_quantity,
        SUM(item_amount) AS ordered_food_value_eur
    FROM dw.fact_order_items
    GROUP BY
        order_id, order_date_key, customer_key,
        restaurant_key, location_key, order_status
),
payment_totals AS (
    SELECT
        order_id,
        SUM(successful_amount) AS collected_payments_eur,
        COUNT(*) FILTER (
            WHERE payment_status = 'successful'
        )::INTEGER AS successful_payment_count,
        COUNT(*) FILTER (
            WHERE payment_status = 'failed'
        )::INTEGER AS failed_payment_count,
        COUNT(*) FILTER (
            WHERE payment_status = 'pending'
        )::INTEGER AS pending_payment_count
    FROM dw.fact_payments
    GROUP BY order_id
)
SELECT
    i.order_id,
    dt.full_date AS order_date,
    date_trunc('month', dt.full_date::TIMESTAMP)::DATE AS order_month,
    dt.year AS order_year,
    dt.month AS order_month_number,
    dt.month_name AS order_month_name,
    i.order_status,
    cu.customer_id,
    r.restaurant_id,
    r.name AS restaurant_name,
    l.city,
    COALESCE(l.district, 'Unknown') AS district,
    COALESCE(d.delivery_status, 'no_delivery') AS delivery_status,
    COALESCE(c.courier_id::TEXT, 'unassigned') AS courier_id,
    CASE WHEN c.courier_id IS NULL THEN 'Unassigned'
         ELSE c.first_name || ' ' || c.last_name
    END AS courier_name,
    i.item_line_count,
    i.total_quantity,
    i.ordered_food_value_eur,
    CASE WHEN i.order_status = 'delivered'
        THEN i.ordered_food_value_eur ELSE 0
    END AS completed_food_sales_eur,
    CASE WHEN i.order_status = 'delivered'
              AND d.delivery_status = 'delivered'
        THEN d.delivery_fee ELSE 0
    END AS completed_delivery_fees_eur,
    CASE WHEN i.order_status = 'delivered'
        THEN i.ordered_food_value_eur
             + CASE WHEN d.delivery_status = 'delivered'
                    THEN d.delivery_fee ELSE 0 END
        ELSE 0
    END AS completed_order_value_eur,
    COALESCE(p.collected_payments_eur, 0) AS collected_payments_eur,
    COALESCE(p.successful_payment_count, 0) AS successful_payment_count,
    COALESCE(p.failed_payment_count, 0) AS failed_payment_count,
    COALESCE(p.pending_payment_count, 0) AS pending_payment_count,
    CASE WHEN i.order_status = 'delivered' THEN 1 ELSE 0 END AS delivered_order_count,
    CASE WHEN i.order_status = 'cancelled' THEN 1 ELSE 0 END AS cancelled_order_count,
    d.delivery_minutes,
    d.estimated_minutes
FROM item_totals i
JOIN dw.dim_date dt ON dt.date_key = i.order_date_key
JOIN dw.dim_customer cu ON cu.customer_key = i.customer_key
JOIN dw.dim_restaurant r ON r.restaurant_key = i.restaurant_key
JOIN dw.dim_location l ON l.location_key = i.location_key
LEFT JOIN payment_totals p ON p.order_id = i.order_id
LEFT JOIN dw.fact_deliveries d ON d.order_id = i.order_id
LEFT JOIN dw.dim_courier c ON c.courier_key = d.courier_key;

COMMENT ON VIEW dw.vw_bi_orders IS
    'One row per order; order-grain BI export from all 3 facts, aggregated before joins. Currency EUR; calendar Europe/Sofia.';

COMMENT ON COLUMN dw.vw_bi_orders.ordered_food_value_eur IS
    'Food subtotal even for cancelled orders. Use completed_food_sales_eur for completed sales.';
COMMENT ON COLUMN dw.vw_bi_orders.completed_order_value_eur IS
    'Delivered food sales + completed delivery fees. Customer order value, not platform revenue/profit.';
COMMENT ON COLUMN dw.vw_bi_orders.collected_payments_eur IS
    'Successful payments, including delivery fees. Do not add this to completed_order_value_eur.';
COMMENT ON COLUMN dw.vw_bi_orders.delivery_minutes IS
    'Minutes from order creation to delivery; NULL if not completed. Use AVG, not SUM.';

DO $$
BEGIN
    IF EXISTS (
        SELECT order_id FROM dw.vw_bi_orders
        GROUP BY order_id HAVING COUNT(*) <> 1
    ) OR (SELECT COUNT(*) FROM dw.vw_bi_orders)
        <> (SELECT COUNT(DISTINCT order_id) FROM dw.fact_order_items) THEN
        RAISE EXCEPTION 'Reporting view must contain exactly one row per order';
    END IF;

    IF (SELECT COALESCE(SUM(completed_food_sales_eur), 0) FROM dw.vw_bi_orders)
        <> (SELECT COALESCE(SUM(item_amount), 0) FROM dw.fact_order_items
            WHERE order_status = 'delivered')
       OR (SELECT COALESCE(SUM(collected_payments_eur), 0) FROM dw.vw_bi_orders)
        <> (SELECT COALESCE(SUM(successful_amount), 0) FROM dw.fact_payments)
       OR (SELECT COALESCE(SUM(failed_payment_count), 0) FROM dw.vw_bi_orders)
        <> (SELECT COUNT(*) FROM dw.fact_payments WHERE payment_status = 'failed') THEN
        RAISE EXCEPTION 'Reporting totals do not match warehouse facts';
    END IF;

    RAISE NOTICE 'PASS: report has one row per order; sales and payments reconcile';
END;
$$;

SELECT
    COUNT(*) AS total_orders,
    SUM(delivered_order_count) AS delivered_orders,
    SUM(cancelled_order_count) AS cancelled_orders,
    SUM(completed_food_sales_eur) AS food_sales_eur,
    SUM(completed_delivery_fees_eur) AS delivery_fees_eur,
    SUM(completed_order_value_eur) AS completed_order_value_eur,
    SUM(collected_payments_eur) AS collected_payments_eur,
    SUM(failed_payment_count) AS failed_payment_attempts,
    ROUND(AVG(delivery_minutes), 2) AS average_delivery_minutes
FROM dw.vw_bi_orders;

COMMIT;

-- Export from psql after successful execution (working directory: Glovo).
-- First ensure reports/data exists: \! mkdir -p reports/data
-- Run the following \copy command on ONE LINE:
-- \copy (SELECT * FROM dw.vw_bi_orders ORDER BY order_id) TO 'reports/data/glovo_orders.csv' WITH (FORMAT CSV, HEADER, ENCODING 'UTF8')
