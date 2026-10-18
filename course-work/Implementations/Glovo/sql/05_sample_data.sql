BEGIN;

DO $$
DECLARE
    v_customers BIGINT[] := ARRAY[]::BIGINT[];
    v_addresses BIGINT[] := ARRAY[]::BIGINT[];
    v_restaurants BIGINT[] := ARRAY[]::BIGINT[];
    v_products BIGINT[] := ARRAY[]::BIGINT[];
    v_couriers BIGINT[] := ARRAY[]::BIGINT[];
    v_methods BIGINT[] := ARRAY[]::BIGINT[];

    v_id BIGINT;
    v_category_id BIGINT;
    v_order_id BIGINT;
    v_customer_index INTEGER;
    v_restaurant_index INTEGER;
    v_product_index INTEGER;
    v_courier_index INTEGER;
    v_method_index INTEGER;

    v_ordered_at TIMESTAMPTZ;
    v_assigned_at TIMESTAMPTZ;
    v_picked_up_at TIMESTAMPTZ;
    v_delivered_at TIMESTAMPTZ;
    v_total NUMERIC;
    v_minutes INTEGER;

    i INTEGER;
    j INTEGER;
BEGIN
    -- Protect against accidental duplicate loading.
    IF EXISTS (
        SELECT 1 FROM public.customers
        WHERE email = 'sample.customer.1@example.com'
    ) THEN
        RAISE EXCEPTION 'Sample dataset already exists';
    END IF;

    -- 1. Customers and their addresses.
    FOR i IN 1..60 LOOP
        INSERT INTO public.customers (
            first_name, last_name, email, phone, registered_at
        )
        VALUES (
            'Customer',
            i::TEXT,
            format('sample.customer.%s@example.com', i),
            format('SAMPLE-CUSTOMER-%s', i),
            TIMESTAMPTZ '2025-12-01 10:00:00+02'
                + i * INTERVAL '1 hour'
        )
        RETURNING customer_id INTO v_id;

        v_customers := array_append(v_customers, v_id);

        INSERT INTO public.addresses (
            customer_id, label, city, district,
            street, street_number, postal_code
        )
        VALUES (
            v_id,
            'Home',
            'Plovdiv',
            (ARRAY['Central', 'Trakia', 'Karshiyaka'])[
                1 + ((i - 1) % 3)
            ],
            'Synthetic Street',
            i::TEXT,
            '4000'
        )
        RETURNING address_id INTO v_id;

        v_addresses := array_append(v_addresses, v_id);
    END LOOP;

    -- 2. Shared menu category.
    INSERT INTO public.categories (name, description)
    VALUES (
        'Sample meals',
        'Synthetic menu items for coursework analysis'
    )
    RETURNING category_id INTO v_category_id;

    -- 3. Six restaurants, four products per restaurant.
    FOR i IN 1..6 LOOP
        INSERT INTO public.restaurants (
            name, phone, email, street_address,
            opening_time, closing_time, minimum_order_amount
        )
        VALUES (
            format('Sample Restaurant %s', i),
            format('SAMPLE-RESTAURANT-%s', i),
            format('sample.restaurant.%s@example.com', i),
            format('Plovdiv, Synthetic Avenue %s', i),
            '09:00',
            '23:00',
            5.00
        )
        RETURNING restaurant_id INTO v_id;

        v_restaurants := array_append(v_restaurants, v_id);

        FOR j IN 1..4 LOOP
            INSERT INTO public.products (
                restaurant_id, category_id,
                name, description, price, created_at
            )
            VALUES (
                v_restaurants[i],
                v_category_id,
                format('Sample Meal %s-%s', i, j),
                'Fictional product for analysis',
                5.00 + i * 0.75 + j * 1.25,
                TIMESTAMPTZ '2025-12-15 10:00:00+02'
            )
            RETURNING product_id INTO v_id;

            v_products := array_append(v_products, v_id);
        END LOOP;
    END LOOP;

    -- 4. Couriers.
    FOR i IN 1..8 LOOP
        INSERT INTO public.couriers (
            first_name, last_name, phone, vehicle_type
        )
        VALUES (
            'SampleCourier',
            i::TEXT,
            format('SAMPLE-COURIER-%s', i),
            (ARRAY['bicycle', 'motorcycle', 'car'])[
                1 + ((i - 1) % 3)
            ]
        )
        RETURNING courier_id INTO v_id;

        v_couriers := array_append(v_couriers, v_id);
    END LOOP;

    -- 5. Payment methods.
    FOR i IN 1..3 LOOP
        INSERT INTO public.payment_methods (name)
        VALUES (
            (ARRAY[
                'Sample card',
                'Sample cash',
                'Sample digital wallet'
            ])[i]
        )
        RETURNING payment_method_id INTO v_id;

        v_methods := array_append(v_methods, v_id);
    END LOOP;

    -- 6. Historical orders: 30 in each of six months.
    -- Direct INSERT allows historical ordered_at values.
    -- All existing triggers remain enabled.
    FOR i IN 1..180 LOOP
        v_customer_index := 1 + ((i - 1) % 60);
        v_restaurant_index := 1 + ((i * 7 + i / 11) % 6);
        v_courier_index := 1 + ((i - 1) % 8);

        -- Approximately 60% card, 30% cash, 10% wallet.
        v_method_index := CASE
            WHEN i % 10 < 6 THEN 1
            WHEN i % 10 < 9 THEN 2
            ELSE 3
        END;

        v_product_index :=
            (v_restaurant_index - 1) * 4 + 1 + (i % 4);

        v_ordered_at :=
            TIMESTAMPTZ '2026-01-01 00:00:00+02'
            + ((i - 1) / 30) * INTERVAL '1 month'
            + ((i - 1) % 28) * INTERVAL '1 day'
            + (10 + (i % 9)) * INTERVAL '1 hour'
            + (i % 50) * INTERVAL '1 minute';

        INSERT INTO public.orders (
            customer_id, address_id, restaurant_id,
            ordered_at, delivery_fee, notes
        )
        VALUES (
            v_customers[v_customer_index],
            v_addresses[v_customer_index],
            v_restaurants[v_restaurant_index],
            v_ordered_at,
            1.50 + (i % 4) * 0.50,
            format('SAMPLE-2026-%s', i)
        )
        RETURNING order_id INTO v_order_id;

        -- First item: the trigger sets the actual unit price.
        INSERT INTO public.order_items (
            order_id, product_id, quantity, unit_price
        )
        VALUES (
            v_order_id,
            v_products[v_product_index],
            1 + (i % 3),
            0
        );

        -- Second, distinct product from the same restaurant.
        INSERT INTO public.order_items (
            order_id, product_id, quantity, unit_price
        )
        VALUES (
            v_order_id,
            v_products[
                (v_restaurant_index - 1) * 4
                + 1 + ((i + 1) % 4)
            ],
            1 + (i % 2),
            0
        );

        -- Every tenth order is cancelled before payment.
        IF i % 10 = 0 THEN
            UPDATE public.orders
            SET status = 'cancelled'
            WHERE order_id = v_order_id;

        ELSE
            v_total := public.fn_order_total(v_order_id);

            -- Some card/wallet orders have an unsuccessful attempt.
            IF i % 7 = 0 AND v_method_index <> 2 THEN
                INSERT INTO public.payments (
                    order_id, payment_method_id,
                    amount, status, transaction_reference
                )
                VALUES (
                    v_order_id,
                    v_methods[v_method_index],
                    v_total,
                    'failed',
                    format('SAMPLE-FAILED-%s', i)
                );
            END IF;

            UPDATE public.orders
            SET status = 'confirmed'
            WHERE order_id = v_order_id;

            CALL public.sp_assign_courier(
                v_order_id,
                v_couriers[v_courier_index],
                30 + (i % 15)
            );

            v_assigned_at := v_ordered_at + INTERVAL '4 minutes';
            v_picked_up_at :=
                v_ordered_at + (12 + (i % 8)) * INTERVAL '1 minute';

            v_minutes := 25 + (i % 31);
            v_delivered_at :=
                v_ordered_at + v_minutes * INTERVAL '1 minute';

            -- Set fictional historical event times for this sample.
            UPDATE public.deliveries
            SET assigned_at = v_assigned_at
            WHERE order_id = v_order_id;

            UPDATE public.orders
            SET status = 'preparing'
            WHERE order_id = v_order_id;

            UPDATE public.orders
            SET status = 'ready'
            WHERE order_id = v_order_id;

            UPDATE public.deliveries
            SET status = 'picked_up',
                picked_up_at = v_picked_up_at
            WHERE order_id = v_order_id;

            UPDATE public.orders
            SET status = 'delivering'
            WHERE order_id = v_order_id;

            -- Cash is paid at delivery; electronic methods earlier.
            INSERT INTO public.payments (
                order_id, payment_method_id,
                amount, status, paid_at, transaction_reference
            )
            VALUES (
                v_order_id,
                v_methods[v_method_index],
                v_total,
                'successful',
                CASE
                    WHEN v_method_index = 2 THEN v_delivered_at
                    ELSE v_ordered_at + INTERVAL '2 minutes'
                END,
                format('SAMPLE-SUCCESS-%s', i)
            );

            UPDATE public.deliveries
            SET status = 'delivered',
                delivered_at = v_delivered_at
            WHERE order_id = v_order_id;

            UPDATE public.orders
            SET status = 'delivered'
            WHERE order_id = v_order_id;
        END IF;

        -- Triggers create the history automatically.
        -- During sample generation only, align its timestamps
        -- with the fictional historical timeline.
        UPDATE public.order_status_history
        SET changed_at = CASE new_status
            WHEN 'pending' THEN v_ordered_at
            WHEN 'confirmed' THEN v_ordered_at + INTERVAL '3 minutes'
            WHEN 'preparing' THEN v_ordered_at + INTERVAL '5 minutes'
            WHEN 'ready' THEN v_picked_up_at - INTERVAL '1 minute'
            WHEN 'delivering' THEN v_picked_up_at
            WHEN 'delivered' THEN v_delivered_at
            WHEN 'cancelled' THEN v_ordered_at + INTERVAL '2 minutes'
        END
        WHERE order_id = v_order_id;
    END LOOP;

    RAISE NOTICE 'Created 180 sample orders: 162 delivered, 18 cancelled';
END;
$$;

SET CONSTRAINTS ALL IMMEDIATE;

COMMIT;