-- One-time database setup, run as the RDS master user through the SSM tunnel:
--   make tunnel-db   (separate terminal)
--   make db-bootstrap
-- Idempotent, and always run with psql --single-transaction so a failure leaves
-- nothing half-applied.

CREATE TABLE IF NOT EXISTS messages (
    id    integer PRIMARY KEY,
    value text    NOT NULL
);

INSERT INTO messages (id, value) VALUES (1, '5') ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'lab_app') THEN
        CREATE ROLE lab_app LOGIN; -- no password: the backend logs in with IAM tokens
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'rds_iam') THEN
        GRANT rds_iam TO lab_app; -- RDS only; skipped on plain PostgreSQL (kind e2e)
    END IF;
END
$$;

-- Read-only: the application can query the value but never change it.
GRANT SELECT ON messages TO lab_app;
