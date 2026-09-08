-- ============================================================
-- BoutiqueOS  •  Migration 002  •  FX rates (versioned, immutable)
-- Rev 3  •  2026-09-08
-- ============================================================
-- Placed BEFORE the sales schema because posting RPCs (004) resolve
-- payment FX through fn_get_fx_rate and sale_payments.fx_rate_id
-- references this table (003).
--
-- Rules:
--   INSERT-only via rpc_set_fx_rate. One current row per
--   (business, currency, rate_date). Corrections supersede; history kept.
--   The only UPDATE ever applied is is_current=false + superseded_by,
--   and only by rpc_set_fx_rate (trigger enforces that nothing else changes).
-- ============================================================

CREATE TABLE fx_rates (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id    UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  rate_date      DATE NOT NULL,
  currency       iso_currency NOT NULL CHECK (currency <> 'TRY'),
  rate_to_base   fx6 NOT NULL,             -- 1 unit currency = N base (TRY)
  source         TEXT NOT NULL DEFAULT 'manual',   -- manual | tcmb (future)
  version        INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
  is_current     BOOLEAN NOT NULL DEFAULT true,
  -- DEFERRABLE: rpc_set_fx_rate must mark the old row superseded BEFORE inserting the new one,
  -- because the partial unique index uix_fx_rates_current (checked immediately) allows only one
  -- current row per (business, currency, date). The FK is therefore validated at COMMIT.
  superseded_by  UUID REFERENCES fx_rates(id) DEFERRABLE INITIALLY DEFERRED,
  created_by     UUID REFERENCES profiles(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, id),
  UNIQUE (business_id, currency, rate_date, version)
);

CREATE UNIQUE INDEX uix_fx_rates_current
  ON fx_rates (business_id, currency, rate_date) WHERE is_current;
CREATE INDEX idx_fx_rates_lookup
  ON fx_rates (business_id, currency, rate_date DESC) WHERE is_current;

-- Immutability: only the supersession transition is allowed, nothing else.
CREATE OR REPLACE FUNCTION fn_guard_fx_rate_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'IMMUTABLE: fx_rates rows cannot be deleted' USING ERRCODE='55000';
  END IF;
  IF NOT (OLD.is_current = true AND NEW.is_current = false AND NEW.superseded_by IS NOT NULL
          AND fn_row_comparable(to_jsonb(NEW), TG_TABLE_NAME) - 'is_current' - 'superseded_by' = fn_row_comparable(to_jsonb(OLD), TG_TABLE_NAME) - 'is_current' - 'superseded_by') THEN
    RAISE EXCEPTION 'IMMUTABLE: fx_rates may only be superseded (is_current -> false, superseded_by set)'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_fx_rates BEFORE UPDATE OR DELETE ON fx_rates
  FOR EACH ROW EXECUTE FUNCTION fn_guard_fx_rate_update();

ALTER TABLE fx_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_fx_select ON fx_rates FOR SELECT USING (fn_is_member(business_id));
-- no INSERT / UPDATE / DELETE policies: RPC only.

