-- ============================================================
-- Phase 10B follow-up — receiving report: landed total for receipts posted before 8A
--
-- Receipts posted before the landed-cost engine (20260916090000) carry no
-- posted_landed_total_base / posted_charges_base; their landed cost is the purchase value
-- (there were no charges). The report showed 0 for them (found on the TLC read-only smoke:
-- the one real posted receipt is pre-8A). Same shape, same authorisation, only the fallback.
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_report_receiving(
  p_business_id UUID, p_date_from DATE, p_date_to DATE, p_branch_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE w RECORD; v_tot JSONB; v_sup JSONB; v_rev JSONB;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_report_assert_branch(p_business_id, p_branch_id);
  SELECT * INTO w FROM fn_report_window(p_business_id, p_date_from, p_date_to);
  WITH g0 AS (
    SELECT g.id, g.supplier_id, g.branch_id, g.posted_charges_base, g.posted_landed_total_base,
           (SELECT COALESCE(sum(i.quantity), 0) FROM goods_receipt_items i WHERE i.goods_receipt_id = g.id) AS units,
           (SELECT COALESCE(sum(i.total_cost_base), 0) FROM goods_receipt_items i WHERE i.goods_receipt_id = g.id) AS purchase_base
    FROM goods_receipts g
    WHERE g.business_id = p_business_id AND g.status = 'posted' AND g.posted_at >= w.ts_from AND g.posted_at < w.ts_to
      AND (p_branch_id IS NULL OR g.branch_id = p_branch_id)),
  g AS (
    SELECT g0.id, g0.supplier_id, g0.units, g0.purchase_base,
           COALESCE(g0.posted_charges_base, 0) AS charges_base,
           -- pre-8A receipts: no charges existed, landed = purchase
           COALESCE(g0.posted_landed_total_base, g0.purchase_base + COALESCE(g0.posted_charges_base, 0)) AS landed_base,
           (SELECT COALESCE(sum(e.amount_base), 0) FROM supplier_account_entries e
            WHERE e.business_id = p_business_id AND e.entry_type = 'liability'
              AND ((e.reference_type = 'goods_receipt' AND e.reference_id = g0.id)
                OR (e.reference_type = 'goods_receipt_charge'
                    AND e.reference_id IN (SELECT c.id FROM goods_receipt_charges c WHERE c.goods_receipt_id = g0.id)))) AS liability_base,
           EXISTS (SELECT 1 FROM goods_receipt_reversals rv WHERE rv.goods_receipt_id = g0.id) AS reversed
    FROM g0),
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
-- ============================================================
-- END phase 10B follow-up
-- ============================================================
