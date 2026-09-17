-- ============================================================
-- Phase 11A — Fashion intelligence (deterministic, read-only)
--
-- Every signal is a rule over the operational records: the inventory ledger (supply,
-- current buckets, first/last arrival), completed sales and returns (net units, velocity,
-- return rate), reservations (demand held on stock), option values (size / colour). No
-- model, no prediction, no score without its inputs: each row carries the numbers that
-- put it there and a sentence built from them.
--
-- Definitions (docs/10 §22 has the prose; thresholds are parameters with documented
-- defaults):
--   supplied_units   = Σ units that entered the SELLABLE bucket by goods receipt, transfer
--                      receipt, positive adjustment or state change (opening stock included;
--                      customer returns and sale voids are NOT supply)
--   net_units_sold   = units sold (completed sales) − units returned (any disposition)
--   sell_through     = net_units_sold / supplied_units        (all-time cohort per variant;
--                      NULL when nothing was supplied — "cohort" = everything ever supplied,
--                      there is no lot tracking, so a restock lowers the ratio)
--   first_arrival    = first SELLABLE inbound movement of the variant (never product.created_at)
--   stock_age_days   = today − first_arrival, for variants that still hold sellable units
--                      (a restock does not reset the age — no lot tracking; documented)
--   active_days      = LEAST(window days, days since first arrival + 1)
--   velocity         = units sold in the window / active_days   (units per selling day)
--   days_of_cover    = available / velocity (NULL when velocity = 0)
--   available        = sellable − active, unexpired holds (Rev 3 rule)
--   return_rate      = returned units / sold units, both in the window; shown as a
--                      percentage only when sold units ≥ p_min_sample (default 10)
--   broken size run  = a product whose sized variants have some sizes available and at
--                      least one size that once had supply and now has none available
--   fast mover       = product with ≥ 3 units sold in the window and ≥ 7 active days,
--                      ranked by velocity (never by lifetime units alone)
--   slow mover       = variant aged ≥ p_slow_age_days with ≥ p_slow_min_qty available,
--                      ≤ 1 unit sold in the window and no sale for ≥ p_slow_no_sale_days
--                      (or never) — a freshly received variant can never be "slow"
--   replenishment    = variant with ≥ p_replenish_min_sold sold in the window and
--                      available ≤ p_min_stock, or active holds ≥ available
--   excess           = variant with available ≥ p_excess_min_qty, age ≥ p_slow_age_days and
--                      days_of_cover ≥ p_excess_cover_days (or no velocity at all)
-- Access mirrors Phase 10B: owner/manager everything (incl. valuation); sales_staff the
-- sales-side signals over the sales they may see (sales_visibility_scope), no money;
-- stock_staff stock-side signals only (no sales, returns, reservations or value).
-- ============================================================

-- ------------------------------------------------------------ 1. per-variant facts (inlined into the RPCs)
CREATE OR REPLACE FUNCTION fn_intel_facts(
  p_business_id UUID, p_branch_id UUID, p_ts_from TIMESTAMPTZ, p_ts_to TIMESTAMPTZ,
  p_is_manager BOOLEAN, p_sales BOOLEAN, p_holds BOOLEAN, p_actor UUID, p_scope TEXT, p_my_branch UUID)
RETURNS TABLE (
  variant_id UUID, product_id UUID, product_name TEXT, sku TEXT, category_id UUID, category_name TEXT,
  size_value TEXT, size_order INTEGER, color_value TEXT,
  supplied INTEGER, first_arrival TIMESTAMPTZ, last_arrival TIMESTAMPTZ,
  sellable INTEGER, damaged INTEGER, quarantine INTEGER, reserved INTEGER, available INTEGER,
  sold_all INTEGER, returned_all INTEGER, sold_win INTEGER, returned_win INTEGER, last_sale_at TIMESTAMPTZ, sales_win INTEGER,
  holds_active INTEGER, holds_converted_win INTEGER, holds_cancelled_win INTEGER, holds_expired_win INTEGER,
  pool_qty INTEGER, pool_value NUMERIC)