-- ============================================================
-- rpc_set_fx_rate  (manager+)
-- ============================================================
-- Concurrency: advisory xact lock on (business, currency, date) so two
-- simultaneous first-time inserts cannot race the partial unique index.
CREATE OR REPLACE FUNCTION rpc_set_fx_rate(
  p_business_id  UUID,
  p_currency     TEXT,
  p_rate_to_base NUMERIC,
  p_rate_date    DATE DEFAULT CURRENT_DATE,
  p_source       TEXT DEFAULT 'manual'
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_old_id  UUID; v_old_ver INTEGER := 0; v_new_id UUID;
BEGIN
  IF NOT fn_is_manager_plus(p_business_id) THEN
    RAISE EXCEPTION 'FORBIDDEN: manager or owner role required' USING ERRCODE='42501';
  END IF;
  IF p_currency IS NULL OR p_currency = 'TRY' OR p_currency NOT IN ('GBP','EUR','USD') THEN
    RAISE EXCEPTION 'INVALID_CURRENCY: %', p_currency USING ERRCODE='22023';
  END IF;
  IF p_rate_to_base IS NULL OR p_rate_to_base <= 0 THEN
    RAISE EXCEPTION 'INVALID_RATE: rate must be > 0' USING ERRCODE='22023';
  END IF;
  IF p_rate_date IS NULL OR p_rate_date > CURRENT_DATE + 1 THEN
    RAISE EXCEPTION 'INVALID_DATE: rate_date % not allowed', p_rate_date USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_business_id::text || ':' || p_currency || ':' || p_rate_date::text));

  SELECT id, version INTO v_old_id, v_old_ver
  FROM fx_rates
  WHERE business_id = p_business_id AND currency = p_currency AND rate_date = p_rate_date AND is_current
  FOR UPDATE;

  -- new id first so the supersession UPDATE can reference it atomically
  v_new_id := gen_random_uuid();

  IF v_old_id IS NOT NULL THEN
    UPDATE fx_rates SET is_current = false, superseded_by = v_new_id WHERE id = v_old_id;
  END IF;

  INSERT INTO fx_rates (id, business_id, rate_date, currency, rate_to_base, source, version, is_current, created_by)
  VALUES (v_new_id, p_business_id, p_rate_date, p_currency, p_rate_to_base, p_source,
          COALESCE(v_old_ver, 0) + 1, true, auth.uid());

  RETURN v_new_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_set_fx_rate(UUID, TEXT, NUMERIC, DATE, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_set_fx_rate(UUID, TEXT, NUMERIC, DATE, TEXT) TO authenticated;

-- superseded_by FK must point to a row of the same business: enforce via trigger
-- (FK already guarantees existence; the UPDATE above is the only writer).

-- ============================================================
-- fn_get_fx_rate  (internal; used by posting RPCs)
-- ============================================================
-- Returns the current business rate for currency on p_date (exact date only —
-- "that day's rate" per pilot). TRY => (NULL, 1). Missing => exception.
CREATE OR REPLACE FUNCTION fn_get_fx_rate(
  p_business_id UUID, p_currency TEXT, p_date DATE,
  OUT fx_rate_id UUID, OUT rate NUMERIC
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF p_currency = 'TRY' THEN fx_rate_id := NULL; rate := 1; RETURN; END IF;
  SELECT id, rate_to_base INTO fx_rate_id, rate
  FROM fx_rates
  WHERE business_id = p_business_id AND currency = p_currency AND rate_date = p_date AND is_current;
  IF fx_rate_id IS NULL THEN
    RAISE EXCEPTION 'FX_RATE_MISSING: no current % rate for % on %', p_currency, p_business_id, p_date
      USING ERRCODE='P0002';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION fn_get_fx_rate(UUID, TEXT, DATE) FROM PUBLIC, anon, authenticated;

-- Members-only guard wrapper for client use
CREATE OR REPLACE FUNCTION rpc_get_fx_rate(p_business_id UUID, p_currency TEXT, p_date DATE DEFAULT CURRENT_DATE)
RETURNS TABLE (fx_rate_id UUID, rate NUMERIC)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF NOT fn_is_member(p_business_id) THEN
    RAISE EXCEPTION 'FORBIDDEN: not a member' USING ERRCODE='42501';
  END IF;
  RETURN QUERY SELECT f.fx_rate_id, f.rate FROM fn_get_fx_rate(p_business_id, p_currency, p_date) f;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_get_fx_rate(UUID, TEXT, DATE) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_get_fx_rate(UUID, TEXT, DATE) TO authenticated;

CREATE VIEW v_fx_rates_current WITH (security_invoker = true) AS
SELECT id, business_id, currency, rate_date, rate_to_base, version, source, created_by, created_at
FROM fx_rates WHERE is_current;

-- ============================================================
-- END 002
-- ============================================================
