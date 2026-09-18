-- ============================================================
-- Phase 13A — SaaS platform foundation
--
-- Public registration → e-mail confirmation → business application → plan → pending
-- platform approval → atomic activation (business + first owner + branch + settings +
-- subscription + audit) → normal tenant onboarding.
--
-- Decisions (docs/09 ADR-19):
--   * The pending state lives in business_applications, never in businesses. A business row
--     exists only once the platform approved the application, and it is created active with
--     its first owner in the same transaction — there is never a business with zero owners
--     and never a half-created tenant. Rejected / withdrawn applications are kept as history.
--   * businesses.status keeps the 3.5 enum (active / suspended / cancelled); "pending" is an
--     application status. Status stays platform-controlled (3.5G guard, audited RPC).
--   * saas_plans is data (code, interval, price, currency); nothing in the code knows a price.
--     business_subscriptions is a commercial record independent of POS money; in 13A it is
--     created PENDING at approval and activated manually by the platform (no payment provider).
--   * Applications, approvals and subscription changes go through SECURITY DEFINER RPCs that
--     prove the actor (confirmed applicant / platform admin). Clients never write these tables.
--   * Idempotency: one pending application per applicant (partial unique index; a second
--     submission returns the first); approval locks the application row and returns the
--     existing business when already approved; every approval writes platform_audit_log.
-- ============================================================

CREATE TYPE billing_interval    AS ENUM ('monthly','annual');
CREATE TYPE application_status  AS ENUM ('pending','approved','rejected','withdrawn');
CREATE TYPE subscription_status AS ENUM ('pending','active','past_due','cancelled','expired');

-- ------------------------------------------------------------ plans (data, public read)
CREATE TABLE saas_plans (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code             TEXT NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9_]{2,40}$'),
  name             TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 80),
  description      TEXT,
  billing_interval billing_interval NOT NULL DEFAULT 'annual',
  price_amount     NUMERIC(12,2) NOT NULL CHECK (price_amount >= 0),
  currency         iso_currency NOT NULL DEFAULT 'USD',
  is_active        BOOLEAN NOT NULL DEFAULT true,
  sort_order       INTEGER NOT NULL DEFAULT 100,
  features         JSONB NOT NULL DEFAULT '{}'::jsonb,   -- reserved; no feature gating in 13A
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE saas_plans ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_saas_plans_public ON saas_plans FOR SELECT USING (is_active);
REVOKE ALL ON saas_plans FROM anon, authenticated;
GRANT SELECT ON saas_plans TO anon, authenticated;

-- the first commercial plan as DATA (editable by the platform admin, never referenced by code)
INSERT INTO saas_plans (code, name, description, billing_interval, price_amount, currency, sort_order)
VALUES ('starter', 'BoutiqueOS Starter', 'Tek mağaza için tüm operasyon: katalog, mal kabul, stok, kasa, iade, müşteri, rapor ve analiz.', 'annual', 50, 'USD', 10);

-- ------------------------------------------------------------ applications
CREATE TABLE business_applications (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  applicant_user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  business_name     TEXT NOT NULL CHECK (length(trim(business_name)) BETWEEN 2 AND 120),
  country           TEXT NOT NULL DEFAULT 'TR' CHECK (country ~ '^[A-Z]{2}$'),
  currency          iso_currency NOT NULL DEFAULT 'TRY',
  phone             TEXT,
  business_type     TEXT,
  branch_name       TEXT NOT NULL DEFAULT 'Merkez' CHECK (length(trim(branch_name)) BETWEEN 1 AND 80),
  plan_id           UUID REFERENCES saas_plans(id),
  status            application_status NOT NULL DEFAULT 'pending',
  submitted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  reviewed_by       UUID REFERENCES profiles(id),
  reviewed_at       TIMESTAMPTZ,
  review_note       TEXT,
  business_id       UUID REFERENCES businesses(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- one open application per person: the second submission finds the first
CREATE UNIQUE INDEX uix_application_pending_per_user ON business_applications (applicant_user_id) WHERE status = 'pending';
CREATE INDEX idx_applications_status ON business_applications (status, submitted_at DESC);
ALTER TABLE business_applications ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_applications_own ON business_applications FOR SELECT USING (applicant_user_id = auth.uid());
REVOKE ALL ON business_applications FROM anon, authenticated;
GRANT SELECT ON business_applications TO authenticated;

-- ------------------------------------------------------------ subscriptions (commercial record, not POS money)
CREATE TABLE business_subscriptions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID NOT NULL REFERENCES businesses(id),
  plan_id           UUID NOT NULL REFERENCES saas_plans(id),
  status            subscription_status NOT NULL DEFAULT 'pending',
  starts_at         TIMESTAMPTZ,
  ends_at           TIMESTAMPTZ,
  renews_at         TIMESTAMPTZ,
  activated_at      TIMESTAMPTZ,
  cancelled_at      TIMESTAMPTZ,
  source            TEXT NOT NULL DEFAULT 'platform_manual',   -- how it came to be; a provider later
  external_provider TEXT,                                       -- reserved for billing (13B+)
  external_ref      TEXT,
  note              TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, id)
);
-- one non-terminal subscription per business
CREATE UNIQUE INDEX uix_subscription_open_per_business ON business_subscriptions (business_id) WHERE status IN ('pending','active','past_due');
ALTER TABLE business_subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_subscriptions_owner ON business_subscriptions FOR SELECT USING (fn_is_manager_plus(business_id));
REVOKE ALL ON business_subscriptions FROM anon, authenticated;
GRANT SELECT ON business_subscriptions TO authenticated;

-- audit log gains an application target (nullable; business target stays)
ALTER TABLE platform_audit_log ADD COLUMN target_application_id UUID REFERENCES business_applications(id);

-- ------------------------------------------------------------ helpers
-- Confirmed applicant: an authenticated user whose e-mail address is confirmed.
CREATE OR REPLACE FUNCTION fn_require_confirmed_user()
RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v UUID := fn_actor(); v_confirmed TIMESTAMPTZ;
BEGIN
  SELECT email_confirmed_at INTO v_confirmed FROM auth.users WHERE id = v;
  IF v_confirmed IS NULL THEN
    RAISE EXCEPTION 'EMAIL_NOT_CONFIRMED: confirm your e-mail address first' USING ERRCODE = '42501';
  END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION fn_require_confirmed_user() FROM PUBLIC, anon, authenticated;

-- Readable, platform-unique business code from the name: ASCII letters/digits, 3–8 chars, numbered on collision.
CREATE OR REPLACE FUNCTION fn_business_code_for(p_name TEXT)
RETURNS TEXT LANGUAGE plpgsql STABLE SET search_path = pg_catalog, public AS $$
DECLARE base TEXT; candidate TEXT; n INTEGER := 1;
BEGIN
  base := upper(regexp_replace(translate(COALESCE(p_name, ''), 'çğıöşüÇĞİÖŞÜâîû', 'cgiosuCGIOSUaiu'), '[^A-Za-z0-9]', '', 'g'));
  base := left(base, 8);
  IF length(base) < 3 THEN base := rpad(base, 3, 'X'); END IF;
  candidate := base;
  WHILE EXISTS (SELECT 1 FROM businesses WHERE code = candidate) LOOP
    n := n + 1;
    candidate := left(base, 8 - length(n::text)) || n::text;
  END LOOP;
  RETURN candidate;
END $$;
REVOKE EXECUTE ON FUNCTION fn_business_code_for(TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_default_timezone_for(p_country TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_country WHEN 'TR' THEN 'Europe/Istanbul' WHEN 'CY' THEN 'Asia/Nicosia' WHEN 'GB' THEN 'Europe/London' WHEN 'DE' THEN 'Europe/Berlin' ELSE 'UTC' END;
$$;
REVOKE EXECUTE ON FUNCTION fn_default_timezone_for(TEXT) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ public / applicant RPCs
CREATE OR REPLACE FUNCTION rpc_saas_plans()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'description', description,
                                               'billing_interval', billing_interval, 'price_amount', price_amount, 'currency', currency)
                            ORDER BY sort_order, name), '[]'::jsonb)
  FROM saas_plans WHERE is_active;
$$;
REVOKE EXECUTE ON FUNCTION rpc_saas_plans() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_saas_plans() TO anon, authenticated;

-- Submit (or find) the caller's business application. Idempotent: an open application is returned as is.
CREATE OR REPLACE FUNCTION rpc_submit_business_application(
  p_business_name TEXT, p_country TEXT DEFAULT 'TR', p_currency TEXT DEFAULT 'TRY', p_phone TEXT DEFAULT NULL,
  p_business_type TEXT DEFAULT NULL, p_branch_name TEXT DEFAULT NULL, p_plan_id UUID DEFAULT NULL, p_full_name TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_user UUID := fn_require_confirmed_user(); v_cur iso_currency; v_id UUID; v_existing RECORD; v_name TEXT := trim(COALESCE(p_business_name, ''));
BEGIN
  SELECT id, status, business_name, business_id INTO v_existing FROM business_applications
  WHERE applicant_user_id = v_user AND status = 'pending' FOR UPDATE;
  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object('application_id', v_existing.id, 'status', 'pending', 'business_name', v_existing.business_name, 'replayed', true);
  END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'INVALID_NAME: business name is required' USING ERRCODE = '22023'; END IF;
  IF p_country IS NULL OR p_country !~ '^[A-Z]{2}$' THEN RAISE EXCEPTION 'INVALID_COUNTRY: %', p_country USING ERRCODE = '22023'; END IF;
  BEGIN v_cur := COALESCE(p_currency, 'TRY')::iso_currency; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_CURRENCY: %', p_currency USING ERRCODE = '22023'; END;
  IF p_plan_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM saas_plans WHERE id = p_plan_id AND is_active) THEN
    RAISE EXCEPTION 'INVALID_PLAN: plan % is not offered', p_plan_id USING ERRCODE = '22023';
  END IF;
  -- the registrant's name from the signup, only if the profile has none yet
  IF p_full_name IS NOT NULL AND length(trim(p_full_name)) BETWEEN 2 AND 120 THEN
    UPDATE profiles SET full_name = trim(p_full_name), updated_at = now() WHERE id = v_user AND (full_name IS NULL OR full_name = '');
  END IF;
  INSERT INTO business_applications (applicant_user_id, business_name, country, currency, phone, business_type, branch_name, plan_id)
  VALUES (v_user, v_name, p_country, v_cur, NULLIF(trim(COALESCE(p_phone, '')), ''), NULLIF(trim(COALESCE(p_business_type, '')), ''),
          COALESCE(NULLIF(trim(COALESCE(p_branch_name, '')), ''), 'Merkez'), p_plan_id)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('application_id', v_id, 'status', 'pending', 'business_name', v_name, 'replayed', false);
EXCEPTION WHEN unique_violation THEN
  -- two submissions raced: the first one won, hand it back
  SELECT id, business_name INTO v_existing FROM business_applications WHERE applicant_user_id = v_user AND status = 'pending';
  RETURN jsonb_build_object('application_id', v_existing.id, 'status', 'pending', 'business_name', v_existing.business_name, 'replayed', true);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_submit_business_application(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_submit_business_application(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT) TO authenticated;

-- The applicant's latest application, for the waiting page. Never internal ids beyond its own.
CREATE OR REPLACE FUNCTION rpc_my_business_application()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT jsonb_build_object('application_id', a.id, 'status', a.status, 'business_name', a.business_name, 'country', a.country,
                            'currency', a.currency, 'submitted_at', a.submitted_at, 'reviewed_at', a.reviewed_at,
                            'review_note', CASE WHEN a.status = 'rejected' THEN a.review_note END,
                            'plan', CASE WHEN p.id IS NULL THEN NULL ELSE jsonb_build_object('code', p.code, 'name', p.name, 'price_amount', p.price_amount, 'currency', p.currency, 'billing_interval', p.billing_interval) END,
                            'business_active', (SELECT b.status = 'active' FROM businesses b WHERE b.id = a.business_id))
  FROM business_applications a LEFT JOIN saas_plans p ON p.id = a.plan_id
  WHERE a.applicant_user_id = auth.uid()
  -- the open application wins over history; ties (same transaction) resolve by id
  ORDER BY (a.status = 'pending') DESC, a.submitted_at DESC, a.id DESC LIMIT 1;
$$;
REVOKE EXECUTE ON FUNCTION rpc_my_business_application() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_my_business_application() TO authenticated;

-- The applicant withdraws an open application (history kept).
CREATE OR REPLACE FUNCTION rpc_withdraw_business_application(p_application_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_user UUID := fn_actor(); a RECORD;
BEGIN
  SELECT * INTO a FROM business_applications WHERE id = p_application_id AND applicant_user_id = v_user FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: application %', p_application_id USING ERRCODE = 'P0002'; END IF;
  IF a.status <> 'pending' THEN RAISE EXCEPTION 'INVALID_STATE: application is %', a.status USING ERRCODE = '55000'; END IF;
  UPDATE business_applications SET status = 'withdrawn', updated_at = now() WHERE id = a.id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_withdraw_business_application(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_withdraw_business_application(UUID) TO authenticated;

-- Memberships in non-active businesses, for the safe status page (the shell filters them out).
CREATE OR REPLACE FUNCTION rpc_my_inactive_businesses()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', b.name, 'status', b.status) ORDER BY b.name), '[]'::jsonb)
  FROM business_members m JOIN businesses b ON b.id = m.business_id
  WHERE m.user_id = auth.uid() AND m.is_active AND b.status <> 'active';
$$;
REVOKE EXECUTE ON FUNCTION rpc_my_inactive_businesses() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_my_inactive_businesses() TO authenticated;

-- One round trip for the shell's "no active membership" branch: what is this visitor waiting on?
CREATE OR REPLACE FUNCTION rpc_my_onboarding()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT jsonb_build_object(
    'platform_admin', EXISTS (SELECT 1 FROM platform_admins WHERE user_id = auth.uid() AND is_active),
    'application', rpc_my_business_application(),
    'inactive_businesses', rpc_my_inactive_businesses());
$$;
REVOKE EXECUTE ON FUNCTION rpc_my_onboarding() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_my_onboarding() TO authenticated;

-- ------------------------------------------------------------ platform RPCs (platform admin only)
-- Atomic activation: business + first owner + branch + settings + subscription + audit, or nothing.
CREATE OR REPLACE FUNCTION rpc_platform_approve_application(p_application_id UUID, p_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); a RECORD; v_biz UUID; v_br UUID; v_sub UUID; v_code TEXT; v_plan UUID; v_plan_code TEXT; v_settings JSONB;
BEGIN
  SELECT * INTO a FROM business_applications WHERE id = p_application_id FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: application %', p_application_id USING ERRCODE = 'P0002'; END IF;
  IF a.status = 'approved' AND a.business_id IS NOT NULL THEN
    -- a retry after a timeout or a second admin: the first approval stands
    RETURN jsonb_build_object('application_id', a.id, 'business_id', a.business_id, 'status', 'approved', 'replayed', true);
  END IF;
  IF a.status <> 'pending' THEN RAISE EXCEPTION 'INVALID_STATE: application is %', a.status USING ERRCODE = '55000'; END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = a.applicant_user_id AND email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'EMAIL_NOT_CONFIRMED: the applicant has not confirmed the e-mail address' USING ERRCODE = '55000';
  END IF;
  -- the chosen plan, or the cheapest offered one when the applicant skipped the step
  v_plan := COALESCE(a.plan_id, (SELECT id FROM saas_plans WHERE is_active ORDER BY sort_order, name LIMIT 1));
  IF v_plan IS NULL THEN RAISE EXCEPTION 'NO_PLAN: no active plan to subscribe to' USING ERRCODE = '55000'; END IF;
  SELECT code INTO v_plan_code FROM saas_plans WHERE id = v_plan;
  v_code := fn_business_code_for(a.business_name);
  v_settings := jsonb_build_object(
    'accepted_currencies', jsonb_build_array(a.currency::text),
    'sales_visibility_scope', 'own',
    'money_refund_allowed', false,
    'store_credit_allowed', false,
    'exchange_window_days', 14,
    'default_charge_allocation_method', 'invoice_value_proportional',
    'timezone', fn_default_timezone_for(a.country));
  INSERT INTO businesses (name, code, sector, base_currency, phone, status, settings)
  VALUES (a.business_name, v_code, a.business_type, a.currency, a.phone, 'active', v_settings)
  RETURNING id INTO v_biz;
  INSERT INTO branches (business_id, name, code, is_default, status) VALUES (v_biz, a.branch_name, 'MRK', true, 'active') RETURNING id INTO v_br;
  INSERT INTO business_members (business_id, user_id, role, is_active) VALUES (v_biz, a.applicant_user_id, 'owner', true);
  INSERT INTO business_subscriptions (business_id, plan_id, status, source, note)
  VALUES (v_biz, v_plan, 'pending', 'platform_manual', 'created at approval; payment is collected outside the app in 13A')
  RETURNING id INTO v_sub;
  UPDATE business_applications SET status = 'approved', reviewed_by = v_admin, reviewed_at = now(), review_note = NULLIF(trim(COALESCE(p_note, '')), ''),
                                   business_id = v_biz, updated_at = now() WHERE id = a.id;
  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, target_application_id, payload)
  VALUES (v_admin, 'approve_application', v_biz, a.id,
          jsonb_build_object('business_name', a.business_name, 'code', v_code, 'applicant', a.applicant_user_id, 'branch_id', v_br,
                             'subscription_id', v_sub, 'plan', v_plan_code, 'note', p_note));
  RETURN jsonb_build_object('application_id', a.id, 'business_id', v_biz, 'business_code', v_code, 'branch_id', v_br, 'subscription_id', v_sub, 'status', 'approved', 'replayed', false);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_approve_application(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_approve_application(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_platform_reject_application(p_application_id UUID, p_note TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); a RECORD;
BEGIN
  SELECT * INTO a FROM business_applications WHERE id = p_application_id FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: application %', p_application_id USING ERRCODE = 'P0002'; END IF;
  IF a.status <> 'pending' THEN RAISE EXCEPTION 'INVALID_STATE: application is %', a.status USING ERRCODE = '55000'; END IF;
  IF length(trim(COALESCE(p_note, ''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED: say why the application is rejected' USING ERRCODE = '22023'; END IF;
  UPDATE business_applications SET status = 'rejected', reviewed_by = v_admin, reviewed_at = now(), review_note = trim(p_note), updated_at = now() WHERE id = a.id;
  INSERT INTO platform_audit_log (admin_user_id, action, target_application_id, payload)
  VALUES (v_admin, 'reject_application', a.id, jsonb_build_object('business_name', a.business_name, 'applicant', a.applicant_user_id, 'note', trim(p_note)));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_reject_application(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_reject_application(UUID, TEXT) TO authenticated;

-- Manual subscription state (no provider yet): active sets the period from the plan interval.
CREATE OR REPLACE FUNCTION rpc_platform_set_subscription_status(p_subscription_id UUID, p_status TEXT, p_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); s RECORD; v_new subscription_status; v_interval INTERVAL;
BEGIN
  BEGIN v_new := p_status::subscription_status; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_STATUS: %', p_status USING ERRCODE = '22023'; END;
  SELECT bs.*, p.billing_interval INTO s FROM business_subscriptions bs JOIN saas_plans p ON p.id = bs.plan_id WHERE bs.id = p_subscription_id FOR UPDATE OF bs;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: subscription %', p_subscription_id USING ERRCODE = 'P0002'; END IF;
  IF s.status IN ('cancelled','expired') THEN RAISE EXCEPTION 'INVALID_STATE: subscription is %', s.status USING ERRCODE = '55000'; END IF;
  v_interval := CASE s.billing_interval WHEN 'monthly' THEN interval '1 month' ELSE interval '1 year' END;
  UPDATE business_subscriptions SET
    status = v_new,
    starts_at = CASE WHEN v_new = 'active' THEN COALESCE(starts_at, now()) ELSE starts_at END,
    ends_at = CASE WHEN v_new = 'active' THEN COALESCE(starts_at, now()) + v_interval ELSE ends_at END,
    renews_at = CASE WHEN v_new = 'active' THEN COALESCE(starts_at, now()) + v_interval ELSE renews_at END,
    activated_at = CASE WHEN v_new = 'active' THEN COALESCE(activated_at, now()) ELSE activated_at END,
    cancelled_at = CASE WHEN v_new = 'cancelled' THEN now() ELSE cancelled_at END,
    note = COALESCE(NULLIF(trim(COALESCE(p_note, '')), ''), note), updated_at = now()
  WHERE id = s.id;
  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
  VALUES (v_admin, 'set_subscription_status', s.business_id, jsonb_build_object('subscription_id', s.id, 'from', s.status, 'to', v_new, 'note', p_note));
  RETURN jsonb_build_object('subscription_id', s.id, 'status', v_new);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_set_subscription_status(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_set_subscription_status(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_platform_upsert_plan(p_code TEXT, p_name TEXT, p_description TEXT, p_billing_interval TEXT, p_price_amount NUMERIC, p_currency TEXT, p_is_active BOOLEAN DEFAULT true, p_sort_order INTEGER DEFAULT 100)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v_id UUID;
BEGIN
  INSERT INTO saas_plans (code, name, description, billing_interval, price_amount, currency, is_active, sort_order)
  VALUES (p_code, trim(p_name), NULLIF(trim(COALESCE(p_description, '')), ''), p_billing_interval::billing_interval, p_price_amount, p_currency::iso_currency, COALESCE(p_is_active, true), COALESCE(p_sort_order, 100))
  ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, billing_interval = EXCLUDED.billing_interval,
    price_amount = EXCLUDED.price_amount, currency = EXCLUDED.currency, is_active = EXCLUDED.is_active, sort_order = EXCLUDED.sort_order, updated_at = now()
  RETURNING id INTO v_id;
  INSERT INTO platform_audit_log (admin_user_id, action, payload)
  VALUES (v_admin, 'upsert_plan', jsonb_build_object('code', p_code, 'name', p_name, 'billing_interval', p_billing_interval, 'price_amount', p_price_amount, 'currency', p_currency, 'is_active', p_is_active));
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_upsert_plan(TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT,BOOLEAN,INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_upsert_plan(TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT,BOOLEAN,INTEGER) TO authenticated;

-- ------------------------------------------------------------ platform reads (bounded, paginated)
CREATE OR REPLACE FUNCTION rpc_platform_applications(p_status TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v_rows JSONB; v_total BIGINT; v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  SELECT count(*) INTO v_total FROM business_applications a WHERE p_status IS NULL OR a.status::text = p_status;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', a.id, 'status', a.status, 'business_name', a.business_name, 'country', a.country, 'currency', a.currency,
           'submitted_at', a.submitted_at, 'reviewed_at', a.reviewed_at, 'business_id', a.business_id,
           'applicant', jsonb_build_object('name', pr.full_name, 'email', u.email, 'confirmed', u.email_confirmed_at IS NOT NULL),
           'plan', CASE WHEN p.id IS NULL THEN NULL ELSE jsonb_build_object('code', p.code, 'name', p.name, 'price_amount', p.price_amount, 'currency', p.currency, 'billing_interval', p.billing_interval) END)
           ORDER BY a.submitted_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (SELECT * FROM business_applications a WHERE p_status IS NULL OR a.status::text = p_status ORDER BY a.submitted_at DESC LIMIT v_lim OFFSET GREATEST(COALESCE(p_offset, 0), 0)) a
  LEFT JOIN profiles pr ON pr.id = a.applicant_user_id LEFT JOIN auth.users u ON u.id = a.applicant_user_id LEFT JOIN saas_plans p ON p.id = a.plan_id;
  RETURN jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_lim, 'offset', GREATEST(COALESCE(p_offset, 0), 0),
                            'pending', (SELECT count(*) FROM business_applications WHERE status = 'pending'));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_applications(TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_applications(TEXT, INTEGER, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_platform_application_detail(p_application_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v JSONB;
BEGIN
  SELECT jsonb_build_object(
           'id', a.id, 'status', a.status, 'business_name', a.business_name, 'country', a.country, 'currency', a.currency, 'phone', a.phone,
           'business_type', a.business_type, 'branch_name', a.branch_name, 'submitted_at', a.submitted_at, 'reviewed_at', a.reviewed_at,
           'review_note', a.review_note, 'reviewer', rv.full_name, 'business_id', a.business_id,
           'business', CASE WHEN b.id IS NULL THEN NULL ELSE jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'status', b.status) END,
           'applicant', jsonb_build_object('user_id', a.applicant_user_id, 'name', pr.full_name, 'email', u.email, 'confirmed_at', u.email_confirmed_at,
                                           'other_memberships', (SELECT count(*) FROM business_members m WHERE m.user_id = a.applicant_user_id AND m.is_active AND m.business_id IS DISTINCT FROM a.business_id)),
           'plan', CASE WHEN p.id IS NULL THEN NULL ELSE jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'price_amount', p.price_amount, 'currency', p.currency, 'billing_interval', p.billing_interval) END,
           'subscription', (SELECT jsonb_build_object('id', s.id, 'status', s.status, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'activated_at', s.activated_at)
                            FROM business_subscriptions s WHERE s.business_id = a.business_id ORDER BY s.created_at DESC LIMIT 1))
  INTO v
  FROM business_applications a
  LEFT JOIN profiles pr ON pr.id = a.applicant_user_id LEFT JOIN auth.users u ON u.id = a.applicant_user_id
  LEFT JOIN profiles rv ON rv.id = a.reviewed_by LEFT JOIN saas_plans p ON p.id = a.plan_id LEFT JOIN businesses b ON b.id = a.business_id
  WHERE a.id = p_application_id;
  IF v IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: application %', p_application_id USING ERRCODE = 'P0002'; END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_application_detail(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_application_detail(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_platform_businesses(p_status TEXT DEFAULT NULL, p_q TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v_rows JSONB; v_total BIGINT; v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200); v_q TEXT := NULLIF(trim(COALESCE(p_q, '')), '');
BEGIN
  SELECT count(*) INTO v_total FROM businesses b WHERE (p_status IS NULL OR b.status::text = p_status) AND (v_q IS NULL OR b.name ILIKE '%' || v_q || '%' OR b.code ILIKE '%' || v_q || '%');
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', b.id, 'name', b.name, 'code', b.code, 'status', b.status, 'base_currency', b.base_currency, 'created_at', b.created_at,
           'owners', (SELECT count(*) FROM business_members m WHERE m.business_id = b.id AND m.is_active AND m.role = 'owner'),
           'members', (SELECT count(*) FROM business_members m WHERE m.business_id = b.id AND m.is_active),
           'branches', (SELECT count(*) FROM branches br WHERE br.business_id = b.id AND br.status = 'active'),
           'subscription', (SELECT jsonb_build_object('id', s.id, 'status', s.status, 'plan', p.code, 'ends_at', s.ends_at)
                            FROM business_subscriptions s JOIN saas_plans p ON p.id = s.plan_id WHERE s.business_id = b.id ORDER BY s.created_at DESC LIMIT 1))
           ORDER BY b.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (SELECT * FROM businesses b WHERE (p_status IS NULL OR b.status::text = p_status) AND (v_q IS NULL OR b.name ILIKE '%' || v_q || '%' OR b.code ILIKE '%' || v_q || '%')
        ORDER BY b.created_at DESC LIMIT v_lim OFFSET GREATEST(COALESCE(p_offset, 0), 0)) b;
  RETURN jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_lim, 'offset', GREATEST(COALESCE(p_offset, 0), 0));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_businesses(TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_businesses(TEXT, TEXT, INTEGER, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_platform_business_detail(p_business_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v JSONB;
BEGIN
  SELECT jsonb_build_object(
           'id', b.id, 'name', b.name, 'code', b.code, 'status', b.status, 'base_currency', b.base_currency, 'created_at', b.created_at,
           'timezone', b.settings ->> 'timezone',
           'owners', (SELECT COALESCE(jsonb_agg(jsonb_build_object('name', pr.full_name, 'email', u.email) ORDER BY u.email), '[]'::jsonb)
                      FROM business_members m LEFT JOIN profiles pr ON pr.id = m.user_id LEFT JOIN auth.users u ON u.id = m.user_id
                      WHERE m.business_id = b.id AND m.is_active AND m.role = 'owner'),
           'members', (SELECT count(*) FROM business_members m WHERE m.business_id = b.id AND m.is_active),
           'branches', (SELECT count(*) FROM branches br WHERE br.business_id = b.id AND br.status = 'active'),
           'subscriptions', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'plan', p.name, 'plan_code', p.code, 'price_amount', p.price_amount, 'currency', p.currency,
                                                                          'billing_interval', p.billing_interval, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'activated_at', s.activated_at, 'cancelled_at', s.cancelled_at, 'source', s.source, 'note', s.note)
                                                       ORDER BY s.created_at DESC), '[]'::jsonb)
                             FROM business_subscriptions s JOIN saas_plans p ON p.id = s.plan_id WHERE s.business_id = b.id),
           'application', (SELECT jsonb_build_object('id', a.id, 'status', a.status, 'submitted_at', a.submitted_at) FROM business_applications a WHERE a.business_id = b.id ORDER BY a.submitted_at DESC LIMIT 1),
           'audit', (SELECT COALESCE(jsonb_agg(jsonb_build_object('at', l.occurred_at, 'action', l.action, 'admin', pa.full_name, 'payload', l.payload) ORDER BY l.occurred_at DESC), '[]'::jsonb)
                     FROM (SELECT * FROM platform_audit_log WHERE target_business_id = b.id ORDER BY occurred_at DESC LIMIT 50) l LEFT JOIN profiles pa ON pa.id = l.admin_user_id))
  INTO v FROM businesses b WHERE b.id = p_business_id;
  IF v IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: business %', p_business_id USING ERRCODE = 'P0002'; END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_business_detail(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_business_detail(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_platform_plans()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v JSONB;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'description', p.description, 'billing_interval', p.billing_interval,
                                               'price_amount', p.price_amount, 'currency', p.currency, 'is_active', p.is_active, 'sort_order', p.sort_order,
                                               'subscriptions', (SELECT count(*) FROM business_subscriptions s WHERE s.plan_id = p.id AND s.status IN ('pending','active','past_due')))
                            ORDER BY p.sort_order, p.name), '[]'::jsonb)
  INTO v FROM saas_plans p;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_plans() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_plans() TO authenticated;

-- "Am I a platform admin?" for the shell (answers only about the caller).
CREATE OR REPLACE FUNCTION rpc_platform_whoami()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT jsonb_build_object('platform_admin', EXISTS (SELECT 1 FROM platform_admins WHERE user_id = auth.uid() AND is_active),
                            'pending_applications', CASE WHEN EXISTS (SELECT 1 FROM platform_admins WHERE user_id = auth.uid() AND is_active)
                                                         THEN (SELECT count(*) FROM business_applications WHERE status = 'pending') ELSE NULL END);
$$;
REVOKE EXECUTE ON FUNCTION rpc_platform_whoami() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_whoami() TO authenticated;

-- ============================================================
-- END phase 13A
-- ============================================================
