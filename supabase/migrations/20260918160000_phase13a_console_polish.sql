-- ============================================================
-- Phase 13A follow-up — platform console polish
--   * the subscription note written at approval reads in the product's language
--   * the audit trail names the acting admin by profile name, else by e-mail
-- Same signatures and grants as 20260918140000; bodies only.
-- ============================================================

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
  VALUES (v_biz, v_plan, 'pending', 'platform_manual', 'Onayda oluşturuldu; ödeme uygulama dışında alınır.')
  RETURNING id INTO v_sub;
  UPDATE business_applications SET status = 'approved', reviewed_by = v_admin, reviewed_at = now(), review_note = NULLIF(trim(COALESCE(p_note, '')), ''),
                                   business_id = v_biz, updated_at = now() WHERE id = a.id;
  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, target_application_id, payload)
  VALUES (v_admin, 'approve_application', v_biz, a.id,
          jsonb_build_object('business_name', a.business_name, 'code', v_code, 'applicant', a.applicant_user_id, 'branch_id', v_br,
                             'subscription_id', v_sub, 'plan', v_plan_code, 'note', p_note));
  RETURN jsonb_build_object('application_id', a.id, 'business_id', v_biz, 'business_code', v_code, 'branch_id', v_br, 'subscription_id', v_sub, 'status', 'approved', 'replayed', false);
END $$;

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
           'audit', (SELECT COALESCE(jsonb_agg(jsonb_build_object('at', l.occurred_at, 'action', l.action, 'admin', COALESCE(pa.full_name, ua.email), 'payload', l.payload) ORDER BY l.occurred_at DESC), '[]'::jsonb)
                     FROM (SELECT * FROM platform_audit_log WHERE target_business_id = b.id ORDER BY occurred_at DESC LIMIT 50) l LEFT JOIN profiles pa ON pa.id = l.admin_user_id LEFT JOIN auth.users ua ON ua.id = l.admin_user_id))
  INTO v FROM businesses b WHERE b.id = p_business_id;
  IF v IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: business %', p_business_id USING ERRCODE = 'P0002'; END IF;
  RETURN v;
END $$;

-- CREATE OR REPLACE keeps the existing privileges; restated so the lint sees the contract.
REVOKE EXECUTE ON FUNCTION rpc_platform_approve_application(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_approve_application(UUID, TEXT) TO authenticated;
REVOKE EXECUTE ON FUNCTION rpc_platform_business_detail(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_business_detail(UUID) TO authenticated;
