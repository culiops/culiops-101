-- Seed a realistic "production" table: 5000 orders.
-- This is the golden state we back up, destroy, and must restore exactly.
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    id             serial PRIMARY KEY,
    customer_email text        NOT NULL,
    amount         numeric(10,2) NOT NULL,
    status         text        NOT NULL DEFAULT 'paid',
    created_at     timestamptz NOT NULL DEFAULT now()
);

INSERT INTO orders (customer_email, amount, status, created_at)
SELECT
    'user' || g || '@example.com',
    round((random() * 500 + 10)::numeric, 2),
    (ARRAY['paid', 'pending', 'refunded'])[1 + floor(random() * 3)::int],
    now() - (random() * interval '90 days')
FROM generate_series(1, 5000) AS g;

CREATE INDEX idx_orders_email ON orders (customer_email);

SELECT count(*) AS seeded_rows FROM orders;
