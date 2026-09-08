-- ============================================================
-- ButikOS — Things Like Crop
-- Supabase PostgreSQL Schema  •  Migration 003
-- Pilot form findings  •  Rev 3  •  2026-09-08
-- ============================================================
-- Changes in this migration:
--   1. fx_rates: versioned immutable table
--   2. rpc_set_fx_rate: SECURITY DEFINER, correct insert order
--      (lock → UPDATE old is_current=false → INSERT new → UPDATE superseded_by)
--
-- NOT in this migration (already handled elsewhere):
--   - sale_payments FX columns: in 002_schema_cont.sql CREATE TABLE
--   - register_session_currency_counts: in 002_schema_cont.sql
--   - accounting role (ALTER TYPE user_role): deferred
--   - markup_multiplier: removed; UX-only concern
--   - TLC seed data: see seed_things_like_crop.sql
-- ============================================================
-- SECURITY MODEL:
--   - All FX rate writes go through rpc_set_fx_rate only.
--   - Direct client INSERT is NOT permitted (no INSERT policy).
--   - UPDATE and DELETE are permanently blocked (no policies for those ops).
--   - Historical rate records are preserved indefinitely.
-- ============================================================


-- ============================================================
-- 1. FX_RATES — Versioned, immutable historical exchange rates
-- ============================================================
-- ADR: FX rate records are immutable historical facts.
-- Updates and deletes are BLOCKED (no UPDATE/DELETE policies).
-- Corrections: rpc_set_fx_rate inserts a superseding record and
-- marks the old one is_current = false. Full correction history
-- preserved without any UPDATE to amounts or existing rows' data.
--
-- rate_to_try: 1 unit of currency = N TRY (e.g., GBP rate ~42)

CREATE TABLE IF NOT EXISTS fx_rates (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id    UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  rate_date      DATE NOT NULL,
  currency       TEXT NOT NULL
                   CONSTRAINT chk_fx_currency
                   CHECK (currency IN ('GBP','EUR','USD')),  -- TRY needs no rate
  rate_to_try    NUMERIC(12,6) NOT NULL CONSTRAINT chk_fx_rate_pos CHECK (rate_to_try > 0),
  -- 'manual' (entered by owner/manager) | 'tcmb' (API, future use)
  source         TEXT NOT NULL DEFAULT 'manual',
  -- Versioning: only one current record per (business, date, currency)
  is_current     BOOLEAN NOT NULL DEFAULT true,
  -- Set by rpc_set_fx_rate when this record is superseded by a correction
  superseded_by  UUID REFERENCES fx_rates(id),
  created_by     UUID REFERENCES profiles(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- Note: NO updated_at — this table is INSERT-only; the only post-insert
  -- mutation is rpc_set_fx_rate updating superseded_by + is_current via
  -- SECURITY DEFINER, which bypasses RLS. No client can UPDATE any row.
);

-- Exactly one current rate per (business, date, currency)
-- This partial UNIQUE index is what rpc_set_fx_rate must not violate.
-- Correct insert order: mark old as is_current=false BEFORE inserting new.
CREATE UNIQUE INDEX IF NOT EXISTS uix_fx_rates_current
  ON fx_rates (business_id, rate_date, currency)
  WHERE is_current = true;

-- Fast lookup for today's rate(s)
CREATE INDEX IF NOT EXISTS idx_fx_rates_lookup
  ON fx_rates (business_id, rate_date DESC, currency)
  WHERE is_current = true;

-- Audit trail: all records for a given business/currency across dates
CREATE INDEX IF NOT EXISTS idx_fx_rates_history
  ON fx_rates (business_id, currency, rate_date DESC);


-- ============================================================
-- 2. RLS — FX_RATES
-- ============================================================

ALTER TABLE fx_rates ENABLE ROW LEVEL SECURITY;

-- All members can read current rates (for FX display and sale validation)
CREATE POLICY "fx_rates_select" ON fx_rates
  FOR SELECT USING (fn_is_member(business_id));

-- NO INSERT policy: all writes go through rpc_set_fx_rate (SECURITY DEFINER).
-- Direct client INSERT is blocked.

-- NO UPDATE policy: FX records are immutable. rpc_set_fx_rate uses
-- SECURITY DEFINER to bypass RLS for the superseded_by + is_current update.

-- NO DELETE policy: historical rates are preserved indefinitely.


-- ============================================================
-- 3. RPC_SET_FX_RATE — Manager-only rate entry and correction
-- ============================================================
-- Purpose: Insert today's (or any date's) exchange rate for a foreign
-- currency. If a current rate already exists for (business, date, currency),
-- this function supersedes it atomically — no rate history is lost.
--
-- CRITICAL: Insert order must avoid violating uix_fx_rates_current:
--   Step 1 — SELECT the existing current record (FOR UPDATE to lock it)
--   Step 2 — UPDATE old record: SET is_current = false
--   Step 3 — INSERT new record with is_current = true
--   Step 4 — UPDATE old record: SET superseded_by = new_id
--
-- Steps 2→3 are ordered this way because the partial UNIQUE index
-- (WHERE is_current = true) would reject a new INSERT if the old row
-- still has is_current = true. We must deactivate old BEFORE inserting new.
--
-- SECURITY DEFINER: bypasses RLS to perform the multi-step atomic update.
-- SET search_path prevents search-path hijacking attacks.

