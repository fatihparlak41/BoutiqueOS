-- ============================================================
-- ButikOS — Test Harness (NOT a real migration)
-- Supabase compatibility shim for local PostgreSQL testing
-- Apply BEFORE 001_schema.sql in the disposable test database only
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- MOCK: auth schema + auth.users (Supabase built-in)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email         TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- auth.uid() — reads GUC app.current_user_id set by test helpers
-- In Supabase this reads the JWT sub claim; here we use a GUC.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    current_setting('app.current_user_id', true)::UUID,
    '00000000-0000-0000-0000-000000000000'::UUID
  );
$$;

-- auth.role() — returns 'authenticated' when a user is set, 'anon' otherwise
CREATE OR REPLACE FUNCTION auth.role()
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN current_setting('app.current_user_id', true) IS NOT NULL
     AND current_setting('app.current_user_id', true) <> ''
    THEN 'authenticated'
    ELSE 'anon'
  END;
$$;


-- ============================================================
-- TEST HELPER: set active user (mimics Supabase JWT context)
-- ============================================================
CREATE OR REPLACE FUNCTION test_set_user(p_user_id UUID)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.current_user_id', p_user_id::TEXT, false);
$$;

CREATE OR REPLACE FUNCTION test_clear_user()
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.current_user_id', '', false);
$$;


-- ============================================================
-- PRE-SEED: Insert test auth users
-- (profiles will be inserted after 001 creates the table)
-- ============================================================
-- We insert these UUIDs to be referenced later in tests.
-- Pin UUIDs so tests are deterministic.

INSERT INTO auth.users (id, email) VALUES
  ('aaaaaaaa-0001-0000-0000-000000000000', 'owner@tlc.test'),
  ('aaaaaaaa-0002-0000-0000-000000000000', 'manager@tlc.test'),
  ('aaaaaaaa-0003-0000-0000-000000000000', 'staff@tlc.test'),
  ('aaaaaaaa-0004-0000-0000-000000000000', 'outsider@other.test')
ON CONFLICT (id) DO NOTHING;


-- ============================================================
-- END OF TEST HARNESS
-- ============================================================
