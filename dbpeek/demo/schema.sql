-- Demo dataset for DB Peek. Rebuild with: sqlite3 demo.db < schema.sql
-- (a committed demo.db is shipped alongside this file for zero-setup testing).
PRAGMA foreign_keys = ON;

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
  id            INTEGER PRIMARY KEY,
  employee_no   TEXT NOT NULL UNIQUE,
  first_name    TEXT NOT NULL,
  last_name     TEXT NOT NULL,
  email         TEXT NOT NULL,
  department_id INTEGER REFERENCES departments(id),
  salary        REAL,
  hire_date     TEXT,
  status        TEXT,
  notes         TEXT
);

CREATE TABLE products (
  id       INTEGER PRIMARY KEY,
  sku      TEXT NOT NULL UNIQUE,
  name     TEXT NOT NULL,
  price    REAL NOT NULL,
  stock    INTEGER NOT NULL DEFAULT 0,
  category TEXT
);

INSERT INTO departments (id, name, code, location) VALUES
  (1, 'Engineering', 'ENG', 'Jakarta'),
  (2, 'Finance',     'FIN', 'Jakarta'),
  (3, 'Operations',  'OPS', 'Surabaya'),
  (4, 'People',      'HR',  'Bandung');

-- 60 rows so the table view has more than one page at the default page size.
WITH RECURSIVE seq(n) AS (
  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 60
)
INSERT INTO employees (employee_no, first_name, last_name, email, department_id, salary, hire_date, status, notes)
SELECT
  printf('EMP-%05d', n),
  CASE (n % 8)
    WHEN 1 THEN 'Klara' WHEN 2 THEN 'Bagas' WHEN 3 THEN 'Sinta' WHEN 4 THEN 'Andi'
    WHEN 5 THEN 'Maya'  WHEN 6 THEN 'Rizky' WHEN 7 THEN 'Dewi'  ELSE 'Tono' END,
  'Lastname' || n,
  'user' || n || '@demo.local',
  ((n - 1) % 4) + 1,
  ROUND(45000 + (n * 1337) % 60000, 2),
  DATE('2021-01-01', '+' || (n % 900) || ' days'),
  CASE WHEN n % 7 = 0 THEN 'probation' ELSE 'active' END,
  CASE WHEN n % 5 = 0 THEN 'Follow up with manager' ELSE NULL END
FROM seq;

INSERT INTO products (sku, name, price, stock, category) VALUES
  ('SKU-1001', 'Mechanical Keyboard', 89.90,  42, 'Accessories'),
  ('SKU-1002', 'Ergonomic Mouse',     45.50, 120, 'Accessories'),
  ('SKU-1003', '27" IPS Monitor',    219.00,  18, 'Displays'),
  ('SKU-1004', 'USB-C Hub',           39.99,  75, 'Accessories'),
  ('SKU-1005', 'Noise-cancel Headset',129.00, 30, 'Audio'),
  ('SKU-1006', 'Laptop Stand',        25.00, 200, 'Furniture'),
  ('SKU-1007', 'Desk Lamp',           32.75,  64, 'Furniture'),
  ('SKU-1008', 'Webcam 1080p',        59.00,   0, 'Video');
