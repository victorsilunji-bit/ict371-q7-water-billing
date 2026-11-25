-- ============================================================================
-- ICT371 Advanced Database - Question 7: Water Meter Readings and Billing
-- ============================================================================

-- (a) Database and seed data (Tables & Constraints)
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(12, 2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12, 2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_customer_reading_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12, 2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on      DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14, 2) NOT NULL CHECK (total_due >= 0)
);

-- (b) Function: fn_water_charge
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption units (%) cannot be NULL or negative.', p_units;
    END IF;

    IF p_units = 0 THEN
        RETURN 0.00;
    ELSIF p_units <= 10 THEN
        RETURN ROUND(p_units * 5.00, 2);
    ELSE
        RETURN ROUND((10 * 5.00) + ((p_units - 10) * 8.00), 2);
    END IF;
END;
$$;

-- (c) Procedure: pr_generate_bill
CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(12, 2);
    v_curr   NUMERIC(12, 2);
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL.';
    END IF;

    SELECT previous_reading, current_reading
      INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'A bill already exists for reading_id %.', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE trigger on readings
CREATE OR REPLACE FUNCTION trg_fn_validate_meter_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Invalid meter reading: current_reading (%) cannot be less than previous_reading (%).',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_validate_meter
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_validate_meter_reading();

-- (a continued) Seed Data: 3 customers and 6 readings (0, exactly 10, >10 units)
INSERT INTO customers (full_name) VALUES
    ('Chisomo Banda'),
    ('Lombe Mutale'),
    ('Patrick Siame');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00), -- 0 units
    (1, DATE '2026-10-01', 100.00, 110.00), -- Exactly 10 units (K50)
    (2, DATE '2026-09-01', 250.00, 268.00), -- 18 units (K50 + K64 = K114)
    (2, DATE '2026-10-01', 268.00, 278.00), -- Exactly 10 units (K50)
    (3, DATE '2026-09-01', 500.00, 525.00), -- 25 units (K50 + K120 = K170)
    (3, DATE '2026-10-01', 525.00, 525.00); -- 0 units

CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE - 5);
CALL pr_generate_bill(3, CURRENT_DATE - 15);
UPDATE bills SET amount_paid = 50.00 WHERE bill_id = 3; -- Partially paid overdue bill
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 10);

-- (e) View: v_overdue_bills
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       (b.charge - b.amount_paid) AS outstanding_amount
  FROM bills b
  JOIN readings r  ON r.reading_id  = b.reading_id
  JOIN customers c ON c.customer_id = r.customer_id
 WHERE b.due_on < CURRENT_DATE
   AND b.amount_paid < b.charge;

-- (f) Index and EXPLAIN
-- Justification: A partial B-tree index on due_on filtered by (amount_paid < charge)
-- indexes only unpaid/partially paid bills, enabling fast range scans for overdue bills.
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN ANALYZE
SELECT bill_id, reading_id, due_on, (charge - amount_paid) AS balance
  FROM bills
 WHERE due_on < CURRENT_DATE
   AND amount_paid < charge;

-- (g) Scheduled Job: pr_refresh_receivables
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(14, 2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00)
      INTO v_total_due
      FROM bills
     WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total_due)
    ON CONFLICT (snapshot_date) DO UPDATE
       SET total_due = EXCLUDED.total_due;
END;
$$;

-- Schedule daily at 00:30
SELECT cron.schedule(
    'refresh_water_receivables',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);