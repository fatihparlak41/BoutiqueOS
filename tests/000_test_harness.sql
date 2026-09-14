-- ============================================================
-- BoutiqueOS  •  Test harness  •  Rev 3
-- PLAIN PostgreSQL MODE ONLY (db_fresh.ps1 default mode).
-- NOT applied in -Mode Supabase (Supabase provides auth schema + roles).
-- ============================================================
-- Emulates the Supabase pieces the migrations depend on:
--   roles anon / authenticated / service_role (NOLOGIN)
--   schema auth, table auth.users, function auth.uid()
--   default privileges equivalent to Supabase (so REVOKE/GRANT logic
--   in migrations is exercised the same way)
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')          THEN CREATE ROLE anon NOLOGIN;          END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role')  THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
-- Supabase-equivalent default privileges (objects created later by this role)
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS auth.users (
  id                UUID PRIMARY KEY,
  instance_id       UUID,
  aud               TEXT,
  role              TEXT,
  email             TEXT UNIQUE,
  -- Phase 4B reads this: an unconfirmed address must not be able to claim a seat.
  -- Defaults to confirmed so existing fixtures behave as before; tests that need an
  -- unverified account set it to NULL explicitly.
  email_confirmed_at TIMESTAMPTZ DEFAULT now(),
  -- Supabase stores options.data of an admin invite here. Phase 4B deliberately puts
  -- nothing of its own in it; T45 asserts that.
  raw_user_meta_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  raw_app_meta_data  JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Same resolution order as Supabase: request.jwt.claim.sub, then request.jwt.claims->>'sub'
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::UUID;
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.role', true), ''),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  );
$$;

GRANT EXECUTE ON FUNCTION auth.uid()  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated, service_role;
GRANT SELECT ON auth.users TO service_role;

-- ------------------------------------------------------------
-- storage shim (Phase 6A): the subset of Supabase Storage's schema that the
-- product-images migration touches — buckets, objects, foldername(). Column names and
-- the folder helper match the real service so the same policies apply in both modes.
-- ------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 TEXT PRIMARY KEY,
  name               TEXT NOT NULL UNIQUE,
  owner              UUID,
  public             BOOLEAN NOT NULL DEFAULT false,
  file_size_limit    BIGINT,
  allowed_mime_types TEXT[],
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id        TEXT NOT NULL REFERENCES storage.buckets(id),
  name             TEXT NOT NULL,
  owner            UUID,
  owner_id         TEXT,
  metadata         JSONB,
  user_metadata    JSONB,
  version          TEXT,
  path_tokens      TEXT[] GENERATED ALWAYS AS (string_to_array(name, '/')) STORED,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_accessed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (bucket_id, name)
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Supabase: every path segment except the last (the file name).
CREATE OR REPLACE FUNCTION storage.foldername(name TEXT)
RETURNS TEXT[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE _parts TEXT[];
BEGIN
  SELECT string_to_array(name, '/') INTO _parts;
  RETURN _parts[1 : array_length(_parts, 1) - 1];
END $$;

GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
GRANT ALL ON storage.buckets, storage.objects TO anon, authenticated, service_role;
