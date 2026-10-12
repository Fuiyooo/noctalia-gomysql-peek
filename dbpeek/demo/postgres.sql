-- DB Peek demo dataset — PostgreSQL.
--
--   psql -h 127.0.0.1 -U postgres -f postgres.sql
--
-- Creates the `dbpeek_demo` database with departments, employees (60 rows)
-- and products. Then add a connection in DB Peek: driver PostgreSQL, host
-- 127.0.0.1, port 5432, database dbpeek_demo.

-- Create the database only if it does not exist, then switch to it.
SELECT 'CREATE DATABASE dbpeek_demo'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dbpeek_demo')\gexec

\connect dbpeek_demo

DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS departments;
DROP TABLE IF EXISTS products;

CREATE TABLE departments (
  id       INTEGER PRIMARY KEY,
  name     TEXT NOT NULL,
  code     TEXT NOT NULL,
  location TEXT
);

CREATE TABLE employees (
  id            SERIAL PRIMARY KEY,
  employee_no   TEXT NOT NULL UNIQUE,
  first_name    TEXT NOT NULL,
  last_name     TEXT NOT NULL,
  email         TEXT NOT NULL,
  department_id INTEGER REFERENCES departments (id),
  salary        NUMERIC(12, 2),
  hire_date     DATE,
  status        TEXT,
  notes         TEXT
);

CREATE TABLE products (
  id       SERIAL PRIMARY KEY,
  sku      TEXT NOT NULL UNIQUE,
  name     TEXT NOT NULL,
  price    NUMERIC(10, 2) NOT NULL,
  stock    INTEGER NOT NULL DEFAULT 0,
  category TEXT
);

INSERT INTO departments (id, name, code, location) VALUES
  (1, 'Engineering', 'ENG', 'Jakarta'),
  (2, 'Finance',     'FIN', 'Jakarta'),
  (3, 'Operations',  'OPS', 'Surabaya'),
  (4, 'People',      'HR',  'Bandung');

INSERT INTO employees (employee_no, first_name, last_name, email, department_id, salary, hire_date, status, notes)
SELECT
  'EMP-' || lpad(n::text, 5, '0'),
  (ARRAY['Tono', 'Klara', 'Bagas', 'Sinta', 'Andi', 'Maya', 'Rizky', 'Dewi'])[(n % 8) + 1],
  'Lastname' || n,
  'user' || n || '@demo.local',
  ((n - 1) % 4) + 1,
  round((45000 + (n * 1337) % 60000)::numeric, 2),
  DATE '2021-01-01' + (n % 900),
  CASE WHEN n % 7 = 0 THEN 'probation' ELSE 'active' END,
  CASE WHEN n % 5 = 0 THEN 'Follow up with manager' END
FROM generate_series(1, 60) AS n;

INSERT INTO products (sku, name, price, stock, category) VALUES
  ('SKU-1001', 'Mechanical Keyboard',  89.90,  42, 'Accessories'),
  ('SKU-1002', 'Ergonomic Mouse',      45.50, 120, 'Accessories'),
  ('SKU-1003', '27" IPS Monitor',     219.00,  18, 'Displays'),
  ('SKU-1004', 'USB-C Hub',            39.99,  75, 'Accessories'),
  ('SKU-1005', 'Noise-cancel Headset',129.00,  30, 'Audio'),
  ('SKU-1006', 'Laptop Stand',         25.00, 200, 'Furniture'),
  ('SKU-1007', 'Desk Lamp',            32.75,  64, 'Furniture'),
  ('SKU-1008', 'Webcam 1080p',         59.00,   0, 'Video');
