BEGIN;

DO $$
DECLARE
    v_order_id BIGINT;
    v_customer_id BIGINT;
    v_address_id BIGINT;
    v_restaurant_id BIGINT;
    v_method_id BIGINT;
    v_other_customer_id BIGINT;
    v_new_order_id BIGINT;
    v_error TEXT;
    v_passed INTEGER := 0;
BEGIN
    SELECT
        o.order_id,
        o.customer_id,
        o.address_id,
        o.restaurant_id
    INTO
        v_order_id,
        v_customer_id,
        v_address_id,
        v_restaurant_id
    FROM public.orders o
    JOIN public.customers c USING (customer_id)
    WHERE c.email = 'demo.customer@example.com'
      AND o.notes = 'Demonstration order';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run 03_demo_data.sql first';
    END IF;

    SELECT payment_method_id INTO v_method_id
    FROM public.payment_methods
    WHERE name = 'Demo card';

    -- TEST 1: Additional payment on an already fully paid order.
    v_error := NULL;

    BEGIN
        INSERT INTO public.payments (
            order_id, payment_method_id, amount, status
        )
        VALUES (
            v_order_id, v_method_id, 1.00, 'successful'
        );
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    END;

    IF v_error IS NULL
       OR v_error NOT LIKE 'Payment exceeds remaining balance%' THEN
        RAISE EXCEPTION 'FAIL 1: unexpected result: %',
            COALESCE(v_error, 'payment was accepted');
    END IF;

    v_passed := v_passed + 1;
    RAISE NOTICE 'PASS 1: Overpayment rejected';


    -- TEST 2: A different customer uses the demo customer's address.
    INSERT INTO public.customers (
        first_name, last_name, email, phone
    )
    VALUES (
        'Validation', 'Customer',
        'validation.customer@example.com', 'TEST-002'
    )
    RETURNING customer_id INTO v_other_customer_id;

    v_error := NULL;

    BEGIN
        INSERT INTO public.orders (
            customer_id, address_id, restaurant_id, delivery_fee
        )
        VALUES (
            v_other_customer_id, v_address_id,
            v_restaurant_id, 2.50
        );
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    END;

    IF v_error IS DISTINCT FROM
        'Address does not belong to the ordering customer' THEN
        RAISE EXCEPTION 'FAIL 2: unexpected result: %',
            COALESCE(v_error, 'foreign address was accepted');
    END IF;

    v_passed := v_passed + 1;
    RAISE NOTICE 'PASS 2: Another customer''s address rejected';


    -- TEST 3: Attempt to move a delivered order back to pending.
    v_error := NULL;

    BEGIN
        UPDATE public.orders
        SET status = 'pending'
        WHERE order_id = v_order_id;
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    END;

    IF v_error IS DISTINCT FROM
        'Invalid order status transition: delivered -> pending' THEN
        RAISE EXCEPTION 'FAIL 3: unexpected result: %',
            COALESCE(v_error, 'invalid status was accepted');
    END IF;

    v_passed := v_passed + 1;
    RAISE NOTICE 'PASS 3: Invalid status transition rejected';


    -- TEST 4: Attempt to overwrite an address used by an order.
    v_error := NULL;

    BEGIN
        UPDATE public.addresses
        SET street = 'Changed street for validation'
        WHERE address_id = v_address_id;
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    END;

    IF v_error IS DISTINCT FROM
        'Address is used by an order; create a new address instead' THEN
        RAISE EXCEPTION 'FAIL 4: unexpected result: %',
            COALESCE(v_error, 'address modification was accepted');
    END IF;

    v_passed := v_passed + 1;
    RAISE NOTICE 'PASS 4: Historical address protected';


    -- TEST 5: Create an order without items.
    -- Force the deferred constraint to run inside the test.
    v_error := NULL;

    BEGIN
        INSERT INTO public.orders (
            customer_id, address_id, restaurant_id, delivery_fee
        )
        VALUES (
            v_customer_id, v_address_id, v_restaurant_id, 2.50
        )
        RETURNING order_id INTO v_new_order_id;

        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    END;

    IF v_error IS NULL
       OR v_error NOT LIKE 'Order % must contain at least one item' THEN
        RAISE EXCEPTION 'FAIL 5: unexpected result: %',
            COALESCE(v_error, 'empty order was accepted');
    END IF;

    v_passed := v_passed + 1;
    RAISE NOTICE 'PASS 5: Order without items rejected';

    RAISE NOTICE 'RESULT: % / 5 validation tests passed', v_passed;
END;
$$;

-- Test-only records are not retained.
ROLLBACK;