CREATE OR REPLACE FUNCTION rpc_set_fx_rate(
  p_business_id UUID,
  p_rate_date   DATE,
  p_currency    TEXT,
  p_rate_to_try NUMERIC,
  p_source      TEXT DEFAULT 'manual'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_old_id UUID;
  v_new_id UUID;
BEGIN
  -- Validate caller is manager or owner
  IF NOT fn_is_manager_plus(p_business_id) THEN
    RAISE EXCEPTION 'rpc_set_fx_rate: manager or owner role required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validate rate is positive
  IF p_rate_to_try <= 0 THEN
    RAISE EXCEPTION 'rpc_set_fx_rate: rate_to_try must be positive, got %', p_rate_to_try
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Validate currency (TRY is always 1.0, never stored here)
  IF p_currency NOT IN ('GBP', 'EUR', 'USD') THEN
    RAISE EXCEPTION 'rpc_set_fx_rate: unsupported currency %, must be GBP, EUR, or USD', p_currency
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- STEP 1: Lock the existing current record (if any)
  -- FOR UPDATE prevents a concurrent rpc_set_fx_rate from racing on the same row.
  SELECT id INTO v_old_id
  FROM fx_rates
  WHERE business_id = p_business_id
    AND rate_date   = p_rate_date
    AND currency    = p_currency
    AND is_current  = true
  FOR UPDATE;

  -- STEP 2: If old record exists, deactivate it BEFORE inserting new one.
  -- This clears the partial UNIQUE index slot so the INSERT in step 3 succeeds.
  IF v_old_id IS NOT NULL THEN
    UPDATE fx_rates
    SET is_current = false
    WHERE id = v_old_id;
  END IF;

  -- STEP 3: Insert the new current record.
  -- The partial UNIQUE index slot is now free (old row has is_current=false).
  INSERT INTO fx_rates (
    business_id,
    rate_date,
    currency,
    rate_to_try,
    source,
    is_current,
    created_by
  )
  VALUES (
    p_business_id,
    p_rate_date,
    p_currency,
    p_rate_to_try,
    p_source,
    true,
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- STEP 4: Record the supersession link on the old record.
  -- The old row is now fully historical: is_current=false, superseded_by set.
  IF v_old_id IS NOT NULL THEN
    UPDATE fx_rates
    SET superseded_by = v_new_id
    WHERE id = v_old_id;
  END IF;

  RETURN v_new_id;
END;
$$;

-- Revoke broad access; grant only to authenticated users.
-- Manager-plus check is enforced inside the function body.
REVOKE EXECUTE ON FUNCTION rpc_set_fx_rate(UUID, DATE, TEXT, NUMERIC, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rpc_set_fx_rate(UUID, DATE, TEXT, NUMERIC, TEXT) TO authenticated;


-- ============================================================
-- 4. HELPER VIEW: v_fx_rates_today
-- ============================================================
-- Convenience view for the app layer to fetch today's active rates.
-- Uses security_invoker so the caller's RLS context applies.

CREATE OR REPLACE VIEW v_fx_rates_today
WITH (security_invoker = true) AS
SELECT
  id,
  business_id,
  rate_date,
  currency,
  rate_to_try,
  source,
  created_by,
  created_at
FROM fx_rates
WHERE rate_date = CURRENT_DATE
  AND is_current = true;


-- ============================================================
-- MIGRATION 003 COMPLETE
-- ============================================================
-- Summary:
--   ✓ fx_rates: versioned immutable table
--       - INSERT-only via rpc_set_fx_rate (no direct client INSERT policy)
--       - is_current flag; superseded_by self-reference for correction chain
--       - Partial UNIQUE index (business_id, rate_date, currency) WHERE is_current=true
--       - Supports GBP, EUR, USD only (TRY needs no rate)
--       - RLS: SELECT for all members; no INSERT/UPDATE/DELETE policies
--   ✓ rpc_set_fx_rate: SECURITY DEFINER, SET search_path
--       - Correct 4-step order: lock → deactivate old → insert new → set superseded_by
--       - Prevents partial UNIQUE index violation (old row deactivated BEFORE new insert)
--       - Manager+ only; validates rate > 0 and currency ∈ {GBP, EUR, USD}
--       - Uses auth.uid() for created_by (never client-supplied)
--       - REVOKE from PUBLIC, GRANT to authenticated
--   ✓ v_fx_rates_today: security_invoker view for app convenience
--
--   ✗ sale_payments FX columns: already in 002_schema_cont.sql
--   ✗ register_session_currency_counts: already in 002_schema_cont.sql
--   ✗ accounting role: deferred — awaiting pilot confirmation
--   ✗ TLC seed data: see seed_things_like_crop.sql
-- ============================================================
