-- ============================================================
-- Phase 10B — Reporting foundation (read-only)
--
-- Reports are derived from the authoritative operational records (completed sales, sale
-- items, payments, historical COGS, returns/exchanges with their historical COGS, the
-- inventory ledger, posted goods receipts, customers, salesperson attribution). No
-- reporting ledger is introduced: every number is an aggregate over those tables computed
-- inside PostgreSQL, one bounded RPC per report surface.
--
-- Timezone: date grouping uses the tenant timezone, settings.timezone (IANA name,
-- validated by trigger). When the key is absent the platform default Europe/Istanbul is
-- used and reported back as timezone_set=false so the UI can say so — never server UTC.
--
-- Access: reports are authorised inside the RPC from the caller's membership; the
-- p_business_id argument only selects the tenant, it never grants anything.
--   owner / manager : everything, including COGS, gross profit, margin, valuation,
--                     purchasing and supplier figures ("financial" = true)
--   sales_staff     : sales-side reports restricted by sales_visibility_scope (own /
--                     branch / business, plus what they sold or are attributed) — units,
--                     counts and selling totals only; financial keys are absent
--   stock_staff     : stock report only (quantities, no valuation); sales reports FORBIDDEN
--
-- Metric definitions (see docs/10 §21 for the prose):
--   gross_sales   = Σ sale_items.list_price × quantity          (completed sales in window)
--   discounts     = Σ sale_items.discount_amount
--   net_sales     = Σ sale_items.line_total (= sales.total; tax is 0 in Rev 3)
--   returns_value = Σ return_items.unit_price_at_sale × quantity (returns in window, all
--                   types — an exchange's replacement sale counts fully in net_sales)
--   net_sales_after_returns = net_sales − returns_value
--   cogs          = Σ sale_item_costs.line_cost_base (historical, captured at sale)
--   returned_cogs = Σ return_item_costs.line_cost_base (historical, captured at return)
--   gross_profit  = net_sales_after_returns − (cogs − returned_cogs)
--   gross_margin  = gross_profit / net_sales_after_returns (NULL when that is 0)
--   avg_basket    = net_sales / transactions (NULL when there are none)
-- A sale belongs to the day of sales.occurred_at, a return to returns.created_at, a
-- receipt to goods_receipts.posted_at, all in the tenant timezone. Voided sales are
-- excluded everywhere; draft receipts never enter financial totals.
-- ============================================================

-- ------------------------------------------------------------ 1. tenant timezone
CREATE OR REPLACE FUNCTION fn_business_timezone(p_business_id UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(NULLIF(settings ->> 'timezone', ''), 'Europe/Istanbul') FROM businesses WHERE id = p_business_id;
$$;
REVOKE EXECUTE ON FUNCTION fn_business_timezone(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_business_timezone(UUID) TO authenticated;

-- settings.timezone must be a real IANA zone; an owner editing settings directly gets the same check.
CREATE OR REPLACE FUNCTION fn_business_settings_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF NEW.settings ? 'timezone' THEN
    IF jsonb_typeof(NEW.settings -> 'timezone') <> 'string'
       OR NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.settings ->> 'timezone') THEN
      RAISE EXCEPTION 'INVALID_TIMEZONE: % is not an IANA time zone', NEW.settings ->> 'timezone' USING ERRCODE = '22023';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_business_settings_guard ON businesses;
CREATE TRIGGER trg_business_settings_guard
  BEFORE INSERT OR UPDATE OF settings ON businesses
  FOR EACH ROW EXECUTE FUNCTION fn_business_settings_guard();

-- owner / manager set the reporting timezone (the only settings key the app writes so far)
CREATE OR REPLACE FUNCTION rpc_business_set_timezone(p_business_id UUID, p_timezone TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(p_business_id);
  IF p_timezone IS NULL OR NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = p_timezone) THEN
    RAISE EXCEPTION 'INVALID_TIMEZONE: % is not an IANA time zone', p_timezone USING ERRCODE = '22023';
  END IF;
  UPDATE businesses SET settings = settings || jsonb_build_object('timezone', p_timezone), updated_at = now()
  WHERE id = p_business_id;
  RETURN jsonb_build_object('timezone', p_timezone);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_business_set_timezone(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_business_set_timezone(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------ 2. access + window helpers
-- Who is asking and what they may see. p_selling = the report is about sales (stock_staff refused).
CREATE OR REPLACE FUNCTION fn_report_access(p_business_id UUID, p_selling BOOLEAN,
  OUT member_role user_role, OUT is_manager BOOLEAN, OUT actor UUID, OUT scope TEXT, OUT my_branch UUID)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  member_role := fn_require_member(p_business_id);
  actor := fn_actor();
  is_manager := member_role IN ('owner','manager');
  IF p_selling AND member_role = 'stock_staff' THEN
    RAISE EXCEPTION 'FORBIDDEN: stock_staff has no sales reporting' USING ERRCODE = '42501';
  END IF;
  scope := CASE WHEN is_manager THEN 'business' ELSE fn_sales_visibility_scope(p_business_id) END;
  my_branch := fn_my_branch(p_business_id);
END $$;
REVOKE EXECUTE ON FUNCTION fn_report_access(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- Inclusive local dates → [ts_from, ts_to) in the tenant timezone. Bounded to 366 days.
CREATE OR REPLACE FUNCTION fn_report_window(p_business_id UUID, p_from DATE, p_to DATE,
  OUT ts_from TIMESTAMPTZ, OUT ts_to TIMESTAMPTZ, OUT tz TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'INVALID_RANGE: % .. %', p_from, p_to USING ERRCODE = '22023';
  END IF;
  IF p_to - p_from > 366 THEN
    RAISE EXCEPTION 'RANGE_TOO_LONG: reports are bounded to 366 days' USING ERRCODE = '22023';
  END IF;
  tz := fn_business_timezone(p_business_id);
  ts_from := (p_from::timestamp) AT TIME ZONE tz;
  ts_to   := ((p_to + 1)::timestamp) AT TIME ZONE tz;
END $$;
REVOKE EXECUTE ON FUNCTION fn_report_window(UUID, DATE, DATE) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_report_assert_branch(p_business_id UUID, p_branch_id UUID)
RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF p_branch_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM branches WHERE id = p_branch_id AND business_id = p_business_id) THEN
    RAISE EXCEPTION 'INVALID_BRANCH: branch % not in business %', p_branch_id, p_business_id USING ERRCODE = '22023';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION fn_report_assert_branch(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ 3. line sources
-- Plain SQL (invoker rights, no SET clause) so the planner can inline them into the calling
-- SECURITY DEFINER RPC, whose search_path they run under; they are never granted to clients. Visibility is the sales predicate of 3.5E/9A
-- evaluated once per call: manager, or sold/attributed to the actor, or the configured scope.
CREATE OR REPLACE FUNCTION fn_report_sale_lines(
  p_business_id UUID, p_ts_from TIMESTAMPTZ, p_ts_to TIMESTAMPTZ,
  p_branch_id UUID, p_salesperson_id UUID, p_category_id UUID, p_product_id UUID,
  p_is_manager BOOLEAN, p_actor UUID, p_scope TEXT, p_my_branch UUID)
RETURNS TABLE (
  sale_id UUID, occurred_at TIMESTAMPTZ, branch_id UUID, salesperson_id UUID, sold_by UUID, customer_id UUID,
  sale_item_id UUID, variant_id UUID, product_id UUID, category_id UUID,
  quantity INTEGER, gross NUMERIC, discount NUMERIC, net NUMERIC, cost NUMERIC)
LANGUAGE sql STABLE AS $$
  SELECT s.id, s.occurred_at, s.branch_id, s.salesperson_id, s.sold_by, s.customer_id,
         si.id, si.variant_id, pv.product_id, p.category_id,
         si.quantity, (si.list_price * si.quantity)::numeric, si.discount_amount::numeric, si.line_total::numeric,
         CASE WHEN p_is_manager THEN sic.line_cost_base::numeric END
  FROM sales s
  JOIN sale_items si ON si.sale_id = s.id
  JOIN product_variants pv ON pv.id = si.variant_id
  JOIN products p ON p.id = pv.product_id
  LEFT JOIN sale_item_costs sic ON p_is_manager AND sic.sale_item_id = si.id
  WHERE s.business_id = p_business_id AND s.status = 'completed'
    AND s.occurred_at >= p_ts_from AND s.occurred_at < p_ts_to
    AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    AND (p_salesperson_id IS NULL OR s.salesperson_id = p_salesperson_id)
    AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_product_id IS NULL OR pv.product_id = p_product_id)
    AND (p_is_manager OR s.sold_by = p_actor OR s.salesperson_id = p_actor OR p_scope = 'business'
         OR (p_scope = 'branch' AND p_my_branch IS NOT NULL AND s.branch_id = p_my_branch));
$$;
REVOKE EXECUTE ON FUNCTION fn_report_sale_lines(UUID,TIMESTAMPTZ,TIMESTAMPTZ,UUID,UUID,UUID,UUID,BOOLEAN,UUID,TEXT,UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_report_return_lines(
  p_business_id UUID, p_ts_from TIMESTAMPTZ, p_ts_to TIMESTAMPTZ,
  p_branch_id UUID, p_salesperson_id UUID, p_category_id UUID, p_product_id UUID,
  p_is_manager BOOLEAN, p_actor UUID, p_scope TEXT, p_my_branch UUID)
RETURNS TABLE (
  return_id UUID, created_at TIMESTAMPTZ, return_type return_type, branch_id UUID, original_sale_id UUID,
  salesperson_id UUID, customer_id UUID, return_item_id UUID, variant_id UUID, product_id UUID, category_id UUID,
  quantity INTEGER, value NUMERIC, cost NUMERIC, disposition inventory_bucket, reason_code TEXT)
LANGUAGE sql STABLE AS $$
  SELECT r.id, r.created_at, r.return_type, r.branch_id, r.original_sale_id,
         s.salesperson_id, r.customer_id, ri.id, ri.variant_id, pv.product_id, p.category_id,
         ri.quantity, (ri.unit_price_at_sale * ri.quantity)::numeric,
         CASE WHEN p_is_manager THEN ric.line_cost_base::numeric END,
         ri.disposition, COALESCE(ri.reason_code, r.reason_code)
  FROM returns r
  JOIN return_items ri ON ri.return_id = r.id
  JOIN sales s ON s.id = r.original_sale_id
  JOIN product_variants pv ON pv.id = ri.variant_id
  JOIN products p ON p.id = pv.product_id
  LEFT JOIN return_item_costs ric ON p_is_manager AND ric.return_item_id = ri.id
  WHERE r.business_id = p_business_id
    AND r.created_at >= p_ts_from AND r.created_at < p_ts_to
    AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
    AND (p_salesperson_id IS NULL OR s.salesperson_id = p_salesperson_id)
    AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_product_id IS NULL OR pv.product_id = p_product_id)
    AND (p_is_manager OR r.processed_by = p_actor OR s.sold_by = p_actor OR s.salesperson_id = p_actor OR p_scope = 'business'
         OR (p_scope = 'branch' AND p_my_branch IS NOT NULL AND s.branch_id = p_my_branch));
$$;
REVOKE EXECUTE ON FUNCTION fn_report_return_lines(UUID,TIMESTAMPTZ,TIMESTAMPTZ,UUID,UUID,UUID,UUID,BOOLEAN,UUID,TEXT,UUID) FROM PUBLIC, anon, authenticated;

-- Period totals over both sources. Financial keys only when p_is_manager.
CREATE OR REPLACE FUNCTION fn_report_period_totals(
  p_business_id UUID, p_ts_from TIMESTAMPTZ, p_ts_to TIMESTAMPTZ,
  p_branch_id UUID, p_salesperson_id UUID, p_category_id UUID, p_product_id UUID,
  p_is_manager BOOLEAN, p_actor UUID, p_scope TEXT, p_my_branch UUID)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  WITH s AS (
    SELECT count(DISTINCT sale_id) AS tx, COALESCE(sum(quantity), 0) AS units,
           COALESCE(sum(gross), 0) AS gross, COALESCE(sum(discount), 0) AS disc,
           COALESCE(sum(net), 0) AS net, COALESCE(sum(cost), 0) AS cost
    FROM fn_report_sale_lines(p_business_id, p_ts_from, p_ts_to, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                              p_is_manager, p_actor, p_scope, p_my_branch)),
  r AS (
    SELECT count(DISTINCT return_id) AS cnt,
           count(DISTINCT return_id) FILTER (WHERE return_type = 'exchange') AS exch,
           COALESCE(sum(quantity), 0) AS units, COALESCE(sum(value), 0) AS val, COALESCE(sum(cost), 0) AS cost
    FROM fn_report_return_lines(p_business_id, p_ts_from, p_ts_to, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                                p_is_manager, p_actor, p_scope, p_my_branch))
  SELECT jsonb_build_object(
           'transactions', s.tx, 'units', s.units,
           'gross_sales', round(s.gross, 2), 'discounts', round(s.disc, 2), 'net_sales', round(s.net, 2),
           'avg_basket', CASE WHEN s.tx > 0 THEN round(s.net / s.tx, 2) END,
           'returns_count', r.cnt, 'exchanges_count', r.exch, 'returned_units', r.units,
           'returns_value', round(r.val, 2), 'net_sales_after_returns', round(s.net - r.val, 2))
         || CASE WHEN p_is_manager THEN jsonb_build_object(
           'cogs', round(s.cost, 2), 'returned_cogs', round(r.cost, 2),
           'gross_profit', round((s.net - r.val) - (s.cost - r.cost), 2),
           'gross_margin_pct', CASE WHEN (s.net - r.val) > 0
                                    THEN round(((s.net - r.val) - (s.cost - r.cost)) / (s.net - r.val) * 100, 2) END)
         ELSE '{}'::jsonb END
  FROM s, r;
$$;
REVOKE EXECUTE ON FUNCTION fn_report_period_totals(UUID,TIMESTAMPTZ,TIMESTAMPTZ,UUID,UUID,UUID,UUID,BOOLEAN,UUID,TEXT,UUID) FROM PUBLIC, anon, authenticated;

-- Daily series in the tenant timezone (days with activity only; the UI fills the gaps).
CREATE OR REPLACE FUNCTION fn_report_daily(
  p_business_id UUID, p_ts_from TIMESTAMPTZ, p_ts_to TIMESTAMPTZ, p_tz TEXT,
  p_branch_id UUID, p_salesperson_id UUID, p_category_id UUID, p_product_id UUID,
  p_is_manager BOOLEAN, p_actor UUID, p_scope TEXT, p_my_branch UUID)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  WITH s AS (
    SELECT (occurred_at AT TIME ZONE p_tz)::date AS d, count(DISTINCT sale_id) AS tx, sum(quantity) AS units, sum(net) AS net, sum(cost) AS cost
    FROM fn_report_sale_lines(p_business_id, p_ts_from, p_ts_to, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                              p_is_manager, p_actor, p_scope, p_my_branch)
    GROUP BY 1),
  r AS (
    SELECT (created_at AT TIME ZONE p_tz)::date AS d, count(DISTINCT return_id) AS cnt, sum(value) AS val, sum(cost) AS cost
    FROM fn_report_return_lines(p_business_id, p_ts_from, p_ts_to, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                                p_is_manager, p_actor, p_scope, p_my_branch)
    GROUP BY 1)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'date', d, 'transactions', COALESCE(s.tx, 0), 'units', COALESCE(s.units, 0),
           'net_sales', round(COALESCE(s.net, 0), 2), 'returns_count', COALESCE(r.cnt, 0), 'returns_value', round(COALESCE(r.val, 0), 2))
           || CASE WHEN p_is_manager THEN jsonb_build_object(
                'gross_profit', round((COALESCE(s.net, 0) - COALESCE(r.val, 0)) - (COALESCE(s.cost, 0) - COALESCE(r.cost, 0)), 2))
              ELSE '{}'::jsonb END
         ORDER BY d), '[]'::jsonb)
  FROM s FULL JOIN r USING (d);
$$;
REVOKE EXECUTE ON FUNCTION fn_report_daily(UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,UUID,UUID,UUID,UUID,BOOLEAN,UUID,TEXT,UUID) FROM PUBLIC, anon, authenticated;

-- Ranked rows by product / variant / category / color / size (sales and returns of the window).
CREATE OR REPLACE FUNCTION fn_report_product_rows(
  p_business_id UUID, p_ts_from TIMESTAMPTZ, p_ts_to TIMESTAMPTZ,
  p_branch_id UUID, p_salesperson_id UUID, p_category_id UUID, p_product_id UUID,
  p_is_manager BOOLEAN, p_actor UUID, p_scope TEXT, p_my_branch UUID,
  p_group TEXT, p_limit INTEGER)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  WITH l AS (
    SELECT l.sale_id, l.quantity, l.gross, l.discount, l.net, l.cost,
           CASE p_group WHEN 'product' THEN l.product_id::text WHEN 'variant' THEN l.variant_id::text
                        WHEN 'category' THEN COALESCE(l.category_id::text, '-') ELSE COALESCE(opt.value, '-') END AS k,
           CASE p_group WHEN 'category' THEN COALESCE(c.name, 'Kategorisiz') WHEN 'product' THEN p.name WHEN 'variant' THEN p.name
                        ELSE COALESCE(opt.value, '—') END AS label,
           CASE p_group WHEN 'variant' THEN pv.sku WHEN 'product' THEN p.sku_prefix END AS sub
    FROM fn_report_sale_lines(p_business_id, p_ts_from, p_ts_to, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                              p_is_manager, p_actor, p_scope, p_my_branch) l
    JOIN product_variants pv ON pv.id = l.variant_id
    JOIN products p ON p.id = l.product_id
    LEFT JOIN categories c ON c.id = l.category_id
    LEFT JOIN LATERAL (
      SELECT ov.value FROM variant_option_values vov
      JOIN product_options po ON po.id = vov.product_option_id
      JOIN option_values ov ON ov.id = vov.option_value_id
      WHERE vov.variant_id = l.variant_id AND po.kind::text = p_group LIMIT 1) opt ON p_group IN ('color','size')
    WHERE p_group NOT IN ('color','size') OR opt.value IS NOT NULL),
  r AS (
    SELECT r.return_id, r.quantity, r.value, r.cost,
           CASE p_group WHEN 'product' THEN r.product_id::text WHEN 'variant' THEN r.variant_id::text
                        WHEN 'category' THEN COALESCE(r.category_id::text, '-') ELSE COALESCE(opt.value, '-') END AS k,
           CASE p_group WHEN 'category' THEN COALESCE(c.name, 'Kategorisiz') WHEN 'product' THEN p.name WHEN 'variant' THEN p.name
                        ELSE COALESCE(opt.value, '—') END AS label,
           CASE p_group WHEN 'variant' THEN pv.sku WHEN 'product' THEN p.sku_prefix END AS sub
    FROM fn_report_return_lines(p_business_id, p_ts_from, p_ts_to, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                                p_is_manager, p_actor, p_scope, p_my_branch) r
    JOIN product_variants pv ON pv.id = r.variant_id
    JOIN products p ON p.id = r.product_id
    LEFT JOIN categories c ON c.id = r.category_id
    LEFT JOIN LATERAL (
      SELECT ov.value FROM variant_option_values vov
      JOIN product_options po ON po.id = vov.product_option_id
      JOIN option_values ov ON ov.id = vov.option_value_id
      WHERE vov.variant_id = r.variant_id AND po.kind::text = p_group LIMIT 1) opt ON p_group IN ('color','size')
    WHERE p_group NOT IN ('color','size') OR opt.value IS NOT NULL),
  sa AS (SELECT k, max(label) AS label, max(sub) AS sub, count(DISTINCT sale_id) AS tx, sum(quantity) AS units,
                sum(gross) AS gross, sum(discount) AS disc, sum(net) AS net, sum(cost) AS cost FROM l GROUP BY k),
  ra AS (SELECT k, max(label) AS label, max(sub) AS sub, count(DISTINCT return_id) AS cnt, sum(quantity) AS units,
                sum(value) AS val, sum(cost) AS cost FROM r GROUP BY k),
  x AS (
    SELECT COALESCE(sa.k, ra.k) AS k, COALESCE(sa.label, ra.label) AS label, COALESCE(sa.sub, ra.sub) AS sub,
           COALESCE(sa.tx, 0) AS tx, COALESCE(sa.units, 0) AS units, COALESCE(sa.gross, 0) AS gross, COALESCE(sa.disc, 0) AS disc,
           COALESCE(sa.net, 0) AS net, COALESCE(sa.cost, 0) AS cost,
           COALESCE(ra.cnt, 0) AS rcnt, COALESCE(ra.units, 0) AS runits, COALESCE(ra.val, 0) AS rval, COALESCE(ra.cost, 0) AS rcost
    FROM sa FULL JOIN ra ON ra.k = sa.k
    ORDER BY COALESCE(sa.net, 0) DESC, COALESCE(sa.units, 0) DESC, label
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200))
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'key', k, 'label', label, 'sub', sub, 'transactions', tx, 'units', units,
           'gross_sales', round(gross, 2), 'discounts', round(disc, 2), 'net_sales', round(net, 2),
           'returns_count', rcnt, 'returned_units', runits, 'returns_value', round(rval, 2),
           'net_sales_after_returns', round(net - rval, 2))
           || CASE WHEN p_is_manager THEN jsonb_build_object(
                'cogs', round(cost, 2), 'returned_cogs', round(rcost, 2),
                'gross_profit', round((net - rval) - (cost - rcost), 2),
                'gross_margin_pct', CASE WHEN (net - rval) > 0 THEN round(((net - rval) - (cost - rcost)) / (net - rval) * 100, 2) END)
              ELSE '{}'::jsonb END
         ORDER BY net DESC, units DESC, label), '[]'::jsonb)
  FROM x;