LANGUAGE sql STABLE AS $$
  WITH v AS (
    SELECT pv.id AS variant_id, pv.product_id, p.name AS product_name, pv.sku, p.category_id, c.name AS category_name,
           sz.value AS size_value, sz.sort_order AS size_order, col.value AS color_value
    FROM product_variants pv
    JOIN products p ON p.id = pv.product_id
    LEFT JOIN categories c ON c.id = p.category_id
    LEFT JOIN LATERAL (SELECT ov.value, ov.sort_order FROM variant_option_values vov
                       JOIN product_options po ON po.id = vov.product_option_id AND po.kind = 'size'
                       JOIN option_values ov ON ov.id = vov.option_value_id
                       WHERE vov.variant_id = pv.id LIMIT 1) sz ON true
    LEFT JOIN LATERAL (SELECT ov.value FROM variant_option_values vov
                       JOIN product_options po ON po.id = vov.product_option_id AND po.kind = 'color'
                       JOIN option_values ov ON ov.id = vov.option_value_id
                       WHERE vov.variant_id = pv.id LIMIT 1) col ON true
    WHERE pv.business_id = p_business_id AND pv.status = 'active' AND p.status = 'active'),
  led AS (
    SELECT m.variant_id,
           COALESCE(sum(m.quantity) FILTER (WHERE m.bucket = 'sellable' AND m.quantity > 0
                     AND m.reason IN ('goods_receipt','transfer_receive','adjustment','state_change')), 0)::integer AS supplied,
           min(m.occurred_at) FILTER (WHERE m.bucket = 'sellable' AND m.quantity > 0
                     AND m.reason IN ('goods_receipt','transfer_receive','adjustment','state_change')) AS first_arrival,
           max(m.occurred_at) FILTER (WHERE m.bucket = 'sellable' AND m.quantity > 0
                     AND m.reason IN ('goods_receipt','transfer_receive','adjustment','state_change')) AS last_arrival,
           COALESCE(sum(m.quantity) FILTER (WHERE m.bucket = 'sellable'), 0)::integer AS sellable,
           COALESCE(sum(m.quantity) FILTER (WHERE m.bucket = 'damaged'), 0)::integer AS damaged,
           COALESCE(sum(m.quantity) FILTER (WHERE m.bucket = 'quarantine'), 0)::integer AS quarantine
    FROM inventory_movements m
    WHERE m.business_id = p_business_id AND (p_branch_id IS NULL OR m.branch_id = p_branch_id)
    GROUP BY m.variant_id),
  held AS (
    SELECT ri.variant_id, COALESCE(sum(ri.quantity), 0)::integer AS reserved
    FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id
    WHERE p_holds AND r.business_id = p_business_id AND r.status = 'active' AND r.expires_at > now()
      AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
    GROUP BY ri.variant_id),
  hs AS (
    SELECT ri.variant_id,
           count(DISTINCT r.id) FILTER (WHERE r.status = 'active' AND r.expires_at > now())::integer AS holds_active,
           count(DISTINCT r.id) FILTER (WHERE r.status = 'converted' AND r.fulfilled_at >= p_ts_from AND r.fulfilled_at < p_ts_to)::integer AS holds_converted_win,
           count(DISTINCT r.id) FILTER (WHERE r.status = 'cancelled' AND r.cancelled_at >= p_ts_from AND r.cancelled_at < p_ts_to)::integer AS holds_cancelled_win,
           count(DISTINCT r.id) FILTER (WHERE r.status = 'expired' AND r.expires_at >= p_ts_from AND r.expires_at < p_ts_to)::integer AS holds_expired_win
    FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id
    WHERE p_holds AND r.business_id = p_business_id AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
    GROUP BY ri.variant_id),
  sold AS (
    SELECT si.variant_id,
           COALESCE(sum(si.quantity), 0)::integer AS sold_all,
           COALESCE(sum(si.quantity) FILTER (WHERE s.occurred_at >= p_ts_from AND s.occurred_at < p_ts_to), 0)::integer AS sold_win,
           count(DISTINCT s.id) FILTER (WHERE s.occurred_at >= p_ts_from AND s.occurred_at < p_ts_to)::integer AS sales_win,
           max(s.occurred_at) AS last_sale_at
    FROM sale_items si JOIN sales s ON s.id = si.sale_id
    WHERE p_sales AND s.business_id = p_business_id AND s.status = 'completed'
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
      AND (p_is_manager OR s.sold_by = p_actor OR s.salesperson_id = p_actor OR p_scope = 'business'
           OR (p_scope = 'branch' AND p_my_branch IS NOT NULL AND s.branch_id = p_my_branch))
    GROUP BY si.variant_id),
  ret AS (
    SELECT ri.variant_id,
           COALESCE(sum(ri.quantity), 0)::integer AS returned_all,
           COALESCE(sum(ri.quantity) FILTER (WHERE r.created_at >= p_ts_from AND r.created_at < p_ts_to), 0)::integer AS returned_win
    FROM return_items ri JOIN returns r ON r.id = ri.return_id JOIN sales s ON s.id = r.original_sale_id
    WHERE p_sales AND r.business_id = p_business_id AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
      AND (p_is_manager OR r.processed_by = p_actor OR s.sold_by = p_actor OR s.salesperson_id = p_actor OR p_scope = 'business'
           OR (p_scope = 'branch' AND p_my_branch IS NOT NULL AND s.branch_id = p_my_branch))
    GROUP BY ri.variant_id),
  pool AS (
    SELECT vcp.variant_id, sum(vcp.on_hand_qty)::integer AS pool_qty, sum(vcp.total_value_base) AS pool_value
    FROM variant_cost_pools vcp
    WHERE p_is_manager AND vcp.business_id = p_business_id AND (p_branch_id IS NULL OR vcp.branch_id = p_branch_id)
    GROUP BY vcp.variant_id)
  SELECT v.variant_id, v.product_id, v.product_name, v.sku, v.category_id, v.category_name,
         v.size_value, v.size_order, v.color_value,
         COALESCE(led.supplied, 0), led.first_arrival, led.last_arrival,
         COALESCE(led.sellable, 0), COALESCE(led.damaged, 0), COALESCE(led.quarantine, 0),
         COALESCE(held.reserved, 0), COALESCE(led.sellable, 0) - COALESCE(held.reserved, 0),
         COALESCE(sold.sold_all, 0), COALESCE(ret.returned_all, 0), COALESCE(sold.sold_win, 0), COALESCE(ret.returned_win, 0),
         sold.last_sale_at, COALESCE(sold.sales_win, 0),
         COALESCE(hs.holds_active, 0), COALESCE(hs.holds_converted_win, 0), COALESCE(hs.holds_cancelled_win, 0), COALESCE(hs.holds_expired_win, 0),
         COALESCE(pool.pool_qty, 0), pool.pool_value
  FROM v
  LEFT JOIN led ON led.variant_id = v.variant_id
  LEFT JOIN held ON held.variant_id = v.variant_id
  LEFT JOIN hs ON hs.variant_id = v.variant_id
  LEFT JOIN sold ON sold.variant_id = v.variant_id
  LEFT JOIN ret ON ret.variant_id = v.variant_id
  LEFT JOIN pool ON pool.variant_id = v.variant_id;
