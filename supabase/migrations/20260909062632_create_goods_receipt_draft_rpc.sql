-- ============================================================
-- BoutiqueOS  •  Phase 3 GAP-1  •  rpc_create_goods_receipt
-- ============================================================
-- Why this exists
-- ---------------
-- Every other document type gets its number from fn_next_sequence() inside a
-- SECURITY DEFINER RPC (sales 'S', returns 'R', reservations 'RV', register
-- sessions 'RS', supplier payments 'SP', internal barcodes 'BC'). Goods receipts
-- had no such entry point: goods_receipts.receipt_number is NOT NULL and unique
-- per business, while fn_next_sequence is REVOKEd from authenticated on purpose
-- (11_REV3_PREFLIGHT_REPORT §84 — a client GRANT would let one tenant burn
-- another tenant's counters) and document_sequences has no write policy.
--
-- Without this function a client would have to invent receipt numbers. Posted
-- receipts are immutable, so a wrong number could never be corrected, and a
-- later proper RPC would restart the 'GR' counter at 1 and collide.
--
-- 'GR' is a NEW prefix. It does not collide with BC / S / R / RV / RS / SP, and
-- it matches the receipt numbers already used by hand in tests/005.
--
-- Scope: additive only. No existing table, policy, trigger, function or grant is
-- modified. rpc_post_goods_receipt and the reversal stub are untouched.
-- ============================================================

-- ============================================================
-- rpc_create_goods_receipt  (owner | manager | stock_staff)
-- ============================================================
-- Tenant is derived from the branch, never taken from the caller: there is no
-- p_business_id parameter to spoof, and a user who belongs to several businesses
-- is resolved unambiguously by the branch they are receiving into. Same pattern
-- as rpc_create_variant, which derives the business from the product.
--
-- status is hard-coded to 'draft'. The caller cannot pass it, so a receipt can
-- never be born posted; only rpc_post_goods_receipt moves it forward.
--
-- FX: chk_gr_try_rate on the table and rpc_post_goods_receipt both treat a TRY
-- invoice with a rate other than 1 as an error, so this function rejects it too
-- (INVALID_FX) rather than silently normalising. Non-TRY rates are validated as
-- > 0 only — exactly what posting requires; fx_rates stays a reference source,
-- not a constraint, and this function does not change that decision.
CREATE OR REPLACE FUNCTION rpc_create_goods_receipt(
  p_branch_id        UUID,
  p_supplier_id      UUID,
  p_invoice_currency TEXT DEFAULT 'TRY',
  p_exchange_rate    NUMERIC DEFAULT 1,
  p_received_at      DATE DEFAULT CURRENT_DATE,
  p_document_ref     TEXT DEFAULT NULL,
  p_note             TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor    UUID := fn_actor();          -- raises UNAUTHENTICATED when auth.uid() is null
  v_biz      UUID;
  v_currency iso_currency;
  v_number   TEXT;
  v_id       UUID;
BEGIN
  -- 1. Resolve the tenant from the branch. A branch id that does not exist reads
  --    the same as one from another business: nothing is disclosed either way.
  SELECT business_id INTO v_biz FROM branches WHERE id = p_branch_id;
  IF v_biz IS NULL THEN
    RAISE EXCEPTION 'INVALID_BRANCH: branch % not found', p_branch_id USING ERRCODE='22023';
  END IF;

  -- 2. Membership + role. Procurement roles, same set that may post a receipt.
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager','stock_staff']::user_role[]);

  -- 3. The branch must be active and belong to that business.
  PERFORM fn_assert_branch(v_biz, p_branch_id);

  -- 4. The supplier must belong to the same business and be active.
  IF NOT EXISTS (
    SELECT 1 FROM suppliers
    WHERE id = p_supplier_id AND business_id = v_biz AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'INVALID_SUPPLIER: supplier % not active in business %', p_supplier_id, v_biz
      USING ERRCODE='22023';
  END IF;

  -- 5. Currency and FX.
  IF p_invoice_currency IS NULL THEN
    RAISE EXCEPTION 'INVALID_CURRENCY: currency is required' USING ERRCODE='22023';
  END IF;
  BEGIN
    v_currency := p_invoice_currency::iso_currency;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'INVALID_CURRENCY: %', p_invoice_currency USING ERRCODE='22023';
  END;

  IF p_exchange_rate IS NULL OR p_exchange_rate <= 0 THEN
    RAISE EXCEPTION 'INVALID_FX: exchange rate must be greater than zero' USING ERRCODE='22023';
  END IF;
  IF v_currency = 'TRY' AND p_exchange_rate <> 1 THEN
    RAISE EXCEPTION 'INVALID_FX: TRY invoice must have exchange_rate = 1' USING ERRCODE='22023';
  END IF;

  IF p_received_at IS NULL THEN
    RAISE EXCEPTION 'INVALID_DATE: received_at is required' USING ERRCODE='22023';
  END IF;

  -- 6. Server-side document number. fn_next_sequence is race-safe (upsert with
  --    ON CONFLICT DO UPDATE) and stays internal — the client never reaches it.
  v_number := fn_next_sequence(v_biz, 'GR');

  -- 7. status is not a parameter: a draft is the only thing this function makes.
  INSERT INTO goods_receipts (
    business_id, branch_id, supplier_id, receipt_number, document_ref,
    received_at, note, status, invoice_currency, exchange_rate, created_by
  ) VALUES (
    v_biz, p_branch_id, p_supplier_id, v_number, p_document_ref,
    p_received_at, p_note, 'draft', v_currency, p_exchange_rate, v_actor
  ) RETURNING id INTO v_id;

  RETURN v_id;
END $$;

REVOKE EXECUTE ON FUNCTION rpc_create_goods_receipt(UUID, UUID, TEXT, NUMERIC, DATE, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_create_goods_receipt(UUID, UUID, TEXT, NUMERIC, DATE, TEXT, TEXT) TO authenticated;

-- ============================================================
-- END 20260909062632
-- ============================================================