$$;
REVOKE EXECUTE ON FUNCTION fn_report_product_rows(UUID,TIMESTAMPTZ,TIMESTAMPTZ,UUID,UUID,UUID,UUID,BOOLEAN,UUID,TEXT,UUID,TEXT,INTEGER) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ 4. report RPCs
-- 4.1 overview: current + optional previous period + daily series
CREATE OR REPLACE FUNCTION rpc_report_overview(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL,
  p_prev_from DATE DEFAULT NULL, p_prev_to DATE DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; w RECORD; pw RECORD; v_prev JSONB;
BEGIN
  SELECT * INTO a FROM fn_report_access(p_business_id, true);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  IF p_prev_from IS NOT NULL AND p_prev_to IS NOT NULL THEN
    SELECT * INTO pw FROM fn_report_window(p_business_id, p_prev_from, p_prev_to);
    v_prev := fn_report_period_totals(p_business_id, pw.ts_from, pw.ts_to, p_branch_id, NULL, NULL, NULL,
                                      a.is_manager, a.actor, a.scope, a.my_branch);
  END IF;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_date_from, 'to', p_date_to, 'timezone', w.tz,
                                 'timezone_set', (SELECT settings ? 'timezone' FROM businesses WHERE id = p_business_id),
                                 'prev_from', p_prev_from, 'prev_to', p_prev_to),
    'scope', a.scope, 'financial', a.is_manager,
    'current', fn_report_period_totals(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, NULL, NULL,
                                       a.is_manager, a.actor, a.scope, a.my_branch),
    'previous', v_prev,
    'daily', fn_report_daily(p_business_id, w.ts_from, w.ts_to, w.tz, p_branch_id, NULL, NULL, NULL,
                             a.is_manager, a.actor, a.scope, a.my_branch));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_overview(UUID, DATE, DATE, UUID, DATE, DATE) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_overview(UUID, DATE, DATE, UUID, DATE, DATE) TO authenticated;

