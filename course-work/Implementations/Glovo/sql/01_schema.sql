-- Glovo coursework: PostgreSQL schema
-- All monetary amounts are in EUR.
-- Run once in an empty glovo database.
-- Cross-table business rules will be added in the next script.

BEGIN;

CREATE TABLE customers (
    customer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(80) NOT NULL,
    last_name VARCHAR(80) NOT NULL,
    email VARCHAR(254) NOT NULL UNIQUE,
    phone VARCHAR(30) NOT NULL,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE addresses (
    address_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
    label VARCHAR(80),
    city VARCHAR(100) NOT NULL,
    district VARCHAR(100),
    street VARCHAR(150) NOT NULL,
    street_number VARCHAR(20) NOT NULL,
    postal_code VARCHAR(20),
    delivery_instructions TEXT
);

CREATE TABLE restaurants (
    restaurant_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    phone VARCHAR(30) NOT NULL,
    email VARCHAR(254),
    street_address TEXT NOT NULL,
    opening_time TIME NOT NULL,
    closing_time TIME NOT NULL,
    minimum_order_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    CONSTRAINT ck_restaurant_minimum
        CHECK (minimum_order_amount >= 0
               AND minimum_order_amount <> 'NaN'::numeric)
);

CREATE TABLE categories (
    category_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE products (
    product_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    restaurant_id BIGINT NOT NULL
        REFERENCES restaurants(restaurant_id),
    category_id BIGINT NOT NULL REFERENCES categories(category_id),
    name VARCHAR(150) NOT NULL,
    description TEXT,
    price NUMERIC(12,2) NOT NULL,
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT ck_product_price
        CHECK (price >= 0 AND price <> 'NaN'::numeric)
);

CREATE TABLE orders (
    order_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
    address_id BIGINT NOT NULL REFERENCES addresses(address_id),
    restaurant_id BIGINT NOT NULL
        REFERENCES restaurants(restaurant_id),
    ordered_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(30) NOT NULL DEFAULT 'pending',
    delivery_fee NUMERIC(12,2) NOT NULL DEFAULT 0,
    notes TEXT,

    CONSTRAINT ck_order_status CHECK (
        status IN (
            'pending',
            'confirmed',
            'preparing',
            'ready',
            'delivering',
            'delivered',
            'cancelled'
        )
    ),

    CONSTRAINT ck_order_delivery_fee
        CHECK (delivery_fee >= 0
               AND delivery_fee <> 'NaN'::numeric)
);

CREATE TABLE order_items (
    order_id BIGINT NOT NULL REFERENCES orders(order_id),
    product_id BIGINT NOT NULL REFERENCES products(product_id),
    quantity INTEGER NOT NULL,
    unit_price NUMERIC(12,2) NOT NULL,

    PRIMARY KEY (order_id, product_id),

    CONSTRAINT ck_item_quantity CHECK (quantity > 0),

    CONSTRAINT ck_item_unit_price
        CHECK (unit_price >= 0 AND unit_price <> 'NaN'::numeric)
);

CREATE TABLE payment_methods (
    payment_method_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(80) NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payments (
    payment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(order_id),
    payment_method_id BIGINT NOT NULL
        REFERENCES payment_methods(payment_method_id),
    amount NUMERIC(12,2) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'pending',
    paid_at TIMESTAMPTZ,
    transaction_reference VARCHAR(150) UNIQUE,

    CONSTRAINT ck_payment_amount
        CHECK (amount > 0 AND amount <> 'NaN'::numeric),

    CONSTRAINT ck_payment_status CHECK (
        status IN ('pending', 'successful', 'failed')
    ),

    CONSTRAINT ck_payment_paid_at CHECK (
        (status = 'successful' AND paid_at IS NOT NULL)
        OR
        (status IN ('pending', 'failed') AND paid_at IS NULL)
    )
);

CREATE TABLE couriers (
    courier_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(80) NOT NULL,
    last_name VARCHAR(80) NOT NULL,
    phone VARCHAR(30) NOT NULL,
    vehicle_type VARCHAR(30) NOT NULL,
    is_available BOOLEAN NOT NULL DEFAULT TRUE,

    CONSTRAINT ck_courier_vehicle CHECK (
        vehicle_type IN ('bicycle', 'motorcycle', 'car', 'on_foot')
    )
);

CREATE TABLE deliveries (
    delivery_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id BIGINT NOT NULL UNIQUE REFERENCES orders(order_id),
    courier_id BIGINT REFERENCES couriers(courier_id),
    status VARCHAR(30) NOT NULL DEFAULT 'pending',
    assigned_at TIMESTAMPTZ,
    picked_up_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    estimated_minutes INTEGER,

    CONSTRAINT ck_delivery_status CHECK (
        status IN (
            'pending', 'assigned', 'picked_up', 'delivered', 'cancelled'
        )
    ),

    CONSTRAINT ck_delivery_estimate
        CHECK (estimated_minutes > 0),

    CONSTRAINT ck_delivery_assignment CHECK (
        (courier_id IS NULL AND assigned_at IS NULL)
        OR
        (courier_id IS NOT NULL AND assigned_at IS NOT NULL)
    ),

    CONSTRAINT ck_delivery_pickup_time CHECK (
        picked_up_at IS NULL
        OR (
            assigned_at IS NOT NULL
            AND picked_up_at >= assigned_at
        )
    ),

    CONSTRAINT ck_delivery_completion_time CHECK (
        delivered_at IS NULL
        OR (
            picked_up_at IS NOT NULL
            AND delivered_at >= picked_up_at
        )
    ),

    CONSTRAINT ck_delivery_status_details CHECK (
        (
            status = 'pending'
            AND courier_id IS NULL
            AND picked_up_at IS NULL
            AND delivered_at IS NULL
        )
        OR (
            status = 'assigned'
            AND courier_id IS NOT NULL
            AND picked_up_at IS NULL
            AND delivered_at IS NULL
        )
        OR (
            status = 'picked_up'
            AND courier_id IS NOT NULL
            AND picked_up_at IS NOT NULL
            AND delivered_at IS NULL
        )
        OR (
            status = 'delivered'
            AND courier_id IS NOT NULL
            AND picked_up_at IS NOT NULL
            AND delivered_at IS NOT NULL
        )
        OR (
            status = 'cancelled'
            AND delivered_at IS NULL
        )
    )
);

CREATE TABLE order_status_history (
    history_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(order_id),
    old_status VARCHAR(30),
    new_status VARCHAR(30) NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT ck_history_old_status CHECK (
        old_status IN (
            'pending', 'confirmed', 'preparing', 'ready',
            'delivering', 'delivered', 'cancelled'
        )
    ),

    CONSTRAINT ck_history_new_status CHECK (
        new_status IN (
            'pending', 'confirmed', 'preparing', 'ready',
            'delivering', 'delivered', 'cancelled'
        )
    ),

    CONSTRAINT ck_history_status_changed
        CHECK (old_status IS DISTINCT FROM new_status)
);

-- Indexes for foreign keys and common lookups.
-- Primary keys and UNIQUE constraints already create their own indexes.

CREATE INDEX ix_addresses_customer
    ON addresses(customer_id);

CREATE INDEX ix_products_restaurant
    ON products(restaurant_id);

CREATE INDEX ix_products_category
    ON products(category_id);

CREATE INDEX ix_orders_customer
    ON orders(customer_id);

CREATE INDEX ix_orders_address
    ON orders(address_id);

CREATE INDEX ix_orders_restaurant
    ON orders(restaurant_id);

CREATE INDEX ix_orders_ordered_at
    ON orders(ordered_at);

CREATE INDEX ix_order_items_product
    ON order_items(product_id);

CREATE INDEX ix_payments_order
    ON payments(order_id);

CREATE INDEX ix_payments_method
    ON payments(payment_method_id);

CREATE INDEX ix_deliveries_courier
    ON deliveries(courier_id);

CREATE INDEX ix_history_order_changed
    ON order_status_history(order_id, changed_at);

COMMIT;