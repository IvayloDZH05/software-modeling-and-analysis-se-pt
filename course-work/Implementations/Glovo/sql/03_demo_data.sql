BEGIN;

DO $$
DECLARE
    v_customer_id BIGINT;
    v_address_id BIGINT;
    v_restaurant_id BIGINT;
    v_category_id BIGINT;
    v_pizza_id BIGINT;
    v_drink_id BIGINT;
    v_method_id BIGINT;
    v_courier_id BIGINT;
    v_order_id BIGINT;
    v_total NUMERIC;
    v_balance NUMERIC;
    v_history_count INTEGER;
BEGIN
    -- Prevent accidental duplicate execution.
    IF EXISTS (
        SELECT 1 FROM public.customers
        WHERE email = 'demo.customer@example.com'
    ) THEN
        RAISE EXCEPTION 'Demo data already exists';
    END IF;

    -- 1. Customer and address: fictional data.
    INSERT INTO public.customers (
        first_name, last_name, email, phone
    )
    VALUES (
        'Demo', 'Customer',
        'demo.customer@example.com', 'DEMO-CUSTOMER-001'
    )
    RETURNING customer_id INTO v_customer_id;

    INSERT INTO public.addresses (
        customer_id, label, city, street,
        street_number, postal_code
    )
    VALUES (
        v_customer_id, 'Home', 'Plovdiv',
        'Demo Street', '10', '4000'
    )
    RETURNING address_id INTO v_address_id;

    -- 2. Restaurant and menu.
    INSERT INTO public.restaurants (
        name, phone, email, street_address,
        opening_time, closing_time, minimum_order_amount
    )
    VALUES (
        'Demo Pizza', 'DEMO-RESTAURANT-001',
        'demo.restaurant@example.com',
        'Plovdiv, Demo Street 20',
        '10:00', '23:00', 10.00
    )
    RETURNING restaurant_id INTO v_restaurant_id;

    INSERT INTO public.categories (name, description)
    VALUES ('Demo pizzas', 'Pizza category for the demonstration')
    RETURNING category_id INTO v_category_id;

    INSERT INTO public.products (
        restaurant_id, category_id, name, price
    )
    VALUES (
        v_restaurant_id, v_category_id, 'Margherita', 8.50
    )
    RETURNING product_id INTO v_pizza_id;

    INSERT INTO public.categories (name, description)
    VALUES ('Demo drinks', 'Drink category for the demonstration')
    RETURNING category_id INTO v_category_id;

    INSERT INTO public.products (
        restaurant_id, category_id, name, price
    )
    VALUES (
        v_restaurant_id, v_category_id, 'Lemonade', 3.00
    )
    RETURNING product_id INTO v_drink_id;

    -- 3. Payment method and courier.
    INSERT INTO public.payment_methods (name)
    VALUES ('Demo card')
    RETURNING payment_method_id INTO v_method_id;

    INSERT INTO public.couriers (
        first_name, last_name, phone, vehicle_type
    )
    VALUES (
        'Demo', 'Courier', 'DEMO-COURIER-001', 'bicycle'
    )
    RETURNING courier_id INTO v_courier_id;

    -- 4. Create an order using our stored procedure.
    -- 2 pizzas x 8.50 + 1 drink x 3.00 + delivery 2.50 = 22.50.
    CALL public.sp_create_order(
        v_customer_id,
        v_address_id,
        v_restaurant_id,
        2.50,
        jsonb_build_array(
            jsonb_build_object(
                'product_id', v_pizza_id,
                'quantity', 2
            ),
            jsonb_build_object(
                'product_id', v_drink_id,
                'quantity', 1
            )
        ),
        v_order_id,
        'Demonstration order'
    );

    v_total := public.fn_order_total(v_order_id);

    IF v_total IS DISTINCT FROM 22.50::NUMERIC THEN
        RAISE EXCEPTION 'Incorrect order total: %', v_total;
    END IF;

    -- 5. Successful payment.
    -- The payment trigger fills paid_at automatically.
    INSERT INTO public.payments (
        order_id, payment_method_id,
        amount, status, transaction_reference
    )
    VALUES (
        v_order_id, v_method_id,
        22.50, 'successful', 'DEMO-PAYMENT-001'
    );

    v_balance := public.fn_order_balance(v_order_id);

    IF v_balance IS DISTINCT FROM 0::NUMERIC THEN
        RAISE EXCEPTION 'Incorrect remaining balance: %', v_balance;
    END IF;

    -- 6. Confirm order and assign courier.
    UPDATE public.orders
    SET status = 'confirmed'
    WHERE order_id = v_order_id;

    CALL public.sp_assign_courier(
        v_order_id, v_courier_id, 30
    );

    -- 7. Move through the permitted order statuses.
    UPDATE public.orders
    SET status = 'preparing'
    WHERE order_id = v_order_id;

    UPDATE public.orders
    SET status = 'ready'
    WHERE order_id = v_order_id;

    UPDATE public.deliveries
    SET status = 'picked_up',
        picked_up_at = clock_timestamp()
    WHERE order_id = v_order_id;

    UPDATE public.orders
    SET status = 'delivering'
    WHERE order_id = v_order_id;

    UPDATE public.deliveries
    SET status = 'delivered',
        delivered_at = clock_timestamp()
    WHERE order_id = v_order_id;

    UPDATE public.orders
    SET status = 'delivered'
    WHERE order_id = v_order_id;

    -- 8. Check automatic status history.
    SELECT COUNT(*) INTO v_history_count
    FROM public.order_status_history
    WHERE order_id = v_order_id;

    IF v_history_count <> 6 THEN
        RAISE EXCEPTION
            'Expected 6 history records, received %', v_history_count;
    END IF;

    RAISE NOTICE 'Demo order ID: %', v_order_id;
    RAISE NOTICE 'Total: % EUR; balance: % EUR', v_total, v_balance;
    RAISE NOTICE 'Status history records: %', v_history_count;
END;
$$;

-- Run deferred checks before committing.
SET CONSTRAINTS ALL IMMEDIATE;

COMMIT;