$$;
REVOKE EXECUTE ON FUNCTION fn_intel_facts(UUID,UUID,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,BOOLEAN,BOOLEAN,UUID,TEXT,UUID) FROM PUBLIC, anon, authenticated;

-- Who may see what: manager+ all; sales_staff sales-side (scoped) without money; stock_staff stock-side only.
CREATE OR REPLACE FUNCTION fn_intel_access(p_business_id UUID,
  OUT member_role user_role, OUT is_manager BOOLEAN, OUT sales BOOLEAN, OUT holds BOOLEAN,
  OUT actor UUID, OUT scope TEXT, OUT my_branch UUID)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  member_role := fn_require_member(p_business_id);
  actor := fn_actor();
  is_manager := member_role IN ('owner','manager');
  sales := member_role <> 'stock_staff';
  holds := member_role <> 'stock_staff';
  scope := CASE WHEN is_manager THEN 'business' ELSE fn_sales_visibility_scope(p_business_id) END;
  my_branch := fn_my_branch(p_business_id);
END $$;
REVOKE EXECUTE ON FUNCTION fn_intel_access(UUID) FROM PUBLIC, anon, authenticated;

-- Window: the last p_days local days ending today (tenant timezone), bounded 7..365.
CREATE OR REPLACE FUNCTION fn_intel_window(p_business_id UUID, p_days INTEGER,
  OUT ts_from TIMESTAMPTZ, OUT ts_to TIMESTAMPTZ, OUT days INTEGER, OUT tz TEXT, OUT today DATE)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  days := LEAST(GREATEST(COALESCE(p_days, 30), 7), 365);
  tz := fn_business_timezone(p_business_id);
  today := (now() AT TIME ZONE tz)::date;
  ts_to := ((today + 1)::timestamp) AT TIME ZONE tz;
  ts_from := ((today - days + 1)::timestamp) AT TIME ZONE tz;
END $$;
REVOKE EXECUTE ON FUNCTION fn_intel_window(UUID, INTEGER) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ 2. intelligence home: one round trip
CREATE OR REPLACE FUNCTION rpc_intel_home(
  p_business_id UUID, p_branch_id UUID DEFAULT NULL, p_days INTEGER DEFAULT 30,
  p_min_sample INTEGER DEFAULT 10, p_min_stock INTEGER DEFAULT 2,
  p_slow_age_days INTEGER DEFAULT 60, p_slow_no_sale_days INTEGER DEFAULT 30, p_slow_min_qty INTEGER DEFAULT 3,
  p_replenish_min_sold INTEGER DEFAULT 3, p_excess_min_qty INTEGER DEFAULT 10, p_excess_cover_days INTEGER DEFAULT 120)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; w RECORD; v_sum JSONB; v_fast JSONB; v_slow JSONB; v_broken JSONB; v_oos JSONB; v_rep JSONB; v_exc JSONB;
        v_age JSONB; v_ret JSONB; v_hold JSONB;
        v_min_sample INTEGER := GREATEST(COALESCE(p_min_sample, 10), 1);