-- 4.2 sales: filters branch / salesperson / category / product; totals + daily + by branch
CREATE OR REPLACE FUNCTION rpc_report_sales(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL,
  p_salesperson_id UUID DEFAULT NULL, p_category_id UUID DEFAULT NULL, p_product_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; w RECORD; v_branches JSONB;
BEGIN
  SELECT * INTO a FROM fn_report_access(p_business_id, true);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('branch_id', b.id, 'branch', b.name, 'transactions', x.tx, 'units', x.units,
                                               'net_sales', round(x.net, 2), 'returns_value', round(x.rval, 2))
                            ORDER BY x.net DESC), '[]'::jsonb)
  INTO v_branches
  FROM (
    SELECT l.branch_id, count(DISTINCT l.sale_id) AS tx, sum(l.quantity) AS units, sum(l.net) AS net,
           COALESCE((SELECT sum(r.value) FROM fn_report_return_lines(p_business_id, w.ts_from, w.ts_to, l.branch_id, p_salesperson_id,
                     p_category_id, p_product_id, a.is_manager, a.actor, a.scope, a.my_branch) r), 0) AS rval
    FROM fn_report_sale_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                              a.is_manager, a.actor, a.scope, a.my_branch) l
    GROUP BY l.branch_id) x
  JOIN branches b ON b.id = x.branch_id;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_date_from, 'to', p_date_to, 'timezone', w.tz),
    'scope', a.scope, 'financial', a.is_manager,
    'filters', jsonb_build_object('branch_id', p_branch_id, 'salesperson_id', p_salesperson_id, 'category_id', p_category_id, 'product_id', p_product_id),
    'totals', fn_report_period_totals(p_business_id, w.ts_from, w.ts_to, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                                      a.is_manager, a.actor, a.scope, a.my_branch),
    'daily', fn_report_daily(p_business_id, w.ts_from, w.ts_to, w.tz, p_branch_id, p_salesperson_id, p_category_id, p_product_id,
                             a.is_manager, a.actor, a.scope, a.my_branch),
    'by_branch', v_branches);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_sales(UUID, DATE, DATE, UUID, UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_sales(UUID, DATE, DATE, UUID, UUID, UUID, UUID) TO authenticated;

-- 4.3 products: ranked by the requested grouping + fashion views
CREATE OR REPLACE FUNCTION rpc_report_products(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL,
  p_group TEXT DEFAULT 'product', p_category_id UUID DEFAULT NULL, p_limit INTEGER DEFAULT 50)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; w RECORD; v_oos JSONB;
BEGIN
  SELECT * INTO a FROM fn_report_access(p_business_id, true);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  IF p_group NOT IN ('product','variant','category','color','size') THEN
    RAISE EXCEPTION 'INVALID_GROUP: %', p_group USING ERRCODE = '22023';
  END IF;
  -- variants sold in the window that have no available stock now (sellable ledger − active holds)
  WITH sold AS (
    SELECT l.variant_id, sum(l.quantity) AS units
    FROM fn_report_sale_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, p_category_id, NULL,
                              a.is_manager, a.actor, a.scope, a.my_branch) l
    GROUP BY l.variant_id),
  stock AS (
    SELECT m.variant_id, sum(m.quantity) AS sellable FROM inventory_movements m
    WHERE m.business_id = p_business_id AND m.bucket = 'sellable' AND (p_branch_id IS NULL OR m.branch_id = p_branch_id)
      AND m.variant_id IN (SELECT variant_id FROM sold)
    GROUP BY m.variant_id),
  held AS (
    SELECT ri.variant_id, sum(ri.quantity) AS reserved FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id
    WHERE r.business_id = p_business_id AND r.status = 'active' AND r.expires_at > now() AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
      AND ri.variant_id IN (SELECT variant_id FROM sold)
    GROUP BY ri.variant_id)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('variant_id', z.id, 'sku', z.sku, 'product', z.name, 'units_sold', z.units, 'available', z.available)
                            ORDER BY z.units DESC, z.name), '[]'::jsonb)
  INTO v_oos
  FROM (SELECT pv.id, pv.sku, p.name, sold.units, COALESCE(st.sellable, 0) - COALESCE(h.reserved, 0) AS available
        FROM sold JOIN product_variants pv ON pv.id = sold.variant_id JOIN products p ON p.id = pv.product_id
        LEFT JOIN stock st ON st.variant_id = sold.variant_id LEFT JOIN held h ON h.variant_id = sold.variant_id
        WHERE pv.status = 'active' AND COALESCE(st.sellable, 0) - COALESCE(h.reserved, 0) <= 0
        ORDER BY sold.units DESC, p.name LIMIT 50) z;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_date_from, 'to', p_date_to, 'timezone', w.tz),
    'scope', a.scope, 'financial', a.is_manager, 'group', p_group,
    'rows', fn_report_product_rows(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, p_category_id, NULL,
                                   a.is_manager, a.actor, a.scope, a.my_branch, p_group, p_limit),
    'top_sizes', fn_report_product_rows(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, p_category_id, NULL,
                                        a.is_manager, a.actor, a.scope, a.my_branch, 'size', 8),
    'top_colors', fn_report_product_rows(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, p_category_id, NULL,
                                         a.is_manager, a.actor, a.scope, a.my_branch, 'color', 8),
    'out_of_stock_with_sales', v_oos);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_products(UUID, DATE, DATE, UUID, TEXT, UUID, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_products(UUID, DATE, DATE, UUID, TEXT, UUID, INTEGER) TO authenticated;

-- 4.4 staff: salesperson (attribution) separate from cashier (terminal actor)
CREATE OR REPLACE FUNCTION rpc_report_staff(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; w RECORD; v_sp JSONB; v_cashiers JSONB;
BEGIN
  SELECT * INTO a FROM fn_report_access(p_business_id, true);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  WITH l AS (
    SELECT * FROM fn_report_sale_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, NULL, NULL,
                                       a.is_manager, a.actor, a.scope, a.my_branch)),
  r AS (
    SELECT * FROM fn_report_return_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, NULL, NULL,
                                         a.is_manager, a.actor, a.scope, a.my_branch)),
  sa AS (SELECT salesperson_id, count(DISTINCT sale_id) AS tx, sum(quantity) AS units, sum(gross) AS gross, sum(discount) AS disc,
                sum(net) AS net, sum(cost) AS cost FROM l GROUP BY salesperson_id),
  ra AS (SELECT salesperson_id, count(DISTINCT return_id) AS cnt, sum(quantity) AS units, sum(value) AS val, sum(cost) AS cost
         FROM r GROUP BY salesperson_id),
  x AS (
    SELECT COALESCE(sa.salesperson_id, ra.salesperson_id) AS uid, COALESCE(sa.tx, 0) AS tx, COALESCE(sa.units, 0) AS units,
           COALESCE(sa.gross, 0) AS gross, COALESCE(sa.disc, 0) AS disc, COALESCE(sa.net, 0) AS net, COALESCE(sa.cost, 0) AS cost,
           COALESCE(ra.cnt, 0) AS rcnt, COALESCE(ra.units, 0) AS runits, COALESCE(ra.val, 0) AS rval, COALESCE(ra.cost, 0) AS rcost
    FROM sa FULL JOIN ra ON ra.salesperson_id = sa.salesperson_id)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'user_id', x.uid, 'name', COALESCE(pr.full_name, '—'),
           'transactions', x.tx, 'units', x.units, 'gross_sales', round(x.gross, 2), 'discounts', round(x.disc, 2),
           'net_sales', round(x.net, 2), 'avg_basket', CASE WHEN x.tx > 0 THEN round(x.net / x.tx, 2) END,
           'returns_count', x.rcnt, 'returned_units', x.runits, 'returns_value', round(x.rval, 2),
           'net_sales_after_returns', round(x.net - x.rval, 2))
           || CASE WHEN a.is_manager THEN jsonb_build_object(
                'gross_profit', round((x.net - x.rval) - (x.cost - x.rcost), 2),
                'gross_margin_pct', CASE WHEN (x.net - x.rval) > 0 THEN round(((x.net - x.rval) - (x.cost - x.rcost)) / (x.net - x.rval) * 100, 2) END)
              ELSE '{}'::jsonb END
         ORDER BY x.net DESC, pr.full_name), '[]'::jsonb)
  INTO v_sp
  FROM x LEFT JOIN profiles pr ON pr.id = x.uid;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', y.sold_by, 'name', COALESCE(pr.full_name, '—'), 'transactions', y.tx,
                                               'net_sales', round(y.net, 2)) ORDER BY y.tx DESC, pr.full_name), '[]'::jsonb)
  INTO v_cashiers
  FROM (SELECT sold_by, count(DISTINCT sale_id) AS tx, sum(net) AS net
        FROM fn_report_sale_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, NULL, NULL,
                                  a.is_manager, a.actor, a.scope, a.my_branch)
        GROUP BY sold_by) y
  LEFT JOIN profiles pr ON pr.id = y.sold_by;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_date_from, 'to', p_date_to, 'timezone', w.tz),
    'scope', a.scope, 'financial', a.is_manager, 'salespeople', v_sp, 'cashiers', v_cashiers);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_staff(UUID, DATE, DATE, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_staff(UUID, DATE, DATE, UUID) TO authenticated;

-- 4.5 payments (manager+): tender by method vs money actually moved; drawer movements separately
CREATE OR REPLACE FUNCTION rpc_report_payments(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE w RECORD; v_methods JSONB; v_refunds JSONB; v_sales RECORD; v_drawer JSONB; v_split INTEGER;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('method', x.method, 'currency', x.currency, 'amount', round(x.amt, 2),
                                               'amount_base', round(x.base, 2), 'payments', x.n, 'sales', x.tx)
                            ORDER BY x.base DESC), '[]'::jsonb)
  INTO v_methods
  FROM (SELECT sp.method, sp.currency, sum(sp.amount) AS amt, sum(sp.amount_base) AS base, count(*) AS n, count(DISTINCT sp.sale_id) AS tx
        FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id
        WHERE s.business_id = p_business_id AND s.status = 'completed' AND s.occurred_at >= w.ts_from AND s.occurred_at < w.ts_to
          AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
        GROUP BY sp.method, sp.currency) x;
  SELECT count(*) AS tx, COALESCE(sum(s.total), 0) AS total, COALESCE(sum(s.credit_applied_base), 0) AS credit,
         COALESCE(sum(s.change_given_base), 0) AS change_given,
         COALESCE(sum((SELECT sum(sp.amount_base) FROM sale_payments sp WHERE sp.sale_id = s.id)), 0) AS tendered
  INTO v_sales
  FROM sales s
  WHERE s.business_id = p_business_id AND s.status = 'completed' AND s.occurred_at >= w.ts_from AND s.occurred_at < w.ts_to
    AND (p_branch_id IS NULL OR s.branch_id = p_branch_id);
  SELECT count(*) INTO v_split
  FROM sales s
  WHERE s.business_id = p_business_id AND s.status = 'completed' AND s.occurred_at >= w.ts_from AND s.occurred_at < w.ts_to
    AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    AND (SELECT count(*) FROM sale_payments sp WHERE sp.sale_id = s.id) > 1;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('method', x.method, 'amount_base', round(x.amt, 2), 'returns', x.n) ORDER BY x.amt DESC), '[]'::jsonb)
  INTO v_refunds
  FROM (SELECT r.refund_method AS method, sum(r.refund_amount_base) AS amt, count(*) AS n
        FROM returns r
        WHERE r.business_id = p_business_id AND r.refund_amount_base > 0 AND r.created_at >= w.ts_from AND r.created_at < w.ts_to
          AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
        GROUP BY r.refund_method) x;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('movement_type', x.movement_type, 'currency', x.currency, 'amount', round(x.amt, 2),
                                               'amount_base', round(x.base, 2), 'count', x.n)
                            ORDER BY x.movement_type, x.currency), '[]'::jsonb)
  INTO v_drawer
  FROM (SELECT cm.movement_type, cm.currency, sum(cm.amount) AS amt, sum(cm.amount_base) AS base, count(*) AS n
        FROM cash_movements cm JOIN register_sessions rs ON rs.id = cm.register_session_id
        WHERE cm.business_id = p_business_id AND cm.created_at >= w.ts_from AND cm.created_at < w.ts_to
          AND (p_branch_id IS NULL OR rs.branch_id = p_branch_id)
        GROUP BY cm.movement_type, cm.currency) x;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_date_from, 'to', p_date_to, 'timezone', w.tz),
    'financial', true,
    'sales', jsonb_build_object('transactions', v_sales.tx, 'net_sales', round(v_sales.total, 2),
                                'credit_applied', round(v_sales.credit, 2), 'tendered_base', round(v_sales.tendered, 2),
                                'change_given', round(v_sales.change_given, 2), 'split_payment_sales', v_split),
    'by_method', v_methods,
    'refunds', v_refunds,
    'refund_total', (SELECT round(COALESCE(sum(r.refund_amount_base), 0), 2) FROM returns r
                     WHERE r.business_id = p_business_id AND r.created_at >= w.ts_from AND r.created_at < w.ts_to
                       AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)),
    -- money in (tendered) − change handed back − money refunded: what actually moved, all methods, base currency
    'net_payment_movement', round(v_sales.tendered - v_sales.change_given
                                  - (SELECT COALESCE(sum(r.refund_amount_base), 0) FROM returns r
                                     WHERE r.business_id = p_business_id AND r.created_at >= w.ts_from AND r.created_at < w.ts_to
                                       AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)), 2),
    'drawer', v_drawer);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_payments(UUID, DATE, DATE, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_payments(UUID, DATE, DATE, UUID) TO authenticated;

-- 4.6 stock: every member (operational quantities); valuation only for manager+
CREATE OR REPLACE FUNCTION rpc_report_stock(
  p_business_id UUID, p_branch_id UUID DEFAULT NULL, p_low_threshold INTEGER DEFAULT 2)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; v_low INTEGER := GREATEST(COALESCE(p_low_threshold, 2), 0); v_tot JSONB; v_oos JSONB; v_lows JSONB; v_val JSONB;
BEGIN
  SELECT * INTO a FROM fn_report_access(p_business_id, false);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  WITH q AS (
    SELECT m.variant_id,
           sum(m.quantity) FILTER (WHERE m.bucket = 'sellable') AS sellable,
           sum(m.quantity) FILTER (WHERE m.bucket = 'damaged') AS damaged,
           sum(m.quantity) FILTER (WHERE m.bucket = 'quarantine') AS quarantine
    FROM inventory_movements m
    WHERE m.business_id = p_business_id AND (p_branch_id IS NULL OR m.branch_id = p_branch_id)
    GROUP BY m.variant_id),
  held AS (
    SELECT ri.variant_id, sum(ri.quantity) AS reserved
    FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id
    WHERE r.business_id = p_business_id AND r.status = 'active' AND r.expires_at > now()
      AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
    GROUP BY ri.variant_id),
  v AS (
    SELECT pv.id AS variant_id, pv.sku, p.name AS product,
           COALESCE(q.sellable, 0) AS sellable, COALESCE(q.damaged, 0) AS damaged, COALESCE(q.quarantine, 0) AS quarantine,
           COALESCE(h.reserved, 0) AS reserved, COALESCE(q.sellable, 0) - COALESCE(h.reserved, 0) AS available
    FROM product_variants pv JOIN products p ON p.id = pv.product_id
    LEFT JOIN q ON q.variant_id = pv.id LEFT JOIN held h ON h.variant_id = pv.id
    WHERE pv.business_id = p_business_id AND pv.status = 'active' AND p.status = 'active'),
  tot AS (
    SELECT jsonb_build_object('variants', count(*), 'sellable', COALESCE(sum(sellable), 0), 'reserved', COALESCE(sum(reserved), 0),
                              'available', COALESCE(sum(available), 0), 'damaged', COALESCE(sum(damaged), 0),
                              'quarantine', COALESCE(sum(quarantine), 0),
                              'out_of_stock', count(*) FILTER (WHERE available <= 0),
                              'low_stock', count(*) FILTER (WHERE available > 0 AND available <= v_low)) AS j FROM v),
  oos AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('variant_id', variant_id, 'sku', sku, 'product', product, 'sellable', sellable, 'reserved', reserved)
                              ORDER BY product, sku), '[]'::jsonb) AS j
    FROM (SELECT * FROM v WHERE available <= 0 ORDER BY product, sku LIMIT 100) z),
  low AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('variant_id', variant_id, 'sku', sku, 'product', product, 'sellable', sellable, 'reserved', reserved,
                                                 'available', available) ORDER BY available, product, sku), '[]'::jsonb) AS j
    FROM (SELECT * FROM v WHERE available > 0 AND available <= v_low ORDER BY available, product, sku LIMIT 100) z)
  SELECT tot.j, oos.j, low.j INTO v_tot, v_oos, v_lows FROM tot, oos, low;
  IF a.is_manager THEN
    SELECT jsonb_build_object('on_hand_qty', COALESCE(sum(on_hand_qty), 0), 'total_value_base', round(COALESCE(sum(total_value_base), 0), 2),
                              'variants_with_stock', count(*) FILTER (WHERE on_hand_qty > 0))
    INTO v_val FROM variant_cost_pools vcp
    WHERE vcp.business_id = p_business_id AND (p_branch_id IS NULL OR vcp.branch_id = p_branch_id);
  END IF;
  RETURN jsonb_build_object(
    'branch_id', p_branch_id, 'financial', a.is_manager, 'low_threshold', v_low,
    'totals', v_tot, 'out_of_stock', v_oos, 'low_stock', v_lows, 'valuation', v_val);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_stock(UUID, UUID, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_stock(UUID, UUID, INTEGER) TO authenticated;

-- 4.7 receiving / purchasing (manager+): POSTED documents by posted_at; reversals shown apart
CREATE OR REPLACE FUNCTION rpc_report_receiving(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE w RECORD; v_tot JSONB; v_sup JSONB; v_rev JSONB;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  WITH g AS (
    SELECT g.id, g.supplier_id,
           (SELECT COALESCE(sum(i.quantity), 0) FROM goods_receipt_items i WHERE i.goods_receipt_id = g.id) AS units,
           (SELECT COALESCE(sum(i.total_cost_base), 0) FROM goods_receipt_items i WHERE i.goods_receipt_id = g.id) AS purchase_base,
           COALESCE(g.posted_charges_base, 0) AS charges_base,
           COALESCE(g.posted_landed_total_base, 0) AS landed_base,
           (SELECT COALESCE(sum(e.amount_base), 0) FROM supplier_account_entries e
            WHERE e.business_id = p_business_id AND e.entry_type = 'liability'
              AND ((e.reference_type = 'goods_receipt' AND e.reference_id = g.id)
                OR (e.reference_type = 'goods_receipt_charge'
                    AND e.reference_id IN (SELECT c.id FROM goods_receipt_charges c WHERE c.goods_receipt_id = g.id)))) AS liability_base,
           EXISTS (SELECT 1 FROM goods_receipt_reversals rv WHERE rv.goods_receipt_id = g.id) AS reversed
    FROM goods_receipts g
    WHERE g.business_id = p_business_id AND g.status = 'posted' AND g.posted_at >= w.ts_from AND g.posted_at < w.ts_to
      AND (p_branch_id IS NULL OR g.branch_id = p_branch_id)),
  tot AS (
    SELECT jsonb_build_object('receipts', count(*), 'units', COALESCE(sum(units), 0),
                              'purchase_value_base', round(COALESCE(sum(purchase_base), 0), 2),
                              'charges_base', round(COALESCE(sum(charges_base), 0), 2),
                              'landed_total_base', round(COALESCE(sum(landed_base), 0), 2),
                              'liability_base', round(COALESCE(sum(liability_base), 0), 2),
                              'reversed_receipts', count(*) FILTER (WHERE reversed)) AS j FROM g),
  sup AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('supplier_id', x.supplier_id, 'supplier', s.name, 'receipts', x.n, 'units', x.units,
                                                 'purchase_value_base', round(x.purchase, 2), 'landed_total_base', round(x.landed, 2),
                                                 'liability_base', round(x.liability, 2))
                              ORDER BY x.landed DESC, s.name), '[]'::jsonb) AS j
    FROM (SELECT supplier_id, count(*) AS n, sum(units) AS units, sum(purchase_base) AS purchase, sum(landed_base) AS landed,
                 sum(liability_base) AS liability
          FROM g GROUP BY supplier_id ORDER BY sum(landed_base) DESC LIMIT 50) x
    JOIN suppliers s ON s.id = x.supplier_id),
  rev AS (
    SELECT jsonb_build_object('count', count(*), 'value_removed_base', round(COALESCE(sum(rv.value_removed_base), 0), 2)) AS j
    FROM goods_receipt_reversals rv JOIN goods_receipts gr ON gr.id = rv.goods_receipt_id
    WHERE rv.business_id = p_business_id AND rv.reversed_at >= w.ts_from AND rv.reversed_at < w.ts_to
      AND (p_branch_id IS NULL OR gr.branch_id = p_branch_id))
  SELECT tot.j, sup.j, rev.j INTO v_tot, v_sup, v_rev FROM tot, sup, rev;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_date_from, 'to', p_date_to, 'timezone', w.tz),
    'financial', true, 'totals', v_tot, 'reversals', v_rev, 'by_supplier', v_sup);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_receiving(UUID, DATE, DATE, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_receiving(UUID, DATE, DATE, UUID) TO authenticated;

-- 4.8 customers (selling roles, scoped): counts + a short top list; no PII beyond the name
CREATE OR REPLACE FUNCTION rpc_report_customers(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; w RECORD; v_tot JSONB; v_top JSONB;
BEGIN
  SELECT * INTO a FROM fn_report_access(p_business_id, true);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  WITH cs AS (
    SELECT sale_id, customer_id, max(occurred_at) AS occurred_at, sum(quantity) AS units, sum(net) AS net
    FROM fn_report_sale_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, NULL, NULL, a.is_manager, a.actor, a.scope, a.my_branch)
    GROUP BY sale_id, customer_id),
  rl AS (
    SELECT customer_id, sum(value) AS val
    FROM fn_report_return_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, NULL, NULL, a.is_manager, a.actor, a.scope, a.my_branch)
    WHERE customer_id IS NOT NULL GROUP BY customer_id),
  tot AS (
    SELECT jsonb_build_object(
             'sales', count(*), 'identified_sales', count(*) FILTER (WHERE customer_id IS NOT NULL),
             'walk_in_sales', count(*) FILTER (WHERE customer_id IS NULL),
             'customers_with_sale', count(DISTINCT customer_id),
             'repeat_customers', (SELECT count(*) FROM (SELECT customer_id FROM cs WHERE customer_id IS NOT NULL GROUP BY customer_id HAVING count(*) >= 2) z),
             'identified_net_sales', round(COALESCE(sum(net) FILTER (WHERE customer_id IS NOT NULL), 0), 2),
             'walk_in_net_sales', round(COALESCE(sum(net) FILTER (WHERE customer_id IS NULL), 0), 2),
             'new_customers', (SELECT count(*) FROM customers c WHERE c.business_id = p_business_id
                               AND c.created_at >= w.ts_from AND c.created_at < w.ts_to)) AS j
    FROM cs),
  top AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('customer_id', x.customer_id, 'name', c.full_name, 'sales', x.n, 'units', x.units,
                                                 'net_spend', round(x.net, 2), 'returns_value', round(COALESCE(rl.val, 0), 2),
                                                 'last_purchase_at', x.last_at)
                              ORDER BY x.net DESC, c.full_name), '[]'::jsonb) AS j
    FROM (SELECT customer_id, count(*) AS n, sum(units) AS units, sum(net) AS net, max(occurred_at) AS last_at
          FROM cs WHERE customer_id IS NOT NULL GROUP BY customer_id ORDER BY sum(net) DESC LIMIT 10) x
    JOIN customers c ON c.id = x.customer_id
    LEFT JOIN rl ON rl.customer_id = x.customer_id)
  SELECT tot.j, top.j INTO v_tot, v_top FROM tot, top;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_date_from, 'to', p_date_to, 'timezone', w.tz),
    'scope', a.scope, 'financial', a.is_manager, 'totals', v_tot, 'top', v_top);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_customers(UUID, DATE, DATE, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_customers(UUID, DATE, DATE, UUID) TO authenticated;

-- 4.9 returns / exchanges: counts, reasons, conditions, return rate by product and size
--     (rate = returned units in window / sold units in window; "meaningful" needs >= 10 sold)
CREATE OR REPLACE FUNCTION rpc_report_returns(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; w RECORD; v_tot JSONB; v_reasons JSONB; v_disp JSONB; v_types JSONB; v_prod JSONB; v_size JSONB;
BEGIN
  SELECT * INTO a FROM fn_report_access(p_business_id, true);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  WITH rl AS (
    SELECT * FROM fn_report_return_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, NULL, NULL, a.is_manager, a.actor, a.scope, a.my_branch)),
  sl AS (
    SELECT variant_id, product_id, quantity
    FROM fn_report_sale_lines(p_business_id, w.ts_from, w.ts_to, p_branch_id, NULL, NULL, NULL, a.is_manager, a.actor, a.scope, a.my_branch)),
  tot AS (
    SELECT jsonb_build_object(
             'returns', count(DISTINCT return_id),
             'exchanges', count(DISTINCT return_id) FILTER (WHERE return_type = 'exchange'),
             'refunds', count(DISTINCT return_id) FILTER (WHERE return_type = 'refund'),
             'store_credits', count(DISTINCT return_id) FILTER (WHERE return_type = 'store_credit'),
             'returned_units', COALESCE(sum(quantity), 0), 'returns_value', round(COALESCE(sum(value), 0), 2),
             'refund_amount', (SELECT round(COALESCE(sum(r.refund_amount_base), 0), 2) FROM returns r
                               WHERE r.id IN (SELECT DISTINCT return_id FROM rl)))
           || CASE WHEN a.is_manager THEN jsonb_build_object('returned_cogs', round(COALESCE(sum(cost), 0), 2)) ELSE '{}'::jsonb END AS j
    FROM rl),
  reasons AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('code', x.code, 'label', COALESCE(rr.label, x.code, 'Belirtilmedi'), 'returns', x.n,
                                                 'units', x.units, 'value', round(x.val, 2)) ORDER BY x.units DESC, x.code), '[]'::jsonb) AS j
    FROM (SELECT reason_code AS code, count(DISTINCT return_id) AS n, sum(quantity) AS units, sum(value) AS val FROM rl GROUP BY reason_code) x
    LEFT JOIN LATERAL (SELECT label FROM return_reasons rr WHERE rr.code = x.code AND (rr.business_id = p_business_id OR rr.business_id IS NULL)
                       ORDER BY rr.business_id NULLS LAST LIMIT 1) rr ON true),
  disp AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('disposition', x.disposition, 'units', x.units, 'value', round(x.val, 2)) ORDER BY x.units DESC), '[]'::jsonb) AS j
    FROM (SELECT disposition, sum(quantity) AS units, sum(value) AS val FROM rl GROUP BY disposition) x),
  types AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('return_type', x.return_type, 'returns', x.n, 'units', x.units, 'value', round(x.val, 2)) ORDER BY x.n DESC), '[]'::jsonb) AS j
    FROM (SELECT return_type, count(DISTINCT return_id) AS n, sum(quantity) AS units, sum(value) AS val FROM rl GROUP BY return_type) x),
  prod AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id', z.id, 'product', z.name, 'sold_units', z.sold, 'returned_units', z.units, 'returns', z.n,
                                                 'rate_pct', CASE WHEN z.sold > 0 THEN round(z.units::numeric / z.sold * 100, 1) END,
                                                 'meaningful', z.sold >= 10) ORDER BY z.units DESC, z.name), '[]'::jsonb) AS j
    FROM (SELECT p.id, p.name, ret.units, ret.n, COALESCE(sold.units, 0) AS sold
          FROM (SELECT product_id, sum(quantity) AS units, count(DISTINCT return_id) AS n FROM rl GROUP BY product_id) ret
          JOIN products p ON p.id = ret.product_id
          LEFT JOIN (SELECT product_id, sum(quantity) AS units FROM sl GROUP BY product_id) sold ON sold.product_id = ret.product_id
          ORDER BY ret.units DESC, p.name LIMIT 50) z),
  sz AS (
    SELECT vov.variant_id, ov.value FROM variant_option_values vov
    JOIN product_options po ON po.id = vov.product_option_id AND po.kind = 'size'
    JOIN option_values ov ON ov.id = vov.option_value_id
    WHERE po.business_id = p_business_id),
  size AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('size', z.value, 'sold_units', z.sold, 'returned_units', z.units, 'returns', z.n,
                                                 'rate_pct', CASE WHEN z.sold > 0 THEN round(z.units::numeric / z.sold * 100, 1) END,
                                                 'meaningful', z.sold >= 10) ORDER BY z.units DESC, z.value), '[]'::jsonb) AS j
    FROM (SELECT ret.value, ret.units, ret.n, COALESCE(sold.units, 0) AS sold
          FROM (SELECT sz.value, sum(r.quantity) AS units, count(DISTINCT r.return_id) AS n FROM rl r JOIN sz ON sz.variant_id = r.variant_id GROUP BY sz.value) ret
          LEFT JOIN (SELECT sz.value, sum(l.quantity) AS units FROM sl l JOIN sz ON sz.variant_id = l.variant_id GROUP BY sz.value) sold ON sold.value = ret.value) z)
  SELECT tot.j, reasons.j, disp.j, types.j, prod.j, size.j INTO v_tot, v_reasons, v_disp, v_types, v_prod, v_size
  FROM tot, reasons, disp, types, prod, size;
  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_date_from, 'to', p_date_to, 'timezone', w.tz),
    'scope', a.scope, 'financial', a.is_manager,
    'totals', v_tot, 'by_reason', v_reasons, 'by_disposition', v_disp, 'by_type', v_types,
    'rate_by_product', v_prod, 'rate_by_size', v_size);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_report_returns(UUID, DATE, DATE, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_report_returns(UUID, DATE, DATE, UUID) TO authenticated;

-- ------------------------------------------------------------ 5. indexes (justified by EXPLAIN on synthetic volume, see docs/10 §21)
CREATE INDEX IF NOT EXISTS idx_returns_business_created ON returns (business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_return_items_return ON return_items (return_id);
CREATE INDEX IF NOT EXISTS idx_gr_business_posted ON goods_receipts (business_id, posted_at DESC) WHERE status = 'posted';
CREATE INDEX IF NOT EXISTS idx_cash_mov_business_created ON cash_movements (business_id, created_at DESC);

-- ============================================================
-- END phase 10B
-- ============================================================
