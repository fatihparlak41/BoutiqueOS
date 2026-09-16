-- ============================================================
-- Phase 9B — returns / exchange foundation on top of completed POS sales
-- ============================================================
-- Audit (Rev 3, 20260908000004): fn_return_core already posts a customer return as an
-- immutable document (returns + return_items), re-enters stock at the ORIGINAL
-- unit_cost_at_sale (historical COGS, never the current MWA), guards OVER_RETURN under
-- sale_item row locks, honours the exchange window and category final-sale flag, and
-- rpc_process_exchange links return + replacement sale atomically with the merchandise
-- credit applied (never touching the original sale). What 9B adds on top:
--   1. one tenant return policy (fn_return_policy) with explicit keys and legacy fallbacks,
--   2. product-level exclusion (products.is_final_sale) next to the category flag,
--   3. structured, tenant-extensible return reasons (return_reasons) + optional requirement,
--   4. an explicit COGS-reversal record per returned line (return_item_costs, manager+),
--   5. idempotent plain returns (returns.client_transaction_id + fingerprint),
--   6. the posting authority: returns and exchanges are completed by owner/manager only —
--      sales_staff searches and prepares (rpc_pos_find_sales / rpc_return_eligibility),
--   7. exchange downgrade treatment decided by policy (block | cash_refund) — a cheaper
--      replacement never silently discards the customer's credit,
--   8. POS-shaped entry points that derive business/branch from the session and the sale
--      (rpc_pos_return, rpc_pos_exchange) — business_id is never a client parameter,
--   9. the client write grant on the return tables is removed (they were already frozen).
-- fn_return_core keeps its signature as a thin wrapper over fn_return_core_ext so the
-- Rev 3 RPCs (rpc_process_return / rpc_process_exchange) share the same rules.
-- ============================================================

-- ------------------------------------------------------------ 1. product-level exclusion
ALTER TABLE products ADD COLUMN is_final_sale BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN products.is_final_sale IS 'Return/exchange exclusion at product level (category flag also applies).';

-- ------------------------------------------------------------ 2. return reasons (platform defaults + tenant rows)
CREATE TABLE return_reasons (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,   -- NULL = platform default
  code        TEXT NOT NULL CHECK (code ~ '^[a-z0-9_]{2,40}$'),
  label       TEXT NOT NULL CHECK (length(trim(label)) BETWEEN 1 AND 80),
  sort_order  INTEGER NOT NULL DEFAULT 100,
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (business_id, code)
);
INSERT INTO return_reasons (business_id, code, label, sort_order) VALUES
  (NULL, 'beden_olmadi',    'Beden olmadı',     10),
  (NULL, 'renk_degisimi',   'Renk değişimi',    20),
  (NULL, 'kusurlu_urun',    'Kusurlu ürün',     30),
  (NULL, 'musteri_tercihi', 'Müşteri tercihi',  40),
  (NULL, 'yanlis_urun',     'Yanlış ürün',      50),
  (NULL, 'diger',           'Diğer',            90);
ALTER TABLE return_reasons ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_rr_select ON return_reasons FOR SELECT
  USING (business_id IS NULL OR fn_is_member(business_id));
