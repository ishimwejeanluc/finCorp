-- Runs once, on first Postgres startup (when the data volume is empty).
-- Re-running requires `docker compose down -v` to wipe pgdata.

BEGIN;

CREATE TABLE IF NOT EXISTS products (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    price       NUMERIC(10, 2) NOT NULL CHECK (price >= 0),
    stock       INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS products_name_idx ON products (name);

INSERT INTO products (name, price, stock)
SELECT v.name, v.price, v.stock
FROM (
    VALUES
        ('Widget', 9.99, 100),
        ('Sprocket', 14.50, 50),
        ('Gizmo', 24.00, 25),
        ('Cog', 4.75, 500),
        ('Thingamajig', 49.99, 10)
) AS v(name, price, stock)
WHERE NOT EXISTS (
    SELECT 1 FROM products p WHERE p.name = v.name
);

COMMIT;
