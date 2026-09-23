-- =========================================================
-- Manufacturing Performance Analysis
-- PostgreSQL
-- Database: manufacturing_operations
-- =========================================================

-- Create the database once, then connect to it before running the rest.
-- CREATE DATABASE manufacturing_operations;


-- =========================================================
-- 1. CREATE TABLES
-- =========================================================

CREATE TABLE IF NOT EXISTS line_productivity (
    sr_no INTEGER,
    production_date DATE,
    product VARCHAR(20),
    batch INTEGER PRIMARY KEY,
    operator_name VARCHAR(50),
    start_time TIME,
    end_time TIME,
    actual_production_time_mins INTEGER,
    min_batch_time_mins INTEGER,
    production_variance_mins INTEGER,
    production_efficiency NUMERIC(6,2)
);

CREATE TABLE IF NOT EXISTS products (
    product VARCHAR(20) PRIMARY KEY,
    soda_flavor VARCHAR(50),
    size VARCHAR(20),
    min_batch_time_mins INTEGER
);

CREATE TABLE IF NOT EXISTS line_downtime (
    batch INTEGER PRIMARY KEY,
    emergency_stop INTEGER,
    batch_change INTEGER,
    labeling_error INTEGER,
    inventory_shortage INTEGER,
    product_spill INTEGER,
    machine_adjustment INTEGER,
    machine_failure INTEGER,
    batch_coding_error INTEGER,
    conveyor_belt_jam INTEGER,
    calibration_error INTEGER,
    label_switch INTEGER,
    other INTEGER,
    total_downtime INTEGER
);

CREATE TABLE IF NOT EXISTS downtime_factors (
    factor VARCHAR(50) PRIMARY KEY,
    description VARCHAR(255),
    operator_error VARCHAR(10)
);

-- Data for these tables was imported from the project CSV files
-- using pgAdmin's Import/Export Data option.


-- =========================================================
-- 2. QUICK DATA CHECKS
-- =========================================================

SELECT COUNT(*) AS line_productivity_rows
FROM line_productivity;

SELECT COUNT(*) AS line_downtime_rows
FROM line_downtime;

SELECT COUNT(*) AS products_rows
FROM products;

SELECT COUNT(*) AS downtime_factors_rows
FROM downtime_factors;


-- =========================================================
-- 3. TRANSFORM DOWNTIME DATA FROM WIDE TO LONG FORMAT
-- =========================================================

CREATE OR REPLACE VIEW downtime_long AS
SELECT
    ld.batch,
    x.factor,
    x.downtime_mins
FROM line_downtime ld
CROSS JOIN LATERAL (
    VALUES
        ('1', ld.emergency_stop),
        ('2', ld.batch_change),
        ('3', ld.labeling_error),
        ('4', ld.inventory_shortage),
        ('5', ld.product_spill),
        ('6', ld.machine_adjustment),
        ('7', ld.machine_failure),
        ('8', ld.batch_coding_error),
        ('9', ld.conveyor_belt_jam),
        ('10', ld.calibration_error),
        ('11', ld.label_switch),
        ('12', ld.other)
) AS x(factor, downtime_mins)
WHERE COALESCE(x.downtime_mins, 0) > 0;


-- =========================================================
-- 4. ADD DOWNTIME REASON + OPERATOR ERROR CLASSIFICATION
-- =========================================================

CREATE OR REPLACE VIEW downtime_analysis AS
SELECT
    dl.batch,
    dl.factor,
    df.description AS downtime_reason,
    df.operator_error,
    dl.downtime_mins
FROM downtime_long dl
LEFT JOIN downtime_factors df
    ON dl.factor = df.factor;


-- =========================================================
-- 5. BUILD BATCH PERFORMANCE VIEW
-- =========================================================

CREATE OR REPLACE VIEW batch_performance AS
SELECT
    lp.sr_no,
    lp.production_date,
    lp.product,
    p.soda_flavor,
    p.size,
    lp.batch,
    lp.operator_name,
    lp.start_time,
    lp.end_time,
    lp.actual_production_time_mins,
    lp.min_batch_time_mins,
    lp.production_variance_mins,
    lp.production_efficiency,
    ld.total_downtime
FROM line_productivity lp
LEFT JOIN products p
    ON lp.product = p.product
LEFT JOIN line_downtime ld
    ON lp.batch = ld.batch;