BEGIN
  SELECT * INTO a FROM fn_intel_access(p_business_id);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_intel_window(p_business_id, p_days);
  WITH f0 AS (
    SELECT * FROM fn_intel_facts(p_business_id, p_branch_id, w.ts_from, w.ts_to, a.is_manager, a.sales, a.holds, a.actor, a.scope, a.my_branch)),
  f AS (
    SELECT f0.*,
           CASE WHEN first_arrival IS NULL THEN NULL ELSE (w.today - (first_arrival AT TIME ZONE w.tz)::date) END AS age_days,
           CASE WHEN last_sale_at IS NULL THEN NULL ELSE (w.today - (last_sale_at AT TIME ZONE w.tz)::date) END AS days_since_sale,
           CASE WHEN first_arrival IS NULL THEN w.days ELSE LEAST(w.days, (w.today - (first_arrival AT TIME ZONE w.tz)::date) + 1) END AS active_days,
           CASE WHEN pool_qty > 0 THEN round(pool_value / pool_qty * GREATEST(sellable, 0), 2) END AS sellable_value
    FROM f0),
  -- product-level velocity for fast movers (units per selling day over the window)
  prod AS (
    SELECT product_id, max(product_name) AS product_name, max(category_name) AS category_name,
           sum(sold_win) AS sold_win, sum(returned_win) AS returned_win, sum(available) AS available, sum(sellable) AS sellable,
           sum(supplied) AS supplied, sum(sold_all) AS sold_all, sum(returned_all) AS returned_all,
           min(first_arrival) AS first_arrival, max(last_sale_at) AS last_sale_at, sum(holds_active) AS holds_active,
           count(*) AS variants, count(*) FILTER (WHERE available <= 0) AS variants_out,
           max(active_days) AS active_days
    FROM f GROUP BY product_id),
  summary AS (
    SELECT jsonb_build_object(
      'variants', count(*), 'products', count(DISTINCT product_id),
      'with_stock', count(*) FILTER (WHERE sellable > 0), 'out_of_stock', count(*) FILTER (WHERE available <= 0 AND supplied > 0),
      'never_stocked', count(*) FILTER (WHERE supplied = 0),
      'sold_win', COALESCE(sum(sold_win), 0), 'returned_win', COALESCE(sum(returned_win), 0),
      'sales_win', COALESCE(sum(sales_win), 0), 'holds_active', COALESCE(sum(holds_active), 0),
      'enough_data', COALESCE(sum(sold_win), 0) >= v_min_sample) AS j FROM f),
  fast AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'product_id', product_id, 'product', product_name, 'category', category_name,
             'sold_win', sold_win, 'returned_win', returned_win, 'active_days', active_days,
             'velocity', round(sold_win::numeric / GREATEST(active_days, 1), 2), 'available', available, 'variants_out', variants_out, 'variants', variants,
             'days_of_cover', CASE WHEN sold_win > 0 THEN round(available::numeric / (sold_win::numeric / GREATEST(active_days, 1)), 0) END,
             'sell_through_pct', CASE WHEN supplied > 0 THEN round((sold_all - returned_all)::numeric / supplied * 100, 1) END)
             ORDER BY sold_win::numeric / GREATEST(active_days, 1) DESC, sold_win DESC, product_name), '[]'::jsonb) AS j
    FROM (SELECT * FROM prod WHERE a.sales AND sold_win >= 3 AND active_days >= 7
          ORDER BY sold_win::numeric / GREATEST(active_days, 1) DESC, sold_win DESC LIMIT 10) x),
  slow AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'variant_id', variant_id, 'product_id', product_id, 'product', product_name, 'sku', sku, 'size', size_value, 'color', color_value,
             'available', available, 'age_days', age_days, 'days_since_sale', days_since_sale, 'sold_win', sold_win,
             'sellable_value', sellable_value,
             'why', format('%s gündür stokta, %s adet müsait, son %s günde %s adet satıldı%s', age_days, available, w.days, sold_win,
                           CASE WHEN days_since_sale IS NULL THEN ', hiç satılmadı' ELSE format(', son satış %s gün önce', days_since_sale) END))
             ORDER BY age_days DESC, available DESC), '[]'::jsonb) AS j
    FROM (SELECT * FROM f WHERE a.sales AND age_days >= GREATEST(COALESCE(p_slow_age_days, 60), 1) AND available >= GREATEST(COALESCE(p_slow_min_qty, 3), 1)
                 AND sold_win <= 1 AND (days_since_sale IS NULL OR days_since_sale >= GREATEST(COALESCE(p_slow_no_sale_days, 30), 1))
          ORDER BY age_days DESC, available DESC LIMIT 20) x),
  -- broken size runs: products with sized variants, some sizes available, some once-supplied sizes gone
  sized AS (
    SELECT product_id, max(product_name) AS product_name,
           string_agg(size_value, ' ' ORDER BY size_order, size_value) FILTER (WHERE available > 0) AS sizes_available,
           string_agg(size_value, ' ' ORDER BY size_order, size_value) FILTER (WHERE available <= 0 AND supplied > 0) AS sizes_missing,
           string_agg(size_value, ' ' ORDER BY size_order, size_value) FILTER (WHERE supplied = 0) AS sizes_never,
           count(*) FILTER (WHERE available > 0) AS n_avail, count(*) FILTER (WHERE available <= 0 AND supplied > 0) AS n_missing,
           sum(sold_win) AS sold_win, sum(sold_win) FILTER (WHERE available <= 0 AND supplied > 0) AS sold_win_missing,
           sum(holds_active) AS holds_active, sum(available) AS available
    FROM f WHERE size_value IS NOT NULL GROUP BY product_id),
  broken AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'product_id', product_id, 'product', product_name, 'sizes_available', sizes_available, 'sizes_missing', sizes_missing,
             'sizes_never_stocked', sizes_never, 'sold_win', sold_win, 'sold_win_missing_sizes', sold_win_missing, 'holds_active', holds_active, 'available', available)
             ORDER BY sold_win_missing DESC NULLS LAST, sold_win DESC, product_name), '[]'::jsonb) AS j
    FROM (SELECT * FROM sized WHERE n_avail > 0 AND n_missing > 0 ORDER BY sold_win_missing DESC NULLS LAST, sold_win DESC LIMIT 20) x),
  oos AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'variant_id', variant_id, 'product_id', product_id, 'product', product_name, 'sku', sku, 'size', size_value, 'color', color_value,
             'sold_win', sold_win, 'holds_active', holds_active, 'available', available, 'last_sale_at', last_sale_at)
             ORDER BY sold_win DESC, holds_active DESC, product_name, sku), '[]'::jsonb) AS j
    FROM (SELECT * FROM f WHERE available <= 0 AND supplied > 0 AND (sold_win > 0 OR holds_active > 0 OR NOT a.sales)
          ORDER BY sold_win DESC, holds_active DESC, product_name, sku LIMIT 30) x),
  rep AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'variant_id', variant_id, 'product_id', product_id, 'product', product_name, 'sku', sku, 'size', size_value, 'color', color_value,
             'sold_win', sold_win, 'available', available, 'holds_active', holds_active,
             'velocity', round(sold_win::numeric / GREATEST(active_days, 1), 2),
             'days_of_cover', CASE WHEN sold_win > 0 THEN round(available::numeric / (sold_win::numeric / GREATEST(active_days, 1)), 0) END,
             'why', CASE WHEN holds_active > 0 AND holds_active >= available
                         THEN format('Son %s günde %s adet satıldı, %s adet müsait, %s aktif rezervasyon bekliyor.', w.days, sold_win, available, holds_active)
                         ELSE format('Son %s günde %s adet satıldı, %s adet müsait kaldı.', w.days, sold_win, available) END)
             ORDER BY sold_win DESC, available, product_name, sku), '[]'::jsonb) AS j
    FROM (SELECT * FROM f WHERE a.sales
                 AND ((sold_win >= GREATEST(COALESCE(p_replenish_min_sold, 3), 1) AND available <= GREATEST(COALESCE(p_min_stock, 2), 0))
                      OR (holds_active > 0 AND holds_active >= available))
          ORDER BY sold_win DESC, available LIMIT 20) x),
  exc AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'variant_id', variant_id, 'product_id', product_id, 'product', product_name, 'sku', sku, 'size', size_value, 'color', color_value,
             'available', available, 'age_days', age_days, 'sold_win', sold_win, 'sellable_value', sellable_value,
             'days_of_cover', CASE WHEN sold_win > 0 THEN round(available::numeric / (sold_win::numeric / GREATEST(active_days, 1)), 0) END,
             'why', CASE WHEN sold_win = 0 THEN format('%s adet müsait, %s gündür stokta, son %s günde hiç satılmadı.', available, age_days, w.days)
                         ELSE format('%s adet müsait, %s gündür stokta; bu hızla %s günlük stok.', available, age_days,
                                     round(available::numeric / (sold_win::numeric / GREATEST(active_days, 1)), 0)) END)
             ORDER BY available DESC, age_days DESC), '[]'::jsonb) AS j
    FROM (SELECT * FROM f WHERE a.sales AND available >= GREATEST(COALESCE(p_excess_min_qty, 10), 1) AND age_days >= GREATEST(COALESCE(p_slow_age_days, 60), 1)
                 AND (sold_win = 0 OR available::numeric / (sold_win::numeric / GREATEST(active_days, 1)) >= GREATEST(COALESCE(p_excess_cover_days, 120), 1))
          ORDER BY available DESC, age_days DESC LIMIT 20) x),
  aging AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('bucket', b.label, 'order', b.ord,
             'units', COALESCE(x.units, 0), 'variants', COALESCE(x.variants, 0),
             'value', CASE WHEN a.is_manager THEN COALESCE(x.value, 0) END,
             'no_sale_units', COALESCE(x.no_sale_units, 0)) ORDER BY b.ord), '[]'::jsonb) AS j
    FROM (VALUES ('0–30', 1, 0, 30), ('31–60', 2, 31, 60), ('61–90', 3, 61, 90), ('91–120', 4, 91, 120), ('120+', 5, 121, 100000)) b(label, ord, lo, hi)
    LEFT JOIN (SELECT CASE WHEN age_days <= 30 THEN 1 WHEN age_days <= 60 THEN 2 WHEN age_days <= 90 THEN 3 WHEN age_days <= 120 THEN 4 ELSE 5 END AS ord,
                      sum(sellable) AS units, count(*) AS variants, sum(sellable_value) AS value,
                      sum(sellable) FILTER (WHERE days_since_sale IS NULL OR days_since_sale > 30) AS no_sale_units
               FROM f WHERE sellable > 0 AND age_days IS NOT NULL GROUP BY 1) x ON x.ord = b.ord),
  rets AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'kind', kind, 'key', key, 'label', label, 'sold_win', sold_win, 'returned_win', returned_win,
             'rate_pct', CASE WHEN sold_win > 0 THEN round(returned_win::numeric / sold_win * 100, 1) END,
             'meaningful', sold_win >= v_min_sample) ORDER BY meaningful DESC, returned_win::numeric / GREATEST(sold_win, 1) DESC, returned_win DESC), '[]'::jsonb) AS j
    FROM (
      SELECT * FROM (
        SELECT 'product' AS kind, product_id::text AS key, max(product_name) AS label, sum(sold_win) AS sold_win, sum(returned_win) AS returned_win,
               sum(sold_win) >= v_min_sample AS meaningful FROM f WHERE a.sales GROUP BY product_id HAVING sum(returned_win) > 0
        UNION ALL
        SELECT 'size', product_id::text || ':' || size_value, max(product_name) || ' · ' || size_value, sum(sold_win), sum(returned_win),
               sum(sold_win) >= v_min_sample FROM f WHERE a.sales AND size_value IS NOT NULL GROUP BY product_id, size_value HAVING sum(returned_win) > 0
        UNION ALL
        SELECT 'variant', variant_id::text, product_name || ' · ' || sku, sold_win, returned_win, sold_win >= v_min_sample
        FROM f WHERE a.sales AND returned_win > 0) y
      ORDER BY meaningful DESC, returned_win::numeric / GREATEST(sold_win, 1) DESC, returned_win DESC LIMIT 20) x),
  holds AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'variant_id', variant_id, 'product_id', product_id, 'product', product_name, 'sku', sku, 'size', size_value, 'color', color_value,
             'holds_active', holds_active, 'reserved', reserved, 'available', available, 'sellable', sellable,
             'converted_win', holds_converted_win, 'cancelled_win', holds_cancelled_win, 'expired_win', holds_expired_win,
             'low_stock', available <= GREATEST(COALESCE(p_min_stock, 2), 0))
             ORDER BY holds_active DESC, available, product_name, sku), '[]'::jsonb) AS j
    FROM (SELECT * FROM f WHERE a.holds AND (holds_active > 0 OR holds_converted_win > 0 OR holds_cancelled_win > 0 OR holds_expired_win > 0)
          ORDER BY holds_active DESC, available LIMIT 20) x)
  SELECT summary.j, fast.j, slow.j, broken.j, oos.j, rep.j, exc.j, aging.j, rets.j, holds.j
  INTO v_sum, v_fast, v_slow, v_broken, v_oos, v_rep, v_exc, v_age, v_ret, v_hold
  FROM summary, fast, slow, broken, oos, rep, exc, aging, rets, holds;
  RETURN jsonb_build_object(
    'window', jsonb_build_object('days', w.days, 'from', w.today - w.days + 1, 'to', w.today, 'timezone', w.tz),
    'thresholds', jsonb_build_object('min_sample', v_min_sample, 'min_stock', GREATEST(COALESCE(p_min_stock, 2), 0),
                                     'slow_age_days', GREATEST(COALESCE(p_slow_age_days, 60), 1), 'slow_no_sale_days', GREATEST(COALESCE(p_slow_no_sale_days, 30), 1),
                                     'slow_min_qty', GREATEST(COALESCE(p_slow_min_qty, 3), 1), 'replenish_min_sold', GREATEST(COALESCE(p_replenish_min_sold, 3), 1),
                                     'excess_min_qty', GREATEST(COALESCE(p_excess_min_qty, 10), 1), 'excess_cover_days', GREATEST(COALESCE(p_excess_cover_days, 120), 1)),
    'role', a.member_role, 'financial', a.is_manager, 'sales', a.sales, 'scope', a.scope,
    'summary', v_sum,
    'fast_movers', CASE WHEN a.sales THEN v_fast END, 'slow_movers', CASE WHEN a.sales THEN v_slow END,
    'broken_size_runs', v_broken, 'out_of_stock', v_oos,
    'replenishment', CASE WHEN a.sales THEN v_rep END, 'excess', CASE WHEN a.sales THEN v_exc END,
    'aging', v_age, 'return_signals', CASE WHEN a.sales THEN v_ret END, 'reservation_demand', CASE WHEN a.holds THEN v_hold END);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_intel_home(UUID,UUID,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_intel_home(UUID,UUID,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER,INTEGER) TO authenticated;

-- ------------------------------------------------------------ 3. size / colour intelligence (product or category)
CREATE OR REPLACE FUNCTION rpc_intel_dimensions(
  p_business_id UUID, p_branch_id UUID DEFAULT NULL, p_days INTEGER DEFAULT 30,
  p_category_id UUID DEFAULT NULL, p_product_id UUID DEFAULT NULL, p_min_sample INTEGER DEFAULT 10)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a RECORD; w RECORD; v_size JSONB; v_color JSONB; v_sold BIGINT; v_sized BIGINT; v_colored BIGINT; v_min_sample INTEGER := GREATEST(COALESCE(p_min_sample, 10), 1);
BEGIN
  SELECT * INTO a FROM fn_intel_access(p_business_id);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_intel_window(p_business_id, p_days);
  WITH f AS (
    SELECT * FROM fn_intel_facts(p_business_id, p_branch_id, w.ts_from, w.ts_to, a.is_manager, a.sales, a.holds, a.actor, a.scope, a.my_branch)
    WHERE (p_category_id IS NULL OR category_id = p_category_id) AND (p_product_id IS NULL OR product_id = p_product_id)),
  tot AS (SELECT COALESCE(sum(sold_win), 0) AS sold_win, COALESCE(sum(sold_win) FILTER (WHERE size_value IS NOT NULL), 0) AS sold_sized,
                 COALESCE(sum(sold_win) FILTER (WHERE color_value IS NOT NULL), 0) AS sold_colored FROM f),
  sz AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'value', x.size_value, 'sold_win', x.sold_win, 'returned_win', x.returned_win,
             'share_pct', CASE WHEN tot.sold_sized >= v_min_sample AND tot.sold_sized > 0 THEN round(x.sold_win::numeric / tot.sold_sized * 100, 1) END,
             'return_rate_pct', CASE WHEN x.sold_win >= v_min_sample THEN round(x.returned_win::numeric / x.sold_win * 100, 1) END,
             'available', x.available, 'sellable', x.sellable, 'reserved', x.reserved, 'variants', x.variants, 'variants_out', x.variants_out,
             'holds_active', x.holds_active) ORDER BY x.size_order, x.size_value), '[]'::jsonb) AS j
    FROM (SELECT size_value, min(size_order) AS size_order, sum(sold_win) AS sold_win, sum(returned_win) AS returned_win, sum(available) AS available,
                 sum(sellable) AS sellable, sum(reserved) AS reserved, count(*) AS variants, count(*) FILTER (WHERE available <= 0) AS variants_out,
                 sum(holds_active) AS holds_active
          FROM f WHERE size_value IS NOT NULL GROUP BY size_value) x, tot),
  col AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'value', x.color_value, 'sold_win', x.sold_win, 'returned_win', x.returned_win,
             'share_pct', CASE WHEN tot.sold_colored >= v_min_sample AND tot.sold_colored > 0 THEN round(x.sold_win::numeric / tot.sold_colored * 100, 1) END,
             'return_rate_pct', CASE WHEN x.sold_win >= v_min_sample THEN round(x.returned_win::numeric / x.sold_win * 100, 1) END,
             'available', x.available, 'sellable', x.sellable, 'reserved', x.reserved, 'variants', x.variants, 'variants_out', x.variants_out,
             'holds_active', x.holds_active) ORDER BY x.sold_win DESC, x.color_value), '[]'::jsonb) AS j
    FROM (SELECT color_value, sum(sold_win) AS sold_win, sum(returned_win) AS returned_win, sum(available) AS available,
                 sum(sellable) AS sellable, sum(reserved) AS reserved, count(*) AS variants, count(*) FILTER (WHERE available <= 0) AS variants_out,
                 sum(holds_active) AS holds_active
          FROM f WHERE color_value IS NOT NULL GROUP BY color_value) x, tot)
  SELECT sz.j, col.j, tot.sold_win, tot.sold_sized, tot.sold_colored INTO v_size, v_color, v_sold, v_sized, v_colored FROM sz, col, tot;
  RETURN jsonb_build_object(
    'window', jsonb_build_object('days', w.days, 'from', w.today - w.days + 1, 'to', w.today, 'timezone', w.tz),
    'min_sample', v_min_sample, 'financial', a.is_manager, 'sales', a.sales, 'scope', a.scope,
    'filters', jsonb_build_object('category_id', p_category_id, 'product_id', p_product_id),
    'sold_win', v_sold, 'sold_sized', v_sized, 'sold_colored', v_colored,
    'sizes', v_size, 'colors', v_color);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_intel_dimensions(UUID,UUID,INTEGER,UUID,UUID,INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_intel_dimensions(UUID,UUID,INTEGER,UUID,UUID,INTEGER) TO authenticated;

-- ------------------------------------------------------------ 4. product intelligence (one call for the product page)
CREATE OR REPLACE FUNCTION rpc_intel_product(p_product_id UUID, p_days INTEGER DEFAULT 30, p_min_sample INTEGER DEFAULT 10)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_biz UUID; a RECORD; w RECORD; v_tot RECORD; v_sizes JSONB; v_colors JSONB; v_variants JSONB;
        v_min_sample INTEGER := GREATEST(COALESCE(p_min_sample, 10), 1);
BEGIN
  SELECT business_id INTO v_biz FROM products WHERE id = p_product_id;
  IF v_biz IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: product %', p_product_id USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO a FROM fn_intel_access(v_biz);
  SELECT * INTO w FROM fn_intel_window(v_biz, p_days);
  WITH f0 AS (
    SELECT * FROM fn_intel_facts(v_biz, NULL, w.ts_from, w.ts_to, a.is_manager, a.sales, a.holds, a.actor, a.scope, a.my_branch)
    WHERE product_id = p_product_id),
  f AS (
    SELECT f0.*,
           CASE WHEN first_arrival IS NULL THEN NULL ELSE (w.today - (first_arrival AT TIME ZONE w.tz)::date) END AS age_days,
           CASE WHEN last_sale_at IS NULL THEN NULL ELSE (w.today - (last_sale_at AT TIME ZONE w.tz)::date) END AS days_since_sale,
           CASE WHEN first_arrival IS NULL THEN w.days ELSE LEAST(w.days, (w.today - (first_arrival AT TIME ZONE w.tz)::date) + 1) END AS active_days
    FROM f0),
  tot AS (
    SELECT count(*) AS variants, COALESCE(sum(sold_win), 0) AS sold_win, COALESCE(sum(returned_win), 0) AS returned_win,
           COALESCE(sum(sold_all), 0) AS sold_all, COALESCE(sum(returned_all), 0) AS returned_all, COALESCE(sum(supplied), 0) AS supplied,
           COALESCE(sum(sellable), 0) AS sellable, COALESCE(sum(reserved), 0) AS reserved, COALESCE(sum(available), 0) AS available,
           COALESCE(sum(damaged), 0) AS damaged, COALESCE(sum(quarantine), 0) AS quarantine, COALESCE(sum(holds_active), 0) AS holds_active,
           min(first_arrival) AS first_arrival, max(last_sale_at) AS last_sale_at, max(active_days) AS active_days,
           count(*) FILTER (WHERE available <= 0 AND supplied > 0) AS variants_out,
           sum(pool_value) AS pool_value, COALESCE(sum(pool_qty), 0) AS pool_qty
    FROM f),
  sz AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('value', x.size_value, 'sold_win', x.sold_win, 'returned_win', x.returned_win,
             'share_pct', CASE WHEN t.sized >= v_min_sample AND t.sized > 0 THEN round(x.sold_win::numeric / t.sized * 100, 1) END,
             'return_rate_pct', CASE WHEN x.sold_win >= v_min_sample THEN round(x.returned_win::numeric / x.sold_win * 100, 1) END,
             'available', x.available, 'out', x.available <= 0 AND x.supplied > 0, 'never_stocked', x.supplied = 0, 'holds_active', x.holds_active)
             ORDER BY x.size_order, x.size_value), '[]'::jsonb) AS j
    FROM (SELECT size_value, min(size_order) AS size_order, sum(sold_win) AS sold_win, sum(returned_win) AS returned_win, sum(available) AS available,
                 sum(supplied) AS supplied, sum(holds_active) AS holds_active FROM f WHERE size_value IS NOT NULL GROUP BY size_value) x,
         (SELECT COALESCE(sum(sold_win), 0) AS sized FROM f WHERE size_value IS NOT NULL) t),
  col AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('value', x.color_value, 'sold_win', x.sold_win, 'returned_win', x.returned_win,
             'share_pct', CASE WHEN t.colored >= v_min_sample AND t.colored > 0 THEN round(x.sold_win::numeric / t.colored * 100, 1) END,
             'available', x.available, 'out', x.available <= 0 AND x.supplied > 0)
             ORDER BY x.sold_win DESC, x.color_value), '[]'::jsonb) AS j
    FROM (SELECT color_value, sum(sold_win) AS sold_win, sum(returned_win) AS returned_win, sum(available) AS available, sum(supplied) AS supplied
          FROM f WHERE color_value IS NOT NULL GROUP BY color_value) x,
         (SELECT COALESCE(sum(sold_win), 0) AS colored FROM f WHERE color_value IS NOT NULL) t),
  vr AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('variant_id', variant_id, 'sku', sku, 'size', size_value, 'color', color_value,
             'sold_win', sold_win, 'returned_win', returned_win, 'available', available, 'reserved', reserved, 'supplied', supplied,
             'age_days', age_days, 'days_since_sale', days_since_sale, 'holds_active', holds_active)
             ORDER BY size_order NULLS LAST, sku), '[]'::jsonb) AS j FROM f)
  SELECT tot.*, sz.j AS sizes, col.j AS colors, vr.j AS variants_j INTO v_tot FROM tot, sz, col, vr;
  RETURN jsonb_build_object(
    'window', jsonb_build_object('days', w.days, 'from', w.today - w.days + 1, 'to', w.today, 'timezone', w.tz),
    'min_sample', v_min_sample, 'financial', a.is_manager, 'sales', a.sales, 'scope', a.scope,
    'enough_data', v_tot.sold_win >= v_min_sample,
    'variants', v_tot.variants, 'variants_out', v_tot.variants_out,
    'sold_win', v_tot.sold_win, 'returned_win', v_tot.returned_win, 'sold_all', v_tot.sold_all, 'returned_all', v_tot.returned_all,
    'supplied', v_tot.supplied,
    'sell_through_pct', CASE WHEN a.sales AND v_tot.supplied > 0 THEN round((v_tot.sold_all - v_tot.returned_all)::numeric / v_tot.supplied * 100, 1) END,
    'active_days', v_tot.active_days,
    'velocity', CASE WHEN a.sales THEN round(v_tot.sold_win::numeric / GREATEST(COALESCE(v_tot.active_days, w.days), 1), 2) END,
    'days_of_cover', CASE WHEN a.sales AND v_tot.sold_win > 0 THEN round(v_tot.available::numeric / (v_tot.sold_win::numeric / GREATEST(COALESCE(v_tot.active_days, w.days), 1)), 0) END,
    'return_rate_pct', CASE WHEN a.sales AND v_tot.sold_win >= v_min_sample THEN round(v_tot.returned_win::numeric / v_tot.sold_win * 100, 1) END,
    'stock', jsonb_build_object('sellable', v_tot.sellable, 'reserved', v_tot.reserved, 'available', v_tot.available, 'damaged', v_tot.damaged, 'quarantine', v_tot.quarantine),
    'holds_active', CASE WHEN a.holds THEN v_tot.holds_active END,
    'first_arrival', v_tot.first_arrival, 'age_days', CASE WHEN v_tot.first_arrival IS NULL THEN NULL ELSE w.today - (v_tot.first_arrival AT TIME ZONE w.tz)::date END,
    'last_sale_at', v_tot.last_sale_at, 'days_since_sale', CASE WHEN v_tot.last_sale_at IS NULL THEN NULL ELSE w.today - (v_tot.last_sale_at AT TIME ZONE w.tz)::date END,
    'stock_value', CASE WHEN a.is_manager THEN round(COALESCE(v_tot.pool_value, 0), 2) END,
    'sizes', v_tot.sizes, 'colors', v_tot.colors, 'variants_detail', v_tot.variants_j);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_intel_product(UUID, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_intel_product(UUID, INTEGER, INTEGER) TO authenticated;

-- ------------------------------------------------------------ 5. indexes
-- None. EXPLAIN on 40k sales / 80k lines / 8k returns / 82k movements: the facts are whole-tenant
-- aggregates by variant (grouped scans), so a return_items(variant_id) index did not change the
-- plan or the time (330 vs 400 ms with noise); the existing sale_items(variant_id) and
-- inventory_movements(business_id, branch_id, variant_id, bucket) indexes are what the scans use.

-- ============================================================
-- END phase 11A
-- ============================================================
