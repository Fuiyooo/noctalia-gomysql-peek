-- DB Peek demo dataset — MySQL / MariaDB (10.2+ for the recursive CTE).
--
--   mysql -u root -p < mysql.sql
--
-- Creates the `dbpeek_demo` database with departments, employees (60 rows)
-- and products. Then add a connection in DB Peek: driver MySQL, host
-- 127.0.0.1, port 3306, database dbpeek_demo.

CREATE DATABASE IF NOT EXISTS dbpeek_demo CHARACTER SET utf8mb4;
USE dbpeek_demo;

DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS departments;
DROP TABLE IF EXISTS products;

CREATE TABLE departments (
  id       INT PRIMARY KEY,
  name     VARCHAR(80) NOT NULL,
  code     VARCHAR(10) NOT NULL,
  location VARCHAR(80)
) ENGINE = InnoDB;

CREATE TABLE employees (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  employee_no   VARCHAR(20) NOT NULL UNIQUE,
  first_name    VARCHAR(60) NOT NULL,
  last_name     VARCHAR(60) NOT NULL,
  email         VARCHAR(120) NOT NULL,
  department_id INT,
  salary        DECIMAL(12, 2),
  hire_date     DATE,
  status        VARCHAR(20),
  notes         VARCHAR(255),
  CONSTRAINT fk_emp_dept FOREIGN KEY (department_id) REFERENCES departments (id)
) ENGINE = InnoDB;

CREATE TABLE products (
  id       INT AUTO_INCREMENT PRIMARY KEY,
  sku      VARCHAR(20) NOT NULL UNIQUE,
  name     VARCHAR(120) NOT NULL,
  price    DECIMAL(10, 2) NOT NULL,
  stock    INT NOT NULL DEFAULT 0,
  category VARCHAR(60)
) ENGINE = InnoDB;

INSERT INTO departments (id, name, code, location) VALUES
  (1, 'Engineering', 'ENG', 'Jakarta'),
  (2, 'Finance',     'FIN', 'Jakarta'),
  (3, 'Operations',  'OPS', 'Surabaya'),
  (4, 'People',      'HR',  'Bandung');

INSERT INTO employees (employee_no, first_name, last_name, email, department_id, salary, hire_date, status, notes)
WITH RECURSIVE seq(n) AS (
  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 60
)
SELECT
  CONCAT('EMP-', LPAD(n, 5, '0')),
  CASE (n % 8)
    WHEN 1 THEN 'Klara' WHEN 2 THEN 'Bagas' WHEN 3 THEN 'Sinta' WHEN 4 THEN 'Andi'
    WHEN 5 THEN 'Maya'  WHEN 6 THEN 'Rizky' WHEN 7 THEN 'Dewi'  ELSE 'Tono' END,
  CONCAT('Lastname', n),
  CONCAT('user', n, '@demo.local'),
  ((n - 1) % 4) + 1,
  ROUND(45000 + MOD(n * 1337, 60000), 2),
  DATE_ADD('2021-01-01', INTERVAL (n % 900) DAY),
  IF(n % 7 = 0, 'probation', 'active'),
  IF(n % 5 = 0, 'Follow up with manager', NULL)
FROM seq;

INSERT INTO products (sku, name, price, stock, category) VALUES
  ('SKU-1001', 'Mechanical Keyboard',  89.90,  42, 'Accessories'),
  ('SKU-1002', 'Ergonomic Mouse',      45.50, 120, 'Accessories'),
  ('SKU-1003', '27" IPS Monitor',     219.00,  18, 'Displays'),
  ('SKU-1004', 'USB-C Hub',            39.99,  75, 'Accessories'),
  ('SKU-1005', 'Noise-cancel Headset',129.00,  30, 'Audio'),
  ('SKU-1006', 'Laptop Stand',         25.00, 200, 'Furniture'),
  ('SKU-1007', 'Desk Lamp',            32.75,  64, 'Furniture'),
  ('SKU-1008', 'Webcam 1080p',         59.00,   0, 'Video');
