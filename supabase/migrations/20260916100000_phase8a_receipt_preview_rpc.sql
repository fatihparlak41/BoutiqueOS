-- ============================================================
-- Phase 8A — read-only allocation preview for the receiving screen
-- ============================================================
-- The review RPC stamps the document; the screen also needs the same numbers without a
-- write (page load after a review, or before deciding to review). Returns the allocation
-- rows plus whether the stored review still matches the document.
CREATE OR REPLACE FUNCTION rpc_goods_receipt_preview(p_goods_receipt_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
DECLARE gr RECORD; v_lines JSONB; v_current BOOLEAN;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  IF gr.status <> 'draft' THEN
    RETURN jsonb_build_object('status', gr.status, 'lines', '[]'::jsonb, 'review_current', false);
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.variant_id), '[]'::jsonb) INTO v_lines FROM fn_goods_receipt_allocation_fixed(gr.id) a;
  v_current := gr.review_hash IS NOT NULL AND gr.review_hash = fn_goods_receipt_hash(gr.id);
  RETURN jsonb_build_object('status', gr.status, 'lines', v_lines, 'review_current', v_current, 'reviewed_at', gr.reviewed_at);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_goods_receipt_preview(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_goods_receipt_preview(UUID) TO authenticated;
