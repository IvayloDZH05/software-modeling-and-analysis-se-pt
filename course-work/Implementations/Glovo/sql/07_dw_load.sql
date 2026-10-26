-- Glovo coursework / PostgreSQL 18
-- Run in glovo after 06_dw_schema.sql.
-- Scope: source orders with notes LIKE 'SAMPLE-2026-%'.
-- Refresh strategy: upsert by source IDs; dimension attributes use Type 1.
-- Warehouse surrogate keys remain unchanged on refresh.
-- Generated fact measures are computed by PostgreSQL, not inserted.
-- No source data is modified. No target rows are deleted.
-- Source deletions/scope changes are detected by reconciliation and need
-- an explicit retention policy; this script does not silently purge history.

BEGIN ISOLATION LEVEL REPEATABLE READ;

-- Only one copy of this loader should write at a time.
SELECT pg_advisory_xact_lock(26062507);

DO $$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'dim_date', 'dim_customer', 'dim_restaurant', 'dim_location',
        'dim_product', 'dim_payment_method', 'dim_courier',
        'fact_order_items', 'fact_payments', 'fact_deliveries'
    ] LOOP
        IF to_regclass('dw.' || v_table) IS NULL THEN
            RAISE EXCEPTION 'Missing dw.%; run 06_dw_schema.sql first', v_table;
        END IF;
    END LOOP;
END;
$$;

-- =========================================================
-- 1. CONSISTENT SOURCE SNAPSHOT
-- Europe/Sofia converts order instants to the local business date.
-- =========================================================

CREATE TEMP TABLE _dw_source_orders ON COMMIT DROP AS
SELECT o.*,
       (o.ordered_at AT TIME ZONE 'Europe/Sofia')::DATE AS order_date
FROM public.orders o
WHERE o.notes LIKE 'SAMPLE-2026-%';

ALTER TABLE _dw_source_orders ADD PRIMARY KEY (order_id);

CREATE TEMP TABLE _dw_source_items ON COMMIT DROP AS
SELECT i.*
FROM public.order_items i
JOIN _dw_source_orders o USING (order_id);

CREATE TEMP TABLE _dw_source_payments ON COMMIT DROP AS
SELECT p.*
FROM public.payments p
JOIN _dw_source_orders o USING (order_id);

CREATE TEMP TABLE _dw_source_deliveries ON COMMIT DROP AS
SELECT d.*
FROM public.deliveries d
JOIN _dw_source_orders o USING (order_id);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM _dw_source_orders) THEN
        RAISE EXCEPTION 'No sample orders found; run 05_sample_data.sql first';
    END IF;

    IF EXISTS (
        SELECT 1 FROM _dw_source_orders o
        WHERE NOT EXISTS (
            SELECT 1 FROM _dw_source_items i WHERE i.order_id = o.order_id
        )
    ) THEN
        RAISE EXCEPTION 'A sample order has no items; fix source data first';
    END IF;
END;
$$;

-- =========================================================
-- 2. DIMENSIONS
-- Date dimension includes every day in the selected order range,
-- including days with no orders.
-- =========================================================

INSERT INTO dw.dim_date (
    date_key, full_date, year, quarter, month, month_name,
    day_of_month, day_of_week_iso, is_weekend
)
SELECT
    EXTRACT(YEAR FROM d)::INTEGER * 10000
        + EXTRACT(MONTH FROM d)::INTEGER * 100
        + EXTRACT(DAY FROM d)::INTEGER,
    d,
    EXTRACT(YEAR FROM d)::SMALLINT,
    EXTRACT(QUARTER FROM d)::SMALLINT,
    EXTRACT(MONTH FROM d)::SMALLINT,
    (ARRAY[
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
    ])[EXTRACT(MONTH FROM d)::INTEGER],
    EXTRACT(DAY FROM d)::SMALLINT,
    EXTRACT(ISODOW FROM d)::SMALLINT,
    EXTRACT(ISODOW FROM d) IN (6, 7)
FROM (
    SELECT b.first_date + g.day_offset AS d
    FROM (
        SELECT MIN(order_date) AS first_date,
               MAX(order_date) AS last_date
        FROM _dw_source_orders
    ) b
    CROSS JOIN LATERAL generate_series(
        0, b.last_date - b.first_date
    ) AS g(day_offset)
) dates
ON CONFLICT (date_key) DO UPDATE SET
    full_date = EXCLUDED.full_date,
    year = EXCLUDED.year,
    quarter = EXCLUDED.quarter,
    month = EXCLUDED.month,
    month_name = EXCLUDED.month_name,
    day_of_month = EXCLUDED.day_of_month,
    day_of_week_iso = EXCLUDED.day_of_week_iso,
    is_weekend = EXCLUDED.is_weekend;