-- =========================================================
-- 6. BUILD DETAILED DOWNTIME VIEW
-- =========================================================

CREATE OR REPLACE VIEW downtime_detail AS
SELECT
    da.batch,
    lp.production_date,
    lp.product,
    p.soda_flavor,
    p.size,
    lp.operator_name,
    da.factor,
    da.downtime_reason,
    da.operator_error,
    da.downtime_mins
FROM downtime_analysis da
LEFT JOIN line_productivity lp
    ON da.batch = lp.batch
LEFT JOIN products p
    ON lp.product = p.product;


-- =========================================================
-- 7. ANALYSIS QUERIES
-- =========================================================

-- Q1. Which downtime reasons cause the most downtime?
SELECT
    downtime_reason,
    SUM(downtime_mins) AS total_downtime_mins
FROM downtime_detail
GROUP BY downtime_reason
ORDER BY total_downtime_mins DESC;


-- Q2. What percentage of total downtime does each reason contribute?
SELECT
    downtime_reason,
    SUM(downtime_mins) AS total_downtime_mins,
    ROUND(
        100.0 * SUM(downtime_mins)
        / SUM(SUM(downtime_mins)) OVER (),
        2
    ) AS downtime_percentage
FROM downtime_detail
GROUP BY downtime_reason
ORDER BY total_downtime_mins DESC;


-- Q3. How does production efficiency vary by product / flavor / size?
SELECT
    product,
    soda_flavor,
    size,
    COUNT(*) AS total_batches,
    ROUND(AVG(production_efficiency), 2) AS avg_efficiency_pct,
    SUM(total_downtime) AS total_downtime_mins,
    ROUND(AVG(production_variance_mins), 2) AS avg_production_variance_mins
FROM batch_performance
GROUP BY product, soda_flavor, size
ORDER BY avg_efficiency_pct ASC;


-- Q4. Which operators have the strongest / weakest overall performance?
SELECT
    operator_name,
    COUNT(*) AS total_batches,
    ROUND(AVG(production_efficiency), 2) AS avg_efficiency_pct,
    SUM(total_downtime) AS total_downtime_mins,
    ROUND(AVG(total_downtime), 2) AS avg_downtime_per_batch
FROM batch_performance
GROUP BY operator_name
ORDER BY avg_efficiency_pct ASC;


-- Q5. What share of downtime is operator-related vs non-operator-related?
SELECT
    operator_error,
    SUM(downtime_mins) AS total_downtime_mins,
    ROUND(
        100.0 * SUM(downtime_mins)
        / SUM(SUM(downtime_mins)) OVER (),
        2
    ) AS downtime_percentage
FROM downtime_detail
GROUP BY operator_error
ORDER BY total_downtime_mins DESC;


-- Q6. Which operator-related causes create the most downtime?
SELECT
    downtime_reason,
    SUM(downtime_mins) AS total_downtime_mins,
    ROUND(
        100.0 * SUM(downtime_mins)
        / SUM(SUM(downtime_mins)) OVER (),
        2
    ) AS percentage_of_operator_downtime
FROM downtime_detail
WHERE operator_error = 'Yes'
GROUP BY downtime_reason
ORDER BY total_downtime_mins DESC;


-- Q7. Which batches have the highest production-time variance?
SELECT
    batch,
    production_date,
    product,
    operator_name,
    actual_production_time_mins,
    min_batch_time_mins,
    production_variance_mins,
    production_efficiency,
    total_downtime
FROM batch_performance
ORDER BY production_variance_mins DESC
LIMIT 10;


-- Q8. Drill down into the downtime causes of the worst-performing batches.
SELECT
    batch,
    product,
    operator_name,
    downtime_reason,
    operator_error,
    downtime_mins
FROM downtime_detail
WHERE batch IN (422147, 422111, 422123, 422146, 422118)
ORDER BY batch, downtime_mins DESC;


-- Q9. What are the major downtime causes for each operator?
SELECT
    operator_name,
    downtime_reason,
    SUM(downtime_mins) AS total_downtime_mins
FROM downtime_detail
GROUP BY operator_name, downtime_reason
ORDER BY operator_name, total_downtime_mins DESC;


-- =========================================================
-- 8. OPTIONAL FINAL CHECKS
-- =========================================================

SELECT * FROM batch_performance;
SELECT * FROM downtime_detail;
