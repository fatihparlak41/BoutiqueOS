-- ============================================================
-- Phase 9A — register session hardening (owner/manager only)
-- ============================================================
-- Decision (2026-09-16): opening and closing a cash drawer is an owner/manager act in V1.
-- Rev 3 let any active member of the branch open/close a session (fn_require_member); the
-- POS UI meanwhile only lets managers define registers, and the live ZZ smoke showed a
-- sales_staff REST call reaching REGISTER_ALREADY_OPEN with no role check at all. Backend
-- and UI now share one model: sales_staff sells on a session a manager opened, and cannot
-- open, close, reopen or adjust one. A tenant-level setting may widen this later; not now.
--
-- Audit of every cash-session mutation path: rpc_open_register_session and
-- rpc_close_register_session are the only writers of register_sessions /
-- register_session_currency_counts reachable by a client; cash_movements are written only
-- by the sale/return/void cores against an OPEN session; none of the three tables has a
-- client INSERT/UPDATE/DELETE policy; there is no reopen or session-adjustment RPC.
-- rpc_pos_complete_sale / fn_sale_core are NOT touched: a sales_staff cashier still sells
-- on an open session.
--
-- Both bodies below are verbatim copies of 20260908000004 with the single membership line
-- replaced by fn_require_role(owner|manager). fn_require_role -> fn_require_member keeps the
-- active-business check first, so a suspended tenant still fails with BUSINESS_SUSPENDED.
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_open_register_session(p_cash_register_id UUID, p_opening_counts JSONB DEFAULT '[]')
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); r RECORD; v_id UUID := gen_random_uuid(); v_member_branch UUID; c RECORD; v_accepted TEXT[];
BEGIN
  SELECT * INTO r FROM cash_registers WHERE id = p_cash_register_id;
  IF r.id IS NULL OR NOT r.is_active THEN RAISE EXCEPTION 'INVALID_REGISTER: %', p_cash_register_id USING ERRCODE='22023'; END IF;
  PERFORM fn_require_role(r.business_id, ARRAY['owner','manager']::user_role[]);   -- V1: drawer open is owner/manager
  SELECT branch_id INTO v_member_branch FROM business_members WHERE business_id = r.business_id AND user_id = v_actor;
  IF v_member_branch IS NOT NULL AND v_member_branch <> r.branch_id THEN
    RAISE EXCEPTION 'FORBIDDEN: member is pinned to another branch' USING ERRCODE='42501';
  END IF;
  IF EXISTS (SELECT 1 FROM register_sessions WHERE cash_register_id = r.id AND status = 'open') THEN
    RAISE EXCEPTION 'REGISTER_ALREADY_OPEN: register % has an open session', r.id USING ERRCODE='55000';
  END IF;
  v_accepted := ARRAY(SELECT jsonb_array_elements_text(fn_setting(r.business_id, 'accepted_currencies')));

  INSERT INTO register_sessions (id, business_id, branch_id, cash_register_id, session_number, status, opened_by)
  VALUES (v_id, r.business_id, r.branch_id, r.id, fn_next_sequence(r.business_id, 'RS'), 'open', v_actor);

  INSERT INTO register_session_currency_counts (business_id, register_session_id, currency, opening_amount)
  VALUES (r.business_id, v_id, 'TRY', 0);
  FOR c IN SELECT e->>'currency' AS currency, (e->>'amount')::NUMERIC AS amount FROM jsonb_array_elements(COALESCE(p_opening_counts,'[]'::jsonb)) e LOOP
    IF NOT (c.currency = ANY(v_accepted)) THEN RAISE EXCEPTION 'CURRENCY_NOT_ACCEPTED: %', c.currency USING ERRCODE='22023'; END IF;
    IF c.amount IS NULL OR c.amount < 0 THEN RAISE EXCEPTION 'INVALID_OPENING_AMOUNT' USING ERRCODE='22023'; END IF;
    INSERT INTO register_session_currency_counts (business_id, register_session_id, currency, opening_amount)
    VALUES (r.business_id, v_id, c.currency, c.amount)
    ON CONFLICT (register_session_id, currency) DO UPDATE SET opening_amount = EXCLUDED.opening_amount;
  END LOOP;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_open_register_session(UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_open_register_session(UUID, JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_close_register_session(p_register_session_id UUID, p_counts JSONB, p_closing_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); s RECORD; cur RECORD; v_counted NUMERIC; v_expected NUMERIC; v_rate NUMERIC; v_fx UUID; v_out JSONB := '[]'::jsonb;
BEGIN
  SELECT * INTO s FROM register_sessions WHERE id = p_register_session_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: session %', p_register_session_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(s.business_id, ARRAY['owner','manager']::user_role[]);   -- V1: drawer close is owner/manager
  IF s.status <> 'open' THEN RAISE EXCEPTION 'INVALID_STATE: session already closed' USING ERRCODE='55000'; END IF;

  -- make sure a count row exists for every currency that moved
  INSERT INTO register_session_currency_counts (business_id, register_session_id, currency, opening_amount)
  SELECT DISTINCT s.business_id, s.id, currency, 0 FROM cash_movements WHERE register_session_id = s.id
  ON CONFLICT (register_session_id, currency) DO NOTHING;

  FOR cur IN SELECT * FROM register_session_currency_counts WHERE register_session_id = s.id ORDER BY currency LOOP
    SELECT (e->>'counted_amount')::NUMERIC INTO v_counted
    FROM jsonb_array_elements(COALESCE(p_counts,'[]'::jsonb)) e WHERE e->>'currency' = cur.currency LIMIT 1;
    IF v_counted IS NULL THEN RAISE EXCEPTION 'COUNT_REQUIRED: counted_amount for % missing', cur.currency USING ERRCODE='22023'; END IF;
    IF v_counted < 0 THEN RAISE EXCEPTION 'INVALID_COUNT: % negative', cur.currency USING ERRCODE='22023'; END IF;

    SELECT cur.opening_amount + COALESCE(SUM(amount), 0) INTO v_expected
    FROM cash_movements WHERE register_session_id = s.id AND currency = cur.currency;   -- card/bank never here

    IF cur.currency = 'TRY' THEN v_rate := 1;
    ELSE
      BEGIN
        SELECT f.fx_rate_id, f.rate INTO v_fx, v_rate FROM fn_get_fx_rate(s.business_id, cur.currency, CURRENT_DATE) f;
      EXCEPTION WHEN OTHERS THEN v_rate := NULL;   -- no rate today: base summary left NULL, variance still recorded in currency
      END;
    END IF;

    UPDATE register_session_currency_counts
    SET expected_amount = round(v_expected, 2), counted_amount = round(v_counted, 2), exchange_rate = v_rate
    WHERE id = cur.id;

    v_out := v_out || jsonb_build_object('currency', cur.currency, 'opening', cur.opening_amount, 'expected', round(v_expected,2),
                                         'counted', round(v_counted,2), 'variance', round(v_counted - v_expected, 2));
  END LOOP;

  UPDATE register_sessions SET status = 'closed', closed_by = v_actor, closed_at = now(), closing_note = p_closing_note WHERE id = s.id;
  RETURN jsonb_build_object('session_id', s.id, 'counts', v_out);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_close_register_session(UUID, JSONB, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_close_register_session(UUID, JSONB, TEXT) TO authenticated;