INSERT INTO dw.dim_customer (
    customer_id, first_name, last_name, registered_at, is_active
)
SELECT c.customer_id, c.first_name, c.last_name, c.registered_at, c.is_active
FROM public.customers c
WHERE EXISTS (
    SELECT 1 FROM _dw_source_orders o WHERE o.customer_id = c.customer_id
)
ON CONFLICT (customer_id) DO UPDATE SET
    first_name = EXCLUDED.first_name,
    last_name = EXCLUDED.last_name,
    registered_at = EXCLUDED.registered_at,
    is_active = EXCLUDED.is_active;

INSERT INTO dw.dim_restaurant (
    restaurant_id, name, street_address, is_active
)
SELECT r.restaurant_id, r.name, r.street_address, r.is_active
FROM public.restaurants r
WHERE EXISTS (
    SELECT 1 FROM _dw_source_orders o WHERE o.restaurant_id = r.restaurant_id
)
ON CONFLICT (restaurant_id) DO UPDATE SET
    name = EXCLUDED.name,
    street_address = EXCLUDED.street_address,
    is_active = EXCLUDED.is_active;

INSERT INTO dw.dim_location (address_id, city, district, postal_code)
SELECT a.address_id, a.city, a.district, a.postal_code
FROM public.addresses a
WHERE EXISTS (
    SELECT 1 FROM _dw_source_orders o WHERE o.address_id = a.address_id
)
ON CONFLICT (address_id) DO UPDATE SET
    city = EXCLUDED.city,
    district = EXCLUDED.district,
    postal_code = EXCLUDED.postal_code;

INSERT INTO dw.dim_product (product_id, name, category_name, is_available)
SELECT p.product_id, p.name, c.name, p.is_available
FROM public.products p
JOIN public.categories c USING (category_id)
WHERE EXISTS (
    SELECT 1 FROM _dw_source_items i WHERE i.product_id = p.product_id
)
ON CONFLICT (product_id) DO UPDATE SET
    name = EXCLUDED.name,
    category_name = EXCLUDED.category_name,
    is_available = EXCLUDED.is_available;

INSERT INTO dw.dim_payment_method (payment_method_id, name, is_active)
SELECT m.payment_method_id, m.name, m.is_active
FROM public.payment_methods m
WHERE EXISTS (
    SELECT 1 FROM _dw_source_payments p
    WHERE p.payment_method_id = m.payment_method_id
)
ON CONFLICT (payment_method_id) DO UPDATE SET
    name = EXCLUDED.name,
    is_active = EXCLUDED.is_active;

INSERT INTO dw.dim_courier (
    courier_key, courier_id, first_name, last_name, vehicle_type
)
VALUES (0, NULL, 'Unknown', 'Unassigned', 'unknown')
ON CONFLICT (courier_key) DO NOTHING;

INSERT INTO dw.dim_courier (courier_id, first_name, last_name, vehicle_type)
SELECT c.courier_id, c.first_name, c.last_name, c.vehicle_type
FROM public.couriers c
WHERE EXISTS (
    SELECT 1 FROM _dw_source_deliveries d WHERE d.courier_id = c.courier_id
)
ON CONFLICT (courier_id) DO UPDATE SET
    first_name = EXCLUDED.first_name,
    last_name = EXCLUDED.last_name,
    vehicle_type = EXCLUDED.vehicle_type;

-- =========================================================
-- 3. RESOLVE DIMENSION KEYS AND EXPECTED FACT ROWS
-- Preserve historical unit_price from order_items, not products.price.
-- =========================================================

CREATE TEMP TABLE _dw_order_keys ON COMMIT DROP AS
SELECT o.*,
       d.date_key AS order_date_key,
       c.customer_key,
       r.restaurant_key,
       l.location_key
FROM _dw_source_orders o
JOIN dw.dim_date d ON d.full_date = o.order_date
JOIN dw.dim_customer c ON c.customer_id = o.customer_id
JOIN dw.dim_restaurant r ON r.restaurant_id = o.restaurant_id
JOIN dw.dim_location l ON l.address_id = o.address_id;

CREATE TEMP TABLE _dw_expected_items ON COMMIT DROP AS
SELECT i.order_id, o.order_date_key, o.customer_key,
       o.restaurant_key, o.location_key, p.product_key,
       o.status AS order_status, i.quantity, i.unit_price,
       (i.quantity::NUMERIC * i.unit_price)::NUMERIC(18,2) AS item_amount
