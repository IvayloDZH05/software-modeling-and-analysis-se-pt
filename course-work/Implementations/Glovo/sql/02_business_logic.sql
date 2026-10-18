BEGIN;

-- =========================================================
-- 1. FUNCTIONS
-- =========================================================

CREATE OR REPLACE FUNCTION fn_order_total(p_order_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT o.delivery_fee + COALESCE(
        (
            SELECT SUM(oi.quantity * oi.unit_price)
            FROM public.order_items oi
            WHERE oi.order_id = o.order_id
        ),
        0
    )
    FROM public.orders o
    WHERE o.order_id = p_order_id;
$$;


CREATE OR REPLACE FUNCTION fn_order_balance(p_order_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT public.fn_order_total(p_order_id) - COALESCE(
        (
            SELECT SUM(p.amount)
            FROM public.payments p
            WHERE p.order_id = p_order_id
              AND p.status = 'successful'
        ),
        0
    );
$$;


-- =========================================================
-- 2. ORDER VALIDATION AND HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION trg_validate_order()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id BIGINT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.order_id IS DISTINCT FROM OLD.order_id
           OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
           OR NEW.address_id IS DISTINCT FROM OLD.address_id
           OR NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id
           OR NEW.delivery_fee IS DISTINCT FROM OLD.delivery_fee
           OR NEW.ordered_at IS DISTINCT FROM OLD.ordered_at THEN
            RAISE EXCEPTION
                'Order identity, address, restaurant, date and fee are immutable';
        END IF;

        IF NEW.status IS DISTINCT FROM OLD.status THEN
            IF NOT (
                (OLD.status = 'pending'
                    AND NEW.status IN ('confirmed', 'cancelled'))
                OR (OLD.status = 'confirmed'
                    AND NEW.status IN ('preparing', 'cancelled'))
                OR (OLD.status = 'preparing'
                    AND NEW.status IN ('ready', 'cancelled'))
                OR (OLD.status = 'ready'
                    AND NEW.status IN ('delivering', 'cancelled'))
                OR (OLD.status = 'delivering'
                    AND NEW.status = 'delivered')
            ) THEN
                RAISE EXCEPTION 'Invalid order status transition: % -> %',
                    OLD.status, NEW.status;
            END IF;

            IF NEW.status = 'cancelled'
               AND EXISTS (
                   SELECT 1 FROM public.payments
                   WHERE order_id = OLD.order_id
                     AND status = 'successful'
               ) THEN
                RAISE EXCEPTION
                    'Paid orders cannot be cancelled: refunds are outside scope';
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    IF NEW.status <> 'pending' THEN
        RAISE EXCEPTION 'A new order must start with pending status';
    END IF;

    PERFORM 1 FROM public.customers
    WHERE customer_id = NEW.customer_id AND is_active
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Customer does not exist or is inactive';
    END IF;

    SELECT customer_id INTO v_customer_id
    FROM public.addresses
    WHERE address_id = NEW.address_id
    FOR SHARE;

    IF NOT FOUND OR v_customer_id <> NEW.customer_id THEN
        RAISE EXCEPTION 'Address does not belong to the ordering customer';
    END IF;

    PERFORM 1 FROM public.restaurants
    WHERE restaurant_id = NEW.restaurant_id AND is_active
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Restaurant does not exist or is inactive';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER validate_order
BEFORE INSERT OR UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION trg_validate_order();


CREATE OR REPLACE FUNCTION trg_log_order_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.order_status_history (
            order_id, old_status, new_status
        )
        VALUES (NEW.order_id, NULL, NEW.status);

    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO public.order_status_history (
            order_id, old_status, new_status
        )
        VALUES (NEW.order_id, OLD.status, NEW.status);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER log_order_status
AFTER INSERT OR UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION trg_log_order_status();


-- =========================================================
-- 3. ORDER ITEMS
-- =========================================================

CREATE OR REPLACE FUNCTION trg_validate_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_product public.products%ROWTYPE;
    v_order_id BIGINT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.order_id IS DISTINCT FROM OLD.order_id
           OR NEW.product_id IS DISTINCT FROM OLD.product_id THEN
            RAISE EXCEPTION 'Order item keys cannot be changed';
        END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_order_id := OLD.order_id;
    ELSE
        v_order_id := NEW.order_id;
    END IF;

    -- Serialize item changes and payments for the same order.
    SELECT * INTO v_order
    FROM public.orders
    WHERE order_id = v_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % does not exist', v_order_id;
    END IF;

    IF v_order.status <> 'pending' THEN
        RAISE EXCEPTION 'Items can only be changed for pending orders';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.payments
        WHERE order_id = v_order_id AND status = 'successful'
    ) THEN
        RAISE EXCEPTION 'Items cannot be changed after a successful payment';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    SELECT * INTO v_product
    FROM public.products
    WHERE product_id = NEW.product_id
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Product % does not exist', NEW.product_id;
    END IF;

    IF v_product.restaurant_id <> v_order.restaurant_id THEN
        RAISE EXCEPTION 'Product belongs to another restaurant';
    END IF;

    IF NOT v_product.is_available THEN
        RAISE EXCEPTION 'Product is unavailable';
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- Capture the current price as a historical sale price.
        NEW.unit_price := v_product.price;
    ELSIF NEW.unit_price IS DISTINCT FROM OLD.unit_price THEN
        RAISE EXCEPTION 'Historical unit price cannot be changed';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER validate_order_item
BEFORE INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW EXECUTE FUNCTION trg_validate_order_item();


-- Check at transaction end, after the order and its items exist.
CREATE OR REPLACE FUNCTION trg_require_order_items()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_id BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_order_id := OLD.order_id;
    ELSE
        v_order_id := NEW.order_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.orders WHERE order_id = v_order_id
    ) AND NOT EXISTS (
        SELECT 1 FROM public.order_items WHERE order_id = v_order_id
    ) THEN
        RAISE EXCEPTION 'Order % must contain at least one item', v_order_id;
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER require_items_after_order
AFTER INSERT ON orders
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION trg_require_order_items();