CREATE POLICY pol_rr_write ON return_reasons FOR ALL
  USING (business_id IS NOT NULL AND fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (business_id IS NOT NULL AND fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

CREATE OR REPLACE FUNCTION fn_return_reason_valid(p_business_id UUID, p_code TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM return_reasons
    WHERE code = p_code AND is_active AND (business_id IS NULL OR business_id = p_business_id));
$$;
REVOKE EXECUTE ON FUNCTION fn_return_reason_valid(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ 3. return document additions
ALTER TABLE returns
  ADD COLUMN client_transaction_id UUID,
  ADD COLUMN request_fingerprint   TEXT,
  ADD COLUMN reason_code           TEXT,
  ADD CONSTRAINT uq_returns_client_tx UNIQUE (business_id, client_transaction_id);
ALTER TABLE return_items ADD COLUMN reason_code TEXT;

-- Explicit COGS reversal per returned line: the historical unit cost of the sale item
-- (sale_item_costs.unit_cost_at_sale) × returned quantity. Manager+ only, RPC-written.
CREATE TABLE return_item_costs (
  return_item_id     UUID PRIMARY KEY REFERENCES return_items(id),
  business_id        UUID NOT NULL REFERENCES businesses(id),
  unit_cost_at_sale  cost6  NOT NULL,
  line_cost_base     value6 NOT NULL
);
ALTER TABLE return_item_costs ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_ric_select ON return_item_costs FOR SELECT USING (fn_is_manager_plus(business_id));
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON return_item_costs FROM anon, authenticated;

-- returns / return_items are already frozen by the Rev 3 immutability loop (trg_imm_returns,
-- trg_imm_return_items, 003); the client write grant is removed here and the cost record
-- gets the same trigger. Corrections are new documents, never edits.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON returns, return_items FROM anon, authenticated;
CREATE TRIGGER trg_imm_ric BEFORE UPDATE OR DELETE ON return_item_costs FOR EACH ROW EXECUTE FUNCTION fn_forbid_update_delete();

-- ------------------------------------------------------------ 4. tenant return policy
-- settings.return_policy = { allow_exchange, allow_cash_refund, allow_store_credit,
--   exchange_window_days, receipt_required, reason_required, downgrade_treatment }
-- Legacy flat keys (money_refund_allowed, store_credit_allowed, exchange_window_days)
-- remain the fallback so no existing tenant row has to change. Missing core keys raise
-- SETTING_MISSING (fn_setting); the additive keys have documented defaults:
--   allow_exchange true · receipt_required true · reason_required false · downgrade_treatment 'block'.
CREATE OR REPLACE FUNCTION fn_return_policy(p_business_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v JSONB; v_out JSONB; v_treat TEXT;
BEGIN
  SELECT COALESCE(settings -> 'return_policy', '{}'::jsonb) INTO v FROM businesses WHERE id = p_business_id;
  IF v IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: business %', p_business_id USING ERRCODE='P0002'; END IF;
  v_treat := COALESCE(v ->> 'downgrade_treatment', 'block');
  IF v_treat NOT IN ('block','cash_refund','store_credit') THEN
    RAISE EXCEPTION 'INVALID_POLICY: downgrade_treatment % unknown', v_treat USING ERRCODE='22023';
  END IF;
  v_out := jsonb_build_object(
    'allow_exchange',       COALESCE((v ->> 'allow_exchange')::boolean, true),
    'allow_cash_refund',    COALESCE((v ->> 'allow_cash_refund')::boolean, (fn_setting(p_business_id, 'money_refund_allowed'))::text::boolean),
    'allow_store_credit',   COALESCE((v ->> 'allow_store_credit')::boolean, (fn_setting(p_business_id, 'store_credit_allowed'))::text::boolean),
    'exchange_window_days', COALESCE((v ->> 'exchange_window_days')::int, (fn_setting(p_business_id, 'exchange_window_days'))::text::int),
    'receipt_required',     COALESCE((v ->> 'receipt_required')::boolean, true),
    'reason_required',      COALESCE((v ->> 'reason_required')::boolean, false),
    'downgrade_treatment',  v_treat);
  IF (v_out ->> 'exchange_window_days')::int < 0 THEN
    RAISE EXCEPTION 'INVALID_POLICY: exchange_window_days must be >= 0' USING ERRCODE='22023';
  END IF;
  RETURN v_out;
END $$;
REVOKE EXECUTE ON FUNCTION fn_return_policy(UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ 5. return core (extended)
-- Verbatim copy of fn_return_core (20260916150000) plus the 9B rules, marked "-- 9B".
CREATE OR REPLACE FUNCTION fn_return_core_ext(
  p_business_id UUID, p_branch_id UUID, p_sale_id UUID, p_items JSONB,
  p_return_type return_type, p_reason TEXT, p_note TEXT,
  p_exchange_group_id UUID, p_replacement_sale_id UUID,
  p_register_session_id UUID, p_refund_method payment_method,
  p_reason_code TEXT, p_client_transaction_id UUID, p_fingerprint TEXT, p_refund_override NUMERIC
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); v_role user_role; s RECORD; it RECORD; si RECORD; sic RECORD; pr t_cost_pool_result;
  v_window INT; v_money BOOLEAN; v_store BOOLEAN; v_ret_id UUID := gen_random_uuid(); v_num TEXT;
  v_credit NUMERIC := 0; v_returned INT; v_disp inventory_bucket; v_final BOOLEAN; v_vids UUID[]; v_ri_id UUID;
  v_refund NUMERIC := 0;
  v_pol JSONB; v_fp TEXT; v_existing RECORD;   -- 9B
BEGIN
  v_role := fn_require_member(p_business_id);
  -- 9B: completing a return is a financial reversal — owner/manager only. sales_staff
  -- prepares (rpc_return_eligibility / rpc_pos_find_sales) and hands over.
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_assert_branch(p_business_id, p_branch_id);

  -- 9B: one policy object; legacy keys remain the fallback
  v_pol    := fn_return_policy(p_business_id);
  v_window := (v_pol ->> 'exchange_window_days')::INT;
  v_money  := (v_pol ->> 'allow_cash_refund')::BOOLEAN;
  v_store  := (v_pol ->> 'allow_store_credit')::BOOLEAN;
  IF p_return_type = 'exchange' AND NOT (v_pol ->> 'allow_exchange')::BOOLEAN THEN
    RAISE EXCEPTION 'EXCHANGE_NOT_ALLOWED: exchanges are disabled for this business' USING ERRCODE='55000';
  END IF;
  IF (v_pol ->> 'reason_required')::BOOLEAN AND p_reason_code IS NULL THEN
    RAISE EXCEPTION 'REASON_REQUIRED: this business requires a return reason' USING ERRCODE='22023';
  END IF;
  IF p_reason_code IS NOT NULL AND NOT fn_return_reason_valid(p_business_id, p_reason_code) THEN
    RAISE EXCEPTION 'INVALID_REASON: % is not an active return reason', p_reason_code USING ERRCODE='22023';
  END IF;

  IF p_return_type = 'refund' AND NOT v_money THEN
    RAISE EXCEPTION 'REFUND_NOT_ALLOWED: money refunds are disabled for this business (any method)' USING ERRCODE='55000';
  END IF;
  IF p_return_type = 'store_credit' THEN
    IF NOT v_store THEN RAISE EXCEPTION 'STORE_CREDIT_NOT_ALLOWED: store credit is disabled for this business' USING ERRCODE='55000'; END IF;
    RAISE EXCEPTION 'NOT_IMPLEMENTED: store credit ledger is not part of V1' USING ERRCODE='0A000';
  END IF;

  -- 9B: idempotent plain returns (exchanges are keyed on the replacement sale)
  IF p_client_transaction_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext(p_business_id::text || ':ret:' || p_client_transaction_id::text));
    v_fp := COALESCE(p_fingerprint, encode(sha256(convert_to(jsonb_build_object(
              's', p_sale_id, 't', p_return_type, 'm', p_refund_method, 'rs', p_register_session_id,
              'i', (SELECT jsonb_agg(jsonb_build_object('si', e->>'sale_item_id', 'q', (e->>'quantity')::int, 'd', e->>'disposition')
                            ORDER BY e->>'sale_item_id') FROM jsonb_array_elements(p_items) e)
            )::text, 'UTF8')), 'hex'));
    SELECT id, return_number, credit_value_base, refund_amount_base, request_fingerprint INTO v_existing
    FROM returns WHERE business_id = p_business_id AND client_transaction_id = p_client_transaction_id;
    IF v_existing.id IS NOT NULL THEN
      IF v_existing.request_fingerprint IS DISTINCT FROM v_fp THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: client_transaction_id % was used with a different payload', p_client_transaction_id USING ERRCODE='23505';
      END IF;
      RETURN jsonb_build_object('return_id', v_existing.id, 'return_number', v_existing.return_number,
                                'credit_value_base', v_existing.credit_value_base, 'refund_amount_base', v_existing.refund_amount_base, 'replayed', true);
    END IF;
  END IF;

  SELECT * INTO s FROM sales WHERE id = p_sale_id AND business_id = p_business_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: sale %', p_sale_id USING ERRCODE='P0002'; END IF;
  IF s.branch_id <> p_branch_id THEN RAISE EXCEPTION 'BRANCH_MISMATCH: sale % belongs to another branch', p_sale_id USING ERRCODE='22023'; END IF;
  IF s.status <> 'completed' THEN RAISE EXCEPTION 'INVALID_STATE: sale % is %', p_sale_id, s.status USING ERRCODE='55000'; END IF;
  IF now() > s.occurred_at + make_interval(days => v_window) THEN
    RAISE EXCEPTION 'EXCHANGE_WINDOW_EXPIRED: sale % sold at %, window % days', p_sale_id, s.occurred_at, v_window USING ERRCODE='55000';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_RETURN: no items' USING ERRCODE='22023';
  END IF;

  SELECT array_agg(DISTINCT x.variant_id ORDER BY x.variant_id) INTO v_vids
  FROM jsonb_array_elements(p_items) e JOIN sale_items x ON x.id = (e->>'sale_item_id')::UUID AND x.sale_id = p_sale_id;
  IF v_vids IS NULL THEN RAISE EXCEPTION 'INVALID_ITEM: sale_item not on sale %', p_sale_id USING ERRCODE='22023'; END IF;
  PERFORM fn_lock_pools(p_business_id, p_branch_id, v_vids);

  -- PASS 1: validate every line under sale_item locks and accumulate (no writes yet)
  CREATE TEMP TABLE IF NOT EXISTS _return_lines (
    sale_item_id UUID, variant_id UUID, qty INT, disp inventory_bucket, unit_price NUMERIC, unit_cost NUMERIC, reason TEXT
  ) ON COMMIT DROP;
  DELETE FROM _return_lines WHERE true;   -- pg-safeupdate: a bare DELETE is refused on Supabase

  FOR it IN SELECT (e->>'sale_item_id')::UUID AS sale_item_id, (e->>'quantity')::INT AS qty,
                   (e->>'disposition')::inventory_bucket AS disp, e->>'reason' AS reason
            FROM jsonb_array_elements(p_items) e ORDER BY (e->>'sale_item_id')::UUID LOOP
    IF it.qty IS NULL OR it.qty <= 0 THEN RAISE EXCEPTION 'INVALID_QTY: quantity must be > 0' USING ERRCODE='22023'; END IF;
    IF EXISTS (SELECT 1 FROM _return_lines WHERE sale_item_id = it.sale_item_id) THEN
      RAISE EXCEPTION 'DUPLICATE_ITEM: sale_item % listed twice', it.sale_item_id USING ERRCODE='22023';
    END IF;

    SELECT * INTO si FROM sale_items WHERE id = it.sale_item_id AND sale_id = p_sale_id FOR UPDATE;   -- serialises returns per line
    IF si.id IS NULL THEN RAISE EXCEPTION 'INVALID_ITEM: sale_item % not on sale %', it.sale_item_id, p_sale_id USING ERRCODE='22023'; END IF;

    -- 9B: product-level flag joins the category flag
    SELECT COALESCE(p.is_final_sale, false) OR COALESCE(c.is_final_sale, false) INTO v_final
    FROM product_variants pv JOIN products p ON p.id = pv.product_id LEFT JOIN categories c ON c.id = p.category_id
    WHERE pv.id = si.variant_id;
    IF v_final THEN RAISE EXCEPTION 'FINAL_SALE: variant % cannot be returned or exchanged', si.variant_id USING ERRCODE='55000'; END IF;

    SELECT COALESCE(SUM(quantity), 0) INTO v_returned FROM return_items WHERE sale_item_id = si.id;
    IF v_returned + it.qty > si.quantity THEN
      RAISE EXCEPTION 'OVER_RETURN: sale_item % sold=% already_returned=% requested=%', si.id, si.quantity, v_returned, it.qty USING ERRCODE='55000';
    END IF;

    -- J-1 disposition: default quarantine; sellable/damaged only for owner/manager
    v_disp := COALESCE(it.disp, 'quarantine');
    IF v_disp <> 'quarantine' AND NOT (v_role IN ('owner','manager')) THEN
      RAISE EXCEPTION 'DISPOSITION_NOT_AUTHORIZED: % may only return to quarantine', v_role USING ERRCODE='42501';
    END IF;

    SELECT * INTO sic FROM sale_item_costs WHERE sale_item_id = si.id;
    IF sic.sale_item_id IS NULL THEN RAISE EXCEPTION 'INTEGRITY: missing cost snapshot for sale_item %', si.id USING ERRCODE='23000'; END IF;

    INSERT INTO _return_lines VALUES (si.id, si.variant_id, it.qty, v_disp, si.unit_price_at_sale, sic.unit_cost_at_sale, it.reason);
    v_credit := v_credit + si.unit_price_at_sale * it.qty;
  END LOOP;
  v_credit := round(v_credit, 2);

  IF p_return_type = 'refund' THEN
    -- only reachable when money refunds are allowed
    IF p_refund_method IS NULL THEN RAISE EXCEPTION 'REFUND_METHOD_REQUIRED' USING ERRCODE='22023'; END IF;
    v_refund := v_credit;
  END IF;
  -- 9B: exchange downgrade — the part of the credit the replacement cannot absorb is refunded
  IF p_return_type = 'exchange' AND p_refund_override IS NOT NULL THEN
    IF p_refund_override <= 0 OR p_refund_override > v_credit THEN
      RAISE EXCEPTION 'INTEGRITY: refund override % outside (0, %]', p_refund_override, v_credit USING ERRCODE='23000';
    END IF;
    IF NOT v_money THEN RAISE EXCEPTION 'REFUND_NOT_ALLOWED: money refunds are disabled for this business (any method)' USING ERRCODE='55000'; END IF;
    IF p_refund_method IS NULL THEN RAISE EXCEPTION 'REFUND_METHOD_REQUIRED' USING ERRCODE='22023'; END IF;
    v_refund := round(p_refund_override, 2);
  END IF;
  IF v_refund > 0 AND p_refund_method = 'cash' AND (p_register_session_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM register_sessions WHERE id = p_register_session_id AND business_id = p_business_id
         AND branch_id = p_branch_id AND status = 'open')) THEN
    RAISE EXCEPTION 'REGISTER_REQUIRED: cash refund needs an open register session' USING ERRCODE='22023';
  END IF;

  -- PASS 2: header written ONCE with final values (returns are immutable)
  v_num := fn_next_sequence(p_business_id, 'R');
  INSERT INTO returns (id, business_id, branch_id, original_sale_id, return_number, return_type, customer_id,
                       credit_value_base, refund_amount_base, refund_method, exchange_group_id, replacement_sale_id,
                       reason, note, processed_by, client_transaction_id, request_fingerprint, reason_code)
  VALUES (v_ret_id, p_business_id, p_branch_id, p_sale_id, v_num, p_return_type, s.customer_id,
          v_credit, v_refund, CASE WHEN v_refund > 0 THEN p_refund_method END,
          p_exchange_group_id, p_replacement_sale_id, p_reason, p_note, v_actor, p_client_transaction_id, v_fp, p_reason_code);

  -- PASS 3: items, pool re-entry at ORIGINAL unit_cost_at_sale, ledger, COGS reversal record
  FOR it IN SELECT * FROM _return_lines ORDER BY variant_id, sale_item_id LOOP
    v_ri_id := gen_random_uuid();
    INSERT INTO return_items (id, return_id, sale_item_id, variant_id, quantity, disposition, unit_price_at_sale, reason, reason_code)
    VALUES (v_ri_id, v_ret_id, it.sale_item_id, it.variant_id, it.qty, it.disp, it.unit_price, it.reason, p_reason_code);
    pr := fn_post_to_cost_pool(p_business_id, p_branch_id, it.variant_id, it.qty, it.unit_cost, NULL);
    PERFORM fn_ledger_post(p_business_id, p_branch_id, it.variant_id, it.disp, it.qty, 'customer_return',
                           'return_item', v_ri_id, pr.unit_cost_used, pr.value_delta_base,
                           COALESCE(it.reason, p_reason_code) , now(), v_actor);
    INSERT INTO return_item_costs (return_item_id, business_id, unit_cost_at_sale, line_cost_base)
    VALUES (v_ri_id, p_business_id, it.unit_cost, round(it.unit_cost * it.qty, 6));
  END LOOP;

  IF v_refund > 0 AND p_refund_method = 'cash' THEN
    INSERT INTO cash_movements (business_id, register_session_id, movement_type, currency, amount, exchange_rate,
                                reference_type, reference_id, note, created_by)
    VALUES (p_business_id, p_register_session_id, 'refund_cash_out', 'TRY', -v_refund, 1, 'return', v_ret_id, p_reason, v_actor);
  END IF;

  RETURN jsonb_build_object('return_id', v_ret_id, 'return_number', v_num, 'credit_value_base', v_credit, 'refund_amount_base', v_refund, 'replayed', false);
END $$;
REVOKE EXECUTE ON FUNCTION fn_return_core_ext(UUID,UUID,UUID,JSONB,return_type,TEXT,TEXT,UUID,UUID,UUID,payment_method,TEXT,UUID,TEXT,NUMERIC) FROM PUBLIC, anon, authenticated;

-- the Rev 3 signature stays for rpc_process_return / rpc_process_exchange
CREATE OR REPLACE FUNCTION fn_return_core(
  p_business_id UUID, p_branch_id UUID, p_sale_id UUID, p_items JSONB,
  p_return_type return_type, p_reason TEXT, p_note TEXT,
  p_exchange_group_id UUID, p_replacement_sale_id UUID,
  p_register_session_id UUID, p_refund_method payment_method
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  RETURN fn_return_core_ext(p_business_id, p_branch_id, p_sale_id, p_items, p_return_type, p_reason, p_note,
                            p_exchange_group_id, p_replacement_sale_id, p_register_session_id, p_refund_method,
                            NULL, NULL, NULL, NULL);
END $$;
REVOKE EXECUTE ON FUNCTION fn_return_core(UUID,UUID,UUID,JSONB,return_type,TEXT,TEXT,UUID,UUID,UUID,payment_method) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ 6. sale quote (what fn_sale_core will charge)
-- Same pricing as fn_sale_core step 5 (list = variant override or product default, unit = requested
-- or list, tax-exclusive tax added). rpc_pos_exchange uses it to decide the downgrade treatment
-- BEFORE posting and asserts the posted total equals the quote.
CREATE OR REPLACE FUNCTION fn_sale_quote(p_business_id UUID, p_items JSONB)
RETURNS NUMERIC LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE it RECORD; v_total NUMERIC := 0; v_tax_excl NUMERIC := 0; v_unit NUMERIC;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_CART: no items' USING ERRCODE='22023';
  END IF;
  FOR it IN SELECT (e->>'variant_id')::UUID AS variant_id, (e->>'quantity')::INT AS qty, (e->>'unit_price')::NUMERIC AS unit_price,
                   COALESCE(pv.sale_price_override, p.default_sale_price) AS db_price, p.tax_rate, p.is_tax_inclusive
            FROM jsonb_array_elements(p_items) e
            LEFT JOIN product_variants pv ON pv.id = (e->>'variant_id')::UUID AND pv.business_id = p_business_id
            LEFT JOIN products p ON p.id = pv.product_id LOOP
    IF it.db_price IS NULL THEN RAISE EXCEPTION 'INVALID_VARIANT: cart contains a variant that is not in this business' USING ERRCODE='22023'; END IF;
    IF it.qty IS NULL OR it.qty <= 0 THEN RAISE EXCEPTION 'INVALID_ITEM: variant_id and quantity>0 required' USING ERRCODE='22023'; END IF;
    v_unit := COALESCE(it.unit_price, it.db_price);
    v_total := v_total + v_unit * it.qty;
    IF NOT it.is_tax_inclusive THEN v_tax_excl := v_tax_excl + round(v_unit * it.qty * it.tax_rate / 100, 2); END IF;
  END LOOP;
  RETURN round(v_total + v_tax_excl, 2);
END $$;
REVOKE EXECUTE ON FUNCTION fn_sale_quote(UUID, JSONB) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ 7. POS entry points
-- Plain return (refund or record-only). Business and branch come from the sale.
CREATE OR REPLACE FUNCTION rpc_pos_return(
  p_sale_id UUID, p_items JSONB, p_return_type return_type, p_client_transaction_id UUID,
  p_reason_code TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL,
  p_register_session_id UUID DEFAULT NULL, p_refund_method payment_method DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s RECORD;
BEGIN
  IF p_client_transaction_id IS NULL THEN
    RAISE EXCEPTION 'CLIENT_TRANSACTION_REQUIRED: POS returns must carry a client_transaction_id' USING ERRCODE='22023';
  END IF;
  IF p_return_type = 'exchange' THEN
    RAISE EXCEPTION 'USE_EXCHANGE_RPC: exchanges must be posted with rpc_pos_exchange (return + replacement sale atomically)' USING ERRCODE='22023';
  END IF;
  SELECT id, business_id, branch_id INTO s FROM sales WHERE id = p_sale_id;
  IF s.id IS NULL OR NOT fn_is_member(s.business_id) THEN
    RAISE EXCEPTION 'NOT_FOUND: sale %', p_sale_id USING ERRCODE='P0002';
  END IF;
  RETURN fn_return_core_ext(s.business_id, s.branch_id, p_sale_id, p_items, p_return_type, NULL, p_note,
                            NULL, NULL, p_register_session_id, p_refund_method,
                            p_reason_code, p_client_transaction_id, NULL, NULL);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_return(UUID,JSONB,return_type,UUID,TEXT,TEXT,UUID,payment_method) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_return(UUID,JSONB,return_type,UUID,TEXT,TEXT,UUID,payment_method) TO authenticated;

-- Exchange = return of the original lines + a linked replacement sale, one transaction.
-- Business / branch come from the register session; the original sale must belong to the
-- same business and branch. The merchandise credit is applied to the replacement sale; a
-- replacement cheaper than the credit follows the policy's downgrade_treatment.
CREATE OR REPLACE FUNCTION rpc_pos_exchange(
  p_register_session_id UUID, p_original_sale_id UUID, p_return_items JSONB, p_new_items JSONB, p_payments JSONB,
  p_client_transaction_id UUID,
  p_reason_code TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL,
  p_customer_id UUID DEFAULT NULL, p_salesperson_id UUID DEFAULT NULL, p_device_id TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  sess RECORD; s RECORD; v_pol JSONB; v_credit NUMERIC := 0; v_quote NUMERIC; v_applied NUMERIC; v_refund NUMERIC;
  v_group UUID := gen_random_uuid(); v_sale_id UUID := gen_random_uuid(); v_fp TEXT; v_ret JSONB; v_sale JSONB; v_existing RECORD;
BEGIN
  IF p_client_transaction_id IS NULL THEN
    RAISE EXCEPTION 'CLIENT_TRANSACTION_REQUIRED: POS exchanges must carry a client_transaction_id' USING ERRCODE='22023';
  END IF;
  IF p_new_items IS NULL OR jsonb_typeof(p_new_items) <> 'array' OR jsonb_array_length(p_new_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_CART: an exchange needs at least one replacement item' USING ERRCODE='22023';
  END IF;
  SELECT id, business_id, branch_id, status INTO sess FROM register_sessions WHERE id = p_register_session_id;
  IF sess.id IS NULL OR NOT fn_is_member(sess.business_id) THEN
    RAISE EXCEPTION 'INVALID_REGISTER_SESSION: % not found', p_register_session_id USING ERRCODE='22023';
  END IF;
  PERFORM fn_require_role(sess.business_id, ARRAY['owner','manager']::user_role[]);
  IF sess.status <> 'open' THEN RAISE EXCEPTION 'REGISTER_CLOSED: session % is closed', p_register_session_id USING ERRCODE='55000'; END IF;
  SELECT id, business_id, branch_id INTO s FROM sales WHERE id = p_original_sale_id AND business_id = sess.business_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: sale %', p_original_sale_id USING ERRCODE='P0002'; END IF;
  IF s.branch_id <> sess.branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH: sale % belongs to another branch', p_original_sale_id USING ERRCODE='22023';
  END IF;

  -- idempotency over the whole exchange payload (the sale core re-checks with this fingerprint)
  PERFORM pg_advisory_xact_lock(hashtext(sess.business_id::text || ':' || p_client_transaction_id::text));
  v_fp := encode(sha256(convert_to(jsonb_build_object(
            'x', p_original_sale_id, 'ri', p_return_items, 'ni', p_new_items, 'p', p_payments, 'br', sess.branch_id,
            's', p_register_session_id, 'c', p_customer_id, 'sp', p_salesperson_id, 'rc', p_reason_code)::text, 'UTF8')), 'hex');
  SELECT id, sale_number, total, amount_due_base, change_given_base, request_fingerprint INTO v_existing
  FROM sales WHERE business_id = sess.business_id AND client_transaction_id = p_client_transaction_id;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fp THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: client_transaction_id % was used with a different payload', p_client_transaction_id USING ERRCODE='23505';
    END IF;
    RETURN jsonb_build_object('sale_id', v_existing.id, 'sale_number', v_existing.sale_number, 'total', v_existing.total,
                              'amount_due', v_existing.amount_due_base, 'change_given', v_existing.change_given_base,
                              'return', (SELECT jsonb_build_object('return_id', r.id, 'return_number', r.return_number,
                                                                   'credit_value_base', r.credit_value_base, 'refund_amount_base', r.refund_amount_base)
                                         FROM returns r WHERE r.replacement_sale_id = v_existing.id),
                              'exchange_group_id', (SELECT exchange_group_id FROM sales WHERE id = v_existing.id),
                              'replayed', true);
  END IF;

  IF p_return_items IS NULL OR jsonb_typeof(p_return_items) <> 'array' OR jsonb_array_length(p_return_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_RETURN: no items' USING ERRCODE='22023';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_return_items) e
             WHERE NOT EXISTS (SELECT 1 FROM sale_items si WHERE si.id = (e->>'sale_item_id')::UUID AND si.sale_id = p_original_sale_id)) THEN
    RAISE EXCEPTION 'INVALID_ITEM: sale_item not on sale %', p_original_sale_id USING ERRCODE='22023';
  END IF;
  -- merchandise credit (the core recomputes it under lock; both must agree)
  SELECT COALESCE(round(SUM(si.unit_price_at_sale * (e->>'quantity')::INT), 2), 0) INTO v_credit
  FROM jsonb_array_elements(COALESCE(p_return_items, '[]'::jsonb)) e
  JOIN sale_items si ON si.id = (e->>'sale_item_id')::UUID AND si.sale_id = p_original_sale_id;
  IF v_credit <= 0 THEN RAISE EXCEPTION 'EMPTY_RETURN: no items' USING ERRCODE='22023'; END IF;
  v_quote := fn_sale_quote(sess.business_id, p_new_items);
  v_pol := fn_return_policy(sess.business_id);
  IF v_credit > v_quote THEN
    CASE v_pol ->> 'downgrade_treatment'
      WHEN 'cash_refund' THEN
        IF NOT (v_pol ->> 'allow_cash_refund')::BOOLEAN THEN
          RAISE EXCEPTION 'EXCHANGE_DOWNGRADE_BLOCKED: credit % exceeds replacement % and cash refunds are disabled', v_credit, v_quote USING ERRCODE='55000';
        END IF;
        v_applied := v_quote; v_refund := round(v_credit - v_quote, 2);
      WHEN 'store_credit' THEN
        RAISE EXCEPTION 'NOT_IMPLEMENTED: store credit ledger is not part of V1' USING ERRCODE='0A000';
      ELSE
        RAISE EXCEPTION 'EXCHANGE_DOWNGRADE_BLOCKED: credit % exceeds replacement % (policy: block)', v_credit, v_quote USING ERRCODE='55000';
    END CASE;
  ELSE
    v_applied := v_credit; v_refund := NULL;
  END IF;

  -- 1. return (FK to replacement sale is DEFERRABLE; validated at commit)
  v_ret := fn_return_core_ext(sess.business_id, sess.branch_id, p_original_sale_id, p_return_items, 'exchange', NULL, p_note,
                              v_group, v_sale_id, p_register_session_id, CASE WHEN v_refund IS NOT NULL THEN 'cash'::payment_method END,
                              p_reason_code, NULL, NULL, v_refund);
  IF (v_ret ->> 'credit_value_base')::NUMERIC <> v_credit THEN
    RAISE EXCEPTION 'INTEGRITY: credit % vs core %', v_credit, v_ret ->> 'credit_value_base' USING ERRCODE='23000';
  END IF;
  -- 2. replacement sale with the merchandise credit applied
  v_sale := fn_sale_core(sess.business_id, sess.branch_id, p_register_session_id, p_customer_id, NULL,
                         p_client_transaction_id, p_device_id, NULL, p_new_items, p_payments,
                         NULL, p_note, v_applied, v_group, v_sale_id, v_fp, p_salesperson_id);
  IF (v_sale ->> 'total')::NUMERIC <> v_quote THEN
    RAISE EXCEPTION 'INTEGRITY: quote % vs posted total %', v_quote, v_sale ->> 'total' USING ERRCODE='23000';
  END IF;
  RETURN v_sale || jsonb_build_object('return', v_ret, 'exchange_group_id', v_group, 'credit_applied', v_applied, 'refund_amount_base', COALESCE(v_refund, 0));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_exchange(UUID,UUID,JSONB,JSONB,JSONB,UUID,TEXT,TEXT,UUID,UUID,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_exchange(UUID,UUID,JSONB,JSONB,JSONB,UUID,TEXT,TEXT,UUID,UUID,TEXT) TO authenticated;

-- ------------------------------------------------------------ 8. preparation (any selling member; read-only; no cost)
-- Per-line eligibility for the operator screen. The posting RPC re-validates everything
-- under lock; this is the same policy read without side effects.
CREATE OR REPLACE FUNCTION rpc_return_eligibility(p_sale_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s RECORD; v_pol JSONB; v_window INT; v_expired BOOLEAN; v_lines JSONB; v_days_left INT;
BEGIN
  SELECT sa.*, b.name AS branch_name, c.full_name AS customer_name, c.phone AS customer_phone
  INTO s FROM sales sa JOIN branches b ON b.id = sa.branch_id LEFT JOIN customers c ON c.id = sa.customer_id
  WHERE sa.id = p_sale_id;
  IF s.id IS NULL OR NOT fn_is_member(s.business_id) THEN RAISE EXCEPTION 'NOT_FOUND: sale %', p_sale_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(s.business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  v_pol := fn_return_policy(s.business_id);
  v_window := (v_pol ->> 'exchange_window_days')::INT;
  v_expired := now() > s.occurred_at + make_interval(days => v_window);
  v_days_left := GREATEST(0, (s.occurred_at::date + v_window) - CURRENT_DATE);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'sale_item_id', si.id, 'variant_id', si.variant_id, 'sku', pv.sku, 'product_name', p.name,
      'options', (SELECT string_agg(ov.value, ' / ' ORDER BY po.sort_order)
                  FROM variant_option_values vov JOIN option_values ov ON ov.id = vov.option_value_id
                  JOIN product_options po ON po.id = vov.product_option_id WHERE vov.variant_id = pv.id),
      'quantity', si.quantity, 'returned_quantity', COALESCE(r.returned_quantity, 0),
      'returnable_quantity', CASE WHEN s.status <> 'completed' OR v_expired OR COALESCE(p.is_final_sale, false) OR COALESCE(c.is_final_sale, false)
                                  THEN 0 ELSE si.quantity - COALESCE(r.returned_quantity, 0) END,
      'unit_price_at_sale', si.unit_price_at_sale, 'list_price', si.list_price,
      'status', CASE WHEN s.status <> 'completed' THEN 'SALE_VOIDED'
                     WHEN COALESCE(p.is_final_sale, false) OR COALESCE(c.is_final_sale, false) THEN 'EXCLUDED'
                     WHEN v_expired THEN 'WINDOW_EXPIRED'
                     WHEN si.quantity - COALESCE(r.returned_quantity, 0) <= 0 THEN 'NOTHING_LEFT'
                     ELSE 'ELIGIBLE' END,
      'excluded_by', CASE WHEN COALESCE(p.is_final_sale, false) THEN 'product' WHEN COALESCE(c.is_final_sale, false) THEN 'category' END
    ) ORDER BY p.name, pv.sku), '[]'::jsonb)
  INTO v_lines
  FROM sale_items si JOIN product_variants pv ON pv.id = si.variant_id JOIN products p ON p.id = pv.product_id
  LEFT JOIN categories c ON c.id = p.category_id
  LEFT JOIN v_sale_item_returned r ON r.sale_item_id = si.id
  WHERE si.sale_id = s.id;

  RETURN jsonb_build_object(
    'sale', jsonb_build_object('id', s.id, 'sale_number', s.sale_number, 'status', s.status, 'occurred_at', s.occurred_at,
                               'branch_id', s.branch_id, 'branch_name', s.branch_name, 'total', s.total,
                               'customer_id', s.customer_id, 'customer_name', s.customer_name, 'customer_phone', s.customer_phone,
                               'exchange_group_id', s.exchange_group_id),
    'policy', v_pol || jsonb_build_object('window_expired', v_expired, 'days_left', v_days_left),
    'returns', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', r.id, 'return_number', r.return_number, 'return_type', r.return_type,
                  'credit_value_base', r.credit_value_base, 'refund_amount_base', r.refund_amount_base, 'created_at', r.created_at,
                  'replacement_sale_id', r.replacement_sale_id) ORDER BY r.created_at), '[]'::jsonb)
                FROM returns r WHERE r.original_sale_id = s.id),
    'reasons', (SELECT COALESCE(jsonb_agg(jsonb_build_object('code', rr.code, 'label', rr.label) ORDER BY rr.sort_order, rr.label), '[]'::jsonb)
                FROM return_reasons rr WHERE rr.is_active AND (rr.business_id IS NULL OR rr.business_id = s.business_id)
                  AND NOT EXISTS (SELECT 1 FROM return_reasons t WHERE t.business_id = s.business_id AND t.code = rr.code AND rr.business_id IS NULL)),
    'lines', v_lines);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_return_eligibility(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_return_eligibility(UUID) TO authenticated;

-- Sale lookup for a return: by receipt number, by a barcode on the receipt, or by customer.
-- A customer holding a receipt is served by whoever is at the counter, so this deliberately
-- reads across the 'own' sales visibility scope — receipt-level fields only, never cost.
CREATE OR REPLACE FUNCTION rpc_pos_find_sales(p_business_id UUID, p_mode TEXT, p_query TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_q TEXT := trim(COALESCE(p_query, '')); v_out JSONB; v_window INT;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  IF length(v_q) < 2 OR length(v_q) > 80 THEN RETURN '[]'::jsonb; END IF;
  v_window := (fn_return_policy(p_business_id) ->> 'exchange_window_days')::INT;
  WITH cand AS (
    SELECT sa.id FROM sales sa
    WHERE sa.business_id = p_business_id AND p_mode = 'sale_number' AND upper(sa.sale_number) = upper(v_q)
    UNION
    SELECT DISTINCT sa.id FROM sales sa JOIN sale_items si ON si.sale_id = sa.id JOIN barcodes bc ON bc.variant_id = si.variant_id
    WHERE sa.business_id = p_business_id AND p_mode = 'barcode' AND bc.barcode = v_q
      AND sa.occurred_at >= now() - make_interval(days => v_window + 1)
    UNION
    SELECT sa.id FROM sales sa JOIN customers c ON c.id = sa.customer_id
    WHERE sa.business_id = p_business_id AND p_mode = 'customer'
      AND (c.full_name ILIKE '%' || v_q || '%' OR c.phone ILIKE '%' || v_q || '%')
      AND sa.occurred_at >= now() - make_interval(days => v_window + 1)
  )
  SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'occurred_at') DESC), '[]'::jsonb) INTO v_out
  FROM (
    SELECT jsonb_build_object('id', sa.id, 'sale_number', sa.sale_number, 'status', sa.status, 'occurred_at', sa.occurred_at,
             'total', sa.total, 'branch_id', sa.branch_id, 'customer_name', c.full_name, 'customer_phone', c.phone,
             'item_count', (SELECT COALESCE(SUM(quantity), 0) FROM sale_items WHERE sale_id = sa.id),
             'returned_count', (SELECT COALESCE(SUM(ri.quantity), 0) FROM return_items ri JOIN sale_items si2 ON si2.id = ri.sale_item_id WHERE si2.sale_id = sa.id),
             'is_exchange_replacement', sa.exchange_group_id IS NOT NULL AND sa.credit_applied_base > 0) AS x
    FROM cand JOIN sales sa ON sa.id = cand.id LEFT JOIN customers c ON c.id = sa.customer_id
    ORDER BY sa.occurred_at DESC LIMIT 20
  ) q;
  RETURN v_out;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_find_sales(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_find_sales(UUID, TEXT, TEXT) TO authenticated;

-- Return document for the receipt screen (same visibility as the return row: processor,
-- manager+, or whoever may see the original sale; names resolved server-side).
CREATE OR REPLACE FUNCTION rpc_return_document(p_return_id UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT jsonb_build_object(
    'id', r.id, 'return_number', r.return_number, 'return_type', r.return_type, 'created_at', r.created_at,
    'original_sale_id', r.original_sale_id, 'original_sale_number', s.sale_number,
    'replacement_sale_id', r.replacement_sale_id, 'replacement_sale_number', rs.sale_number,
    'credit_value_base', r.credit_value_base, 'refund_amount_base', r.refund_amount_base, 'refund_method', r.refund_method,
    'reason_code', r.reason_code, 'reason_label', (SELECT label FROM return_reasons rr WHERE rr.code = r.reason_code AND (rr.business_id IS NULL OR rr.business_id = r.business_id) ORDER BY rr.business_id NULLS LAST LIMIT 1),
    'note', r.note, 'processed_by_name', p.full_name, 'branch_name', b.name,
    'customer', CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object('id', c.id, 'full_name', c.full_name, 'phone', c.phone) END,
    'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', ri.id, 'variant_id', ri.variant_id, 'sku', pv.sku, 'product_name', pr.name,
                'quantity', ri.quantity, 'disposition', ri.disposition, 'unit_price_at_sale', ri.unit_price_at_sale) ORDER BY pr.name, pv.sku), '[]'::jsonb)
              FROM return_items ri JOIN product_variants pv ON pv.id = ri.variant_id JOIN products pr ON pr.id = pv.product_id WHERE ri.return_id = r.id))
  FROM returns r JOIN sales s ON s.id = r.original_sale_id LEFT JOIN sales rs ON rs.id = r.replacement_sale_id
  JOIN branches b ON b.id = r.branch_id LEFT JOIN customers c ON c.id = r.customer_id LEFT JOIN profiles p ON p.id = r.processed_by
  WHERE r.id = p_return_id AND fn_can_see_return_id(r.id);
$$;
REVOKE EXECUTE ON FUNCTION rpc_return_document(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_return_document(UUID) TO authenticated;