FROM _dw_source_items i
JOIN _dw_order_keys o USING (order_id)
JOIN dw.dim_product p ON p.product_id = i.product_id;

CREATE TEMP TABLE _dw_expected_payments ON COMMIT DROP AS
SELECT p.payment_id, p.order_id, o.order_date_key, o.customer_key,
       o.restaurant_key, o.location_key, m.payment_method_key,
       p.status AS payment_status, p.amount,
       (CASE WHEN p.status = 'successful' THEN p.amount ELSE 0 END)
           ::NUMERIC(12,2) AS successful_amount,
       p.paid_at
FROM _dw_source_payments p
JOIN _dw_order_keys o USING (order_id)
JOIN dw.dim_payment_method m ON m.payment_method_id = p.payment_method_id;

CREATE TEMP TABLE _dw_expected_deliveries ON COMMIT DROP AS
SELECT d.delivery_id, d.order_id, o.order_date_key, o.customer_key,
       o.restaurant_key, o.location_key, c.courier_key,
       d.status AS delivery_status,
       o.ordered_at, d.assigned_at, d.picked_up_at, d.delivered_at,
       d.estimated_minutes,
       (CASE WHEN d.status = 'delivered'
            THEN EXTRACT(EPOCH FROM (d.delivered_at - o.ordered_at)) / 60.0
            ELSE NULL END)::NUMERIC(10,2) AS delivery_minutes,
       o.delivery_fee
FROM _dw_source_deliveries d
JOIN _dw_order_keys o USING (order_id)
JOIN dw.dim_courier c ON (
    (d.courier_id IS NULL AND c.courier_key = 0)
    OR d.courier_id = c.courier_id
);

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM _dw_order_keys)
        <> (SELECT COUNT(*) FROM _dw_source_orders)
       OR (SELECT COUNT(*) FROM _dw_expected_items)
        <> (SELECT COUNT(*) FROM _dw_source_items)
       OR (SELECT COUNT(*) FROM _dw_expected_payments)
        <> (SELECT COUNT(*) FROM _dw_source_payments)
       OR (SELECT COUNT(*) FROM _dw_expected_deliveries)
        <> (SELECT COUNT(*) FROM _dw_source_deliveries) THEN
        RAISE EXCEPTION 'Missing or duplicate dimension mapping; load cancelled';
    END IF;
END;
$$;

-- =========================================================
-- 4. INSERT NEW FACTS / REFRESH EXISTING FACTS
-- The *_fact_key surrogate PKs are not overwritten on conflict.
-- =========================================================

INSERT INTO dw.fact_order_items (
    order_id, order_date_key, customer_key, restaurant_key,
    location_key, product_key, order_status, quantity, unit_price
)
SELECT order_id, order_date_key, customer_key, restaurant_key,
       location_key, product_key, order_status, quantity, unit_price
FROM _dw_expected_items
WHERE TRUE
ON CONFLICT (order_id, product_key) DO UPDATE SET
    order_date_key = EXCLUDED.order_date_key,
    customer_key = EXCLUDED.customer_key,
    restaurant_key = EXCLUDED.restaurant_key,
    location_key = EXCLUDED.location_key,
    order_status = EXCLUDED.order_status,
    quantity = EXCLUDED.quantity,
    unit_price = EXCLUDED.unit_price;

INSERT INTO dw.fact_payments (
    payment_id, order_id, order_date_key, customer_key, restaurant_key,
    location_key, payment_method_key, payment_status, amount, paid_at
)
SELECT payment_id, order_id, order_date_key, customer_key, restaurant_key,
       location_key, payment_method_key, payment_status, amount, paid_at
FROM _dw_expected_payments
WHERE TRUE
ON CONFLICT (payment_id) DO UPDATE SET
    order_id = EXCLUDED.order_id,
    order_date_key = EXCLUDED.order_date_key,
    customer_key = EXCLUDED.customer_key,
    restaurant_key = EXCLUDED.restaurant_key,
    location_key = EXCLUDED.location_key,
    payment_method_key = EXCLUDED.payment_method_key,
    payment_status = EXCLUDED.payment_status,
    amount = EXCLUDED.amount,
    paid_at = EXCLUDED.paid_at;

INSERT INTO dw.fact_deliveries (
    delivery_id, order_id, order_date_key, customer_key, restaurant_key,
    location_key, courier_key, delivery_status, ordered_at,
    assigned_at, picked_up_at, delivered_at, estimated_minutes, delivery_fee
)
SELECT delivery_id, order_id, order_date_key, customer_key, restaurant_key,
       location_key, courier_key, delivery_status, ordered_at,
       assigned_at, picked_up_at, delivered_at, estimated_minutes, delivery_fee
FROM _dw_expected_deliveries
WHERE TRUE
ON CONFLICT (delivery_id) DO UPDATE SET
    order_id = EXCLUDED.order_id,
    order_date_key = EXCLUDED.order_date_key,
    customer_key = EXCLUDED.customer_key,
    restaurant_key = EXCLUDED.restaurant_key,
    location_key = EXCLUDED.location_key,
    courier_key = EXCLUDED.courier_key,
    delivery_status = EXCLUDED.delivery_status,
    ordered_at = EXCLUDED.ordered_at,
    assigned_at = EXCLUDED.assigned_at,
    picked_up_at = EXCLUDED.picked_up_at,
    delivered_at = EXCLUDED.delivered_at,
    estimated_minutes = EXCLUDED.estimated_minutes,
    delivery_fee = EXCLUDED.delivery_fee;

-- =========================================================
-- 5. RECONCILE ALL FACT ATTRIBUTES AND GENERATED MEASURES
-- Symmetric EXCEPT ALL detects missing/extra rows and any value mismatch.
-- Surrogate fact PKs are intentionally excluded from the comparison.
-- This warehouse is dedicated to the sample scope, not a mixed-source DW.
-- =========================================================

DO $$
DECLARE
    v_expected TEXT;
    v_target TEXT;
    v_columns TEXT;
    v_mismatch BOOLEAN;
    v_count BIGINT;
BEGIN
    FOR v_expected, v_target IN
        SELECT * FROM (VALUES
            ('_dw_expected_items', 'fact_order_items'),
            ('_dw_expected_payments', 'fact_payments'),
            ('_dw_expected_deliveries', 'fact_deliveries')
        ) AS checks(expected_name, target_name)
    LOOP
        SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum)
        INTO v_columns
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass('pg_temp.' || v_expected)
          AND a.attnum > 0
          AND NOT a.attisdropped;

        EXECUTE format(
            'SELECT EXISTS (
                (SELECT %1$s FROM pg_temp.%2$I
                 EXCEPT ALL SELECT %1$s FROM dw.%3$I)
                UNION ALL
                (SELECT %1$s FROM dw.%3$I
                 EXCEPT ALL SELECT %1$s FROM pg_temp.%2$I)
            )', v_columns, v_expected, v_target
        ) INTO v_mismatch;

        IF v_mismatch THEN
            RAISE EXCEPTION
                'Reconciliation failed for dw.%. Check values or stale rows from source deletions/scope changes; no changes committed',
                v_target;
        END IF;

        EXECUTE format('SELECT COUNT(*) FROM dw.%I', v_target) INTO v_count;
        RAISE NOTICE 'PASS: dw.% matches source (% rows)', v_target, v_count;
    END LOOP;
END;
$$;

-- For this fully paid sample, delivered food sales + delivery fees
-- must equal successful payments. Aggregate facts separately to avoid
-- multiplying payments by the number of products in an order.
DO $$
DECLARE
    v_food NUMERIC;
    v_fees NUMERIC;
    v_collected NUMERIC;
BEGIN
    SELECT COALESCE(SUM(item_amount), 0) INTO v_food
    FROM dw.fact_order_items WHERE order_status = 'delivered';

    SELECT COALESCE(SUM(delivery_fee), 0) INTO v_fees
    FROM dw.fact_deliveries WHERE delivery_status = 'delivered';

    SELECT COALESCE(SUM(successful_amount), 0) INTO v_collected
    FROM dw.fact_payments;

    IF v_food + v_fees <> v_collected THEN
        RAISE EXCEPTION
            'Sample money reconciliation failed: food % + fees % <> collected %',
            v_food, v_fees, v_collected;
    END IF;

    RAISE NOTICE 'PASS: food % + fees % = collected % EUR',
        v_food, v_fees, v_collected;
END;
$$;

-- Present counts only after successful row-level reconciliation.
SELECT 'fact_order_items' AS table_name, COUNT(*) AS row_count
FROM dw.fact_order_items
UNION ALL
SELECT 'fact_payments', COUNT(*) FROM dw.fact_payments
UNION ALL
SELECT 'fact_deliveries', COUNT(*) FROM dw.fact_deliveries
ORDER BY table_name;

COMMIT;