CREATE CONSTRAINT TRIGGER require_items_after_item_change
AFTER DELETE OR UPDATE ON order_items
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION trg_require_order_items();


-- =========================================================
-- 4. PAYMENTS
-- =========================================================

CREATE OR REPLACE FUNCTION trg_validate_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(30);
    v_paid NUMERIC;
    v_total NUMERIC;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Payment records must be retained';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.status <> 'pending' THEN
            RAISE EXCEPTION 'Finalized payments cannot be changed';
        END IF;

        IF NEW.payment_id IS DISTINCT FROM OLD.payment_id
           OR NEW.order_id IS DISTINCT FROM OLD.order_id
           OR NEW.payment_method_id IS DISTINCT FROM OLD.payment_method_id
           OR NEW.amount IS DISTINCT FROM OLD.amount THEN
            RAISE EXCEPTION 'Payment identity, order, method and amount are immutable';
        END IF;
    END IF;

    SELECT status INTO v_status
    FROM public.orders
    WHERE order_id = NEW.order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order does not exist';
    END IF;

    IF v_status = 'cancelled' AND NEW.status <> 'failed' THEN
        RAISE EXCEPTION 'Cannot accept payment for a cancelled order';
    END IF;

    PERFORM 1 FROM public.payment_methods
    WHERE payment_method_id = NEW.payment_method_id AND is_active
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment method does not exist or is inactive';
    END IF;

    IF NEW.status = 'successful' THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.order_items
            WHERE order_id = NEW.order_id
        ) THEN
            RAISE EXCEPTION 'Cannot pay an order without items';
        END IF;

        SELECT COALESCE(SUM(amount), 0) INTO v_paid
        FROM public.payments
        WHERE order_id = NEW.order_id
          AND status = 'successful';

        v_total := public.fn_order_total(NEW.order_id);

        IF v_paid + NEW.amount > v_total THEN
            RAISE EXCEPTION 'Payment exceeds remaining balance of % EUR',
                v_total - v_paid;
        END IF;

        NEW.paid_at := COALESCE(NEW.paid_at, CURRENT_TIMESTAMP);
    ELSE
        NEW.paid_at := NULL;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER validate_payment
BEFORE INSERT OR UPDATE OR DELETE ON payments
FOR EACH ROW EXECUTE FUNCTION trg_validate_payment();


-- =========================================================
-- 5. PRESERVE ADDRESS AND PRODUCT OWNERSHIP
-- =========================================================

CREATE OR REPLACE FUNCTION trg_protect_address()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW IS DISTINCT FROM OLD AND EXISTS (
        SELECT 1 FROM public.orders WHERE address_id = OLD.address_id
    ) THEN
        RAISE EXCEPTION
            'Address is used by an order; create a new address instead';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER protect_used_address
BEFORE UPDATE ON addresses
FOR EACH ROW EXECUTE FUNCTION trg_protect_address();


CREATE OR REPLACE FUNCTION trg_protect_product_restaurant()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id THEN
        RAISE EXCEPTION
            'A product cannot be moved to another restaurant; create a new product';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER protect_product_restaurant
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION trg_protect_product_restaurant();


-- =========================================================
-- 6. PROCEDURE: CREATE ORDER WITH ITEMS
-- =========================================================

CREATE OR REPLACE PROCEDURE sp_create_order(
    IN p_customer_id BIGINT,
    IN p_address_id BIGINT,
    IN p_restaurant_id BIGINT,
    IN p_delivery_fee NUMERIC,
    IN p_items JSONB,
    INOUT p_order_id BIGINT,
    IN p_notes TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_item JSONB;
    v_product_id BIGINT;
    v_quantity INTEGER;
    v_minimum NUMERIC;
    v_subtotal NUMERIC;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'Items must be a JSON array';
    END IF;

    IF jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'At least one product is required';
    END IF;

    INSERT INTO public.orders (
        customer_id, address_id, restaurant_id, delivery_fee, notes
    )
    VALUES (
        p_customer_id, p_address_id, p_restaurant_id,
        p_delivery_fee, p_notes
    )
    RETURNING order_id INTO p_order_id;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
    LOOP
        IF jsonb_typeof(v_item) <> 'object' THEN
            RAISE EXCEPTION 'Each item must be a JSON object';
        END IF;

        v_product_id := (v_item ->> 'product_id')::BIGINT;
        v_quantity := (v_item ->> 'quantity')::INTEGER;

        IF v_product_id IS NULL
           OR v_quantity IS NULL
           OR v_quantity <= 0 THEN
            RAISE EXCEPTION 'Each item needs product_id and positive quantity';
        END IF;

        INSERT INTO public.order_items (
            order_id, product_id, quantity, unit_price
        )
        VALUES (
            p_order_id, v_product_id, v_quantity, 0
        );
        -- Trigger replaces 0 with the product's current price.
        -- Duplicate product IDs are rejected by the composite PK.
    END LOOP;

    SELECT minimum_order_amount INTO v_minimum
    FROM public.restaurants
    WHERE restaurant_id = p_restaurant_id;

    SELECT SUM(quantity * unit_price) INTO v_subtotal
    FROM public.order_items
    WHERE order_id = p_order_id;

    IF v_subtotal < v_minimum THEN
        RAISE EXCEPTION 'Minimum food subtotal is % EUR', v_minimum;
    END IF;
END;
$$;


-- =========================================================
-- 7. PROCEDURE: ASSIGN COURIER
-- =========================================================

CREATE OR REPLACE PROCEDURE sp_assign_courier(
    IN p_order_id BIGINT,
    IN p_courier_id BIGINT,
    IN p_estimated_minutes INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_status VARCHAR(30);
    v_available BOOLEAN;
BEGIN
    IF p_estimated_minutes IS NULL OR p_estimated_minutes <= 0 THEN
        RAISE EXCEPTION 'Estimated minutes must be positive';
    END IF;

    SELECT status INTO v_order_status
    FROM public.orders
    WHERE order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order does not exist';
    END IF;

    IF v_order_status NOT IN ('confirmed', 'preparing', 'ready') THEN
        RAISE EXCEPTION
            'Courier assignment requires a confirmed, preparing or ready order';
    END IF;

    SELECT is_available INTO v_available
    FROM public.couriers
    WHERE courier_id = p_courier_id
    FOR UPDATE;

    IF NOT FOUND OR NOT v_available THEN
        RAISE EXCEPTION 'Courier does not exist or is unavailable';
    END IF;

    -- Coursework policy: one active delivery per courier.
    IF EXISTS (
        SELECT 1 FROM public.deliveries
        WHERE courier_id = p_courier_id
          AND status IN ('assigned', 'picked_up')
    ) THEN
        RAISE EXCEPTION 'Courier already has an active delivery';
    END IF;

    INSERT INTO public.deliveries (
        order_id, courier_id, status, assigned_at, estimated_minutes
    )
    VALUES (
        p_order_id, p_courier_id, 'assigned',
        CURRENT_TIMESTAMP, p_estimated_minutes
    )
    ON CONFLICT (order_id) DO UPDATE
    SET courier_id = EXCLUDED.courier_id,
        status = EXCLUDED.status,
        assigned_at = EXCLUDED.assigned_at,
        estimated_minutes = EXCLUDED.estimated_minutes
    WHERE deliveries.status = 'pending';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order already has an assigned or finalized delivery';
    END IF;
END;
$$;

-- Enforce one active delivery per courier even for direct SQL inserts.
CREATE UNIQUE INDEX ux_courier_active_delivery
ON deliveries(courier_id)
WHERE status IN ('assigned', 'picked_up');

COMMIT;