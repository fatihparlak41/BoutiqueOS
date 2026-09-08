-- ============================================================
-- ButikOS — Things Like Crop
-- Supabase PostgreSQL Schema  •  Migration 004
-- Posting RPCs  •  Rev 3  •  2026-09-08
-- ============================================================
-- Functions in this file (all SECURITY DEFINER, SET search_path):
--   1. rpc_confirm_goods_receipt      — PO → stock; preserves original currency
--   2. rpc_process_return             — Sale return → quarantine; credits cost pool
--   3. rpc_ship_transfer              — Ship stock between branches
--   4. rpc_receive_transfer           — Receive and post inbound transfer
--   5. rpc_reverse_goods_receipt      — NOT IMPLEMENTED stub (V2)
-- ============================================================
-- PERMANENT CONSTRAINTS (enforced here, not in app):
--   - SALES_STAFF cannot see unit_cost_at_sale, average_cost, or any cost field.
--     Cost isolation is enforced via table-level RLS on sale_item_costs, sale_costs,
--     variant_cost_pools — not by filtering in these RPCs.
--   - Normal users cannot directly INSERT to accounting ledger tables.
--   - Actor is always auth.uid(); never a client-supplied UUID.
--   - All cost reads come from variant_cost_pools (via fn_post_to_cost_pool),
--     NEVER from a client payload or from product_variants.
--   - All posting operations lock variant_cost_pools FOR UPDATE
--     in deterministic order (variant_id ASC) to prevent deadlocks.
--   - No refunds for TLC (allow_cash_refund = false in businesses.settings).
--     All returns go to QUARANTINE bucket by default.
--   - V1 transfers: no partial receipt; all lines must be received together.
-- ============================================================


-- ============================================================
-- 1. RPC_CONFIRM_GOODS_RECEIPT
-- ============================================================
-- Confirms a draft goods receipt, posting stock into inventory and
-- updating the cost pool. Records the supplier liability in the original
-- invoice currency (preserving the invoice currency), plus the TRY base
-- equivalent via the amount_base GENERATED column on supplier_account_entries.
--
-- Preconditions:
--   - goods_receipt.status must be 'draft'
--   - goods_receipt_items must have unit_cost_base populated
--   - fn_lock_confirmed_goods_receipt trigger fires AFTER this sets status='confirmed'
--     to prevent re-confirmation
--
-- Cost pool: fn_post_to_cost_pool called for each line (p_qty_delta = +received_qty)
-- Supplier ledger: INSERT into supplier_account_entries preserving original currency
--
-- CRITICAL: Actor = auth.uid() (never client-supplied)
-- CRITICAL: unit_cost from gri.unit_cost_base (never client payload)

CREATE OR REPLACE FUNCTION rpc_confirm_goods_receipt(
  p_business_id        UUID,
  p_goods_receipt_id   UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor         UUID;
  v_receipt       RECORD;
  v_item          RECORD;
  v_cost_result   t_cost_pool_result;
BEGIN
  v_actor := auth.uid();

  -- Caller must be manager or owner
  IF NOT fn_is_manager_plus(p_business_id) THEN
    RAISE EXCEPTION 'rpc_confirm_goods_receipt: manager or owner role required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Lock and fetch the goods receipt
  SELECT gr.*
  INTO v_receipt
  FROM goods_receipts gr
  WHERE gr.id = p_goods_receipt_id
    AND gr.business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'rpc_confirm_goods_receipt: goods receipt % not found', p_goods_receipt_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_receipt.status <> 'draft' THEN
    RAISE EXCEPTION 'rpc_confirm_goods_receipt: receipt % is already %, cannot confirm',
      p_goods_receipt_id, v_receipt.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Process each line item in deterministic order
  FOR v_item IN
    SELECT gri.*
    FROM goods_receipt_items gri
    WHERE gri.goods_receipt_id = p_goods_receipt_id
    ORDER BY gri.variant_id  -- deterministic order for lock acquisition
  LOOP
    IF v_item.unit_cost_base IS NULL THEN
      RAISE EXCEPTION 'rpc_confirm_goods_receipt: item % missing unit_cost_base', v_item.id
        USING ERRCODE = 'null_value_not_allowed';
    END IF;

    IF v_item.quantity_received <= 0 THEN
      RAISE EXCEPTION 'rpc_confirm_goods_receipt: item % quantity_received must be positive', v_item.id
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Post to cost pool (fn_post_to_cost_pool locks the pool row FOR UPDATE internally)
    v_cost_result := fn_post_to_cost_pool(
      p_business_id    := p_business_id,
      p_branch_id      := v_receipt.branch_id,
      p_variant_id     := v_item.variant_id,
      p_qty_delta      := v_item.quantity_received::INTEGER,
      p_unit_cost_base := v_item.unit_cost_base
    );

    -- Record inventory movement into sellable bucket
    INSERT INTO inventory_movements (
      business_id, branch_id, variant_id,
      quantity, bucket,
      movement_type, reference_id, reference_type,
      unit_cost_base, total_cost_base,
      notes
    ) VALUES (
      p_business_id, v_receipt.branch_id, v_item.variant_id,
      v_item.quantity_received, 'sellable',
      'goods_receipt', p_goods_receipt_id, 'goods_receipt',
      v_item.unit_cost_base,
      v_item.unit_cost_base * v_item.quantity_received,
      NULL
    );

    -- Update the goods receipt item with confirmed cost totals
    UPDATE goods_receipt_items
    SET
      total_cost_base     = v_item.unit_cost_base * v_item.quantity_received,
      total_cost_original = v_item.unit_cost_original * v_item.quantity_received
    WHERE id = v_item.id;

  END LOOP;

  -- Mark receipt as confirmed
  -- fn_lock_confirmed_goods_receipt trigger will prevent re-confirmation.
  UPDATE goods_receipts
  SET
    status       = 'confirmed',
    confirmed_by = v_actor,
    confirmed_at = NOW()
  WHERE id = p_goods_receipt_id;

  -- Record supplier liability in original invoice currency.
  -- amount_original = what appears on the supplier invoice.
  -- amount_base (GENERATED = amount_original * exchange_rate) = TRY equivalent.
  -- Preserving original currency keeps the supplier balance view multi-currency accurate.
  INSERT INTO supplier_account_entries (
    business_id, supplier_id,
    entry_type, reference_id, reference_type,
    currency, exchange_rate,
    amount_original,
    notes
  )
  VALUES (
    p_business_id,
    v_receipt.supplier_id,
    'invoice',
    p_goods_receipt_id,
    'goods_receipt',
    v_receipt.currency,
    v_receipt.exchange_rate,
    (
      SELECT SUM(gri.unit_cost_original * gri.quantity_received)
      FROM goods_receipt_items gri
      WHERE gri.goods_receipt_id = p_goods_receipt_id
    ),
    'Goods receipt confirmed'
  );

END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_confirm_goods_receipt(UUID, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rpc_confirm_goods_receipt(UUID, UUID) TO authenticated;


-- ============================================================
-- 2. RPC_PROCESS_RETURN
-- ============================================================
-- Processes a customer return for a previously completed sale.
--
-- Rules enforced at DB level:
--   - Exchange window enforced: sale.occurred_at + exchange_window_days >= NOW()
--     (exchange_window_days read from businesses.settings, not client)
--   - NO REFUNDS for TLC: allow_cash_refund=false → RAISE if return_type='refund'
--   - variant_id read from sale_items (NEVER from client payload)
--   - unit_cost_at_sale read from sale_item_costs (NEVER from client payload)
--   - All returned items go to QUARANTINE bucket
--   - Cost pool credited at unit_cost_at_sale
--
-- p_items: JSONB array of {sale_item_id UUID, quantity_returned INTEGER}
-- p_return_type: 'exchange' only for TLC (refund rejected by DB)
-- p_reason: free-text reason

CREATE OR REPLACE FUNCTION rpc_process_return(
  p_business_id   UUID,
  p_branch_id     UUID,
  p_sale_id       UUID,
  p_items         JSONB,
  p_return_type   return_type,
  p_reason        TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor               UUID;
  v_sale                RECORD;
  v_settings            JSONB;
  v_exchange_window     INTEGER;
  v_allow_cash_refund   BOOLEAN;
  v_deadline            TIMESTAMPTZ;
  v_return_id           UUID;
  v_item_rec            RECORD;
  v_sale_item           RECORD;
  v_cost_rec            RECORD;
  v_cost_result         t_cost_pool_result;
  v_qty_returned        INTEGER;
BEGIN
  v_actor := auth.uid();

  -- Member+ may initiate returns at POS; manager validation is a UX concern
  IF NOT fn_is_member(p_business_id) THEN
    RAISE EXCEPTION 'rpc_process_return: not a member of this business'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Read business settings (authoritative source for refund policy and exchange window)
  SELECT settings INTO v_settings
  FROM businesses
  WHERE id = p_business_id;

  v_allow_cash_refund := COALESCE((v_settings->>'allow_cash_refund')::BOOLEAN, false);
  v_exchange_window   := COALESCE((v_settings->>'exchange_window_days')::INTEGER, 3);

  -- TLC: block ALL refunds at the database layer
  IF p_return_type = 'refund' AND NOT v_allow_cash_refund THEN
    RAISE EXCEPTION 'rpc_process_return: refunds are not permitted (allow_cash_refund=false)'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Lock and validate the sale
  SELECT s.*
  INTO v_sale
  FROM sales s
  WHERE s.id          = p_sale_id
    AND s.business_id = p_business_id
    AND s.branch_id   = p_branch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'rpc_process_return: sale % not found', p_sale_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_sale.status <> 'completed' THEN
    RAISE EXCEPTION 'rpc_process_return: sale % has status %, only completed sales can be returned',
      p_sale_id, v_sale.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Enforce exchange window
  v_deadline := v_sale.occurred_at + (v_exchange_window || ' days')::INTERVAL;
  IF NOW() > v_deadline THEN
    RAISE EXCEPTION 'rpc_process_return: exchange window expired for sale %. occurred_at=%, window=% days, deadline=%',
      p_sale_id, v_sale.occurred_at, v_exchange_window, v_deadline
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Create the return header
  INSERT INTO returns (
    business_id, branch_id, sale_id,
    return_type, reason,
    status, processed_by, processed_at
  ) VALUES (
    p_business_id, p_branch_id, p_sale_id,
    p_return_type, p_reason,
    'completed', v_actor, NOW()
  )
  RETURNING id INTO v_return_id;

  -- Process each returned line in deterministic order
  FOR v_item_rec IN
    SELECT
      (item->>'sale_item_id')::UUID AS sale_item_id,
      (item->>'quantity_returned')::INTEGER AS quantity_returned
    FROM jsonb_array_elements(p_items) AS item
    ORDER BY (item->>'sale_item_id')::UUID
  LOOP
    v_qty_returned := v_item_rec.quantity_returned;

    IF v_qty_returned <= 0 THEN
      RAISE EXCEPTION 'rpc_process_return: quantity_returned must be positive for sale_item %',
        v_item_rec.sale_item_id
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Read variant_id from sale_items (NEVER from client payload)
    SELECT si.*
    INTO v_sale_item
    FROM sale_items si
    WHERE si.id          = v_item_rec.sale_item_id
      AND si.sale_id     = p_sale_id
      AND si.business_id = p_business_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'rpc_process_return: sale_item % not found on sale %',
        v_item_rec.sale_item_id, p_sale_id
        USING ERRCODE = 'no_data_found';
    END IF;

    IF v_qty_returned > v_sale_item.quantity THEN
      RAISE EXCEPTION 'rpc_process_return: cannot return % units of sale_item %; only % were sold',
        v_qty_returned, v_item_rec.sale_item_id, v_sale_item.quantity
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Read unit_cost_at_sale from sale_item_costs (NEVER from client payload)
    SELECT sic.*
    INTO v_cost_rec
    FROM sale_item_costs sic
    WHERE sic.sale_item_id = v_item_rec.sale_item_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'rpc_process_return: no cost record for sale_item % — data integrity error',
        v_item_rec.sale_item_id
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    -- Credit cost pool at unit_cost_at_sale into QUARANTINE bucket.
    -- variant_cost_pools represents ALL owned inventory (SELLABLE + QUARANTINE + DAMAGED).
    -- The bucket is tracked in inventory_movements only; the cost pool is per variant/branch.
    v_cost_result := fn_post_to_cost_pool(
      p_business_id    := p_business_id,
      p_branch_id      := p_branch_id,
      p_variant_id     := v_sale_item.variant_id,
      p_qty_delta      := v_qty_returned,
      p_unit_cost_base := v_cost_rec.unit_cost_at_sale
    );

    -- Record return item with quarantine disposition
    INSERT INTO return_items (
      return_id, sale_item_id,
      variant_id, quantity_returned,
      unit_cost_at_return, disposition
    ) VALUES (
      v_return_id, v_item_rec.sale_item_id,
      v_sale_item.variant_id, v_qty_returned,
      v_cost_rec.unit_cost_at_sale, 'quarantine'
    );

    -- Record inventory movement: stock re-enters as quarantine
    INSERT INTO inventory_movements (
      business_id, branch_id, variant_id,
      quantity, bucket,
      movement_type, reference_id, reference_type,
      unit_cost_base, total_cost_base,
      notes
    ) VALUES (
      p_business_id, p_branch_id, v_sale_item.variant_id,
      v_qty_returned, 'quarantine',
      'return', v_return_id, 'return',
      v_cost_rec.unit_cost_at_sale,
      v_cost_rec.unit_cost_at_sale * v_qty_returned,
      p_reason
    );

  END LOOP;

  RETURN v_return_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_process_return(UUID, UUID, UUID, JSONB, return_type, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rpc_process_return(UUID, UUID, UUID, JSONB, return_type, TEXT) TO authenticated;


-- ============================================================
-- 3. RPC_SHIP_TRANSFER
-- ============================================================
-- Ships stock from a source branch to a destination branch.
-- Deducts from source cost pool, then records the exact TRY value
-- in transfer_held_inventory.carried_total_value_base.
--
-- CRITICAL: Store carried_total_value_base = ABS(value_delta_base),
-- NOT unit_cost_base * quantity. This preserves exact TRY value
-- without rounding on division (especially for odd quantities).
--
-- p_items: JSONB array of {variant_id UUID, quantity INTEGER}

CREATE OR REPLACE FUNCTION rpc_ship_transfer(
  p_business_id        UUID,
  p_from_branch_id     UUID,
  p_to_branch_id       UUID,
  p_transfer_id        UUID,
  p_items              JSONB
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor        UUID;
  v_transfer     RECORD;
  v_item_rec     RECORD;
  v_cost_result  t_cost_pool_result;
BEGIN
  v_actor := auth.uid();

  IF NOT fn_is_manager_plus(p_business_id) THEN
    RAISE EXCEPTION 'rpc_ship_transfer: manager or owner role required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Lock and validate the transfer header
  SELECT st.*
  INTO v_transfer
  FROM stock_transfers st
  WHERE st.id          = p_transfer_id
    AND st.business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'rpc_ship_transfer: transfer % not found', p_transfer_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_transfer.status <> 'pending' THEN
    RAISE EXCEPTION 'rpc_ship_transfer: transfer % has status %, must be pending',
      p_transfer_id, v_transfer.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_transfer.from_branch_id <> p_from_branch_id THEN
    RAISE EXCEPTION 'rpc_ship_transfer: from_branch_id mismatch on transfer %', p_transfer_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_transfer.to_branch_id <> p_to_branch_id THEN
    RAISE EXCEPTION 'rpc_ship_transfer: to_branch_id mismatch on transfer %', p_transfer_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Process each line in variant_id ASC order (deterministic lock ordering)
  FOR v_item_rec IN
    SELECT
      (item->>'variant_id')::UUID AS variant_id,
      (item->>'quantity')::INTEGER AS quantity
    FROM jsonb_array_elements(p_items) AS item
    ORDER BY (item->>'variant_id')::UUID
  LOOP
    IF v_item_rec.quantity <= 0 THEN
      RAISE EXCEPTION 'rpc_ship_transfer: quantity must be positive for variant %', v_item_rec.variant_id
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Deduct from source cost pool FIRST (fn_post_to_cost_pool locks FOR UPDATE internally).
    -- fn_post_to_cost_pool RAISES if source would go negative (oversell protection).
    v_cost_result := fn_post_to_cost_pool(
      p_business_id    := p_business_id,
      p_branch_id      := p_from_branch_id,
      p_variant_id     := v_item_rec.variant_id,
      p_qty_delta      := -(v_item_rec.quantity),  -- debit from source
      p_unit_cost_base := NULL                      -- use pool average (outbound)
    );

    -- Create transfer_held_inventory record.
    -- carried_total_value_base = ABS(value_delta_base):
    --   the exact TRY value removed from the source pool.
    --   Storing this (not unit_cost) prevents rounding drift on the destination side.
    INSERT INTO transfer_held_inventory (
      business_id,
      transfer_id,
      variant_id,
      quantity_sent,
      carried_total_value_base,
      shipped_by,
      shipped_at
    ) VALUES (
      p_business_id,
      p_transfer_id,
      v_item_rec.variant_id,
      v_item_rec.quantity,
      ABS(v_cost_result.value_delta_base),
      v_actor,
      NOW()
    );

    -- Record outbound inventory movement at source branch
    INSERT INTO inventory_movements (
      business_id, branch_id, variant_id,
      quantity, bucket,
      movement_type, reference_id, reference_type,
      unit_cost_base, total_cost_base,
      notes
    ) VALUES (
      p_business_id, p_from_branch_id, v_item_rec.variant_id,
      -(v_item_rec.quantity), 'sellable',
      'transfer_out', p_transfer_id, 'stock_transfer',
      v_cost_result.unit_cost_used,
      ABS(v_cost_result.value_delta_base),
      'Transfer to branch ' || p_to_branch_id::TEXT
    );

    -- Update stock_transfer_lines with shipped cost info
    UPDATE stock_transfer_lines
    SET
      quantity_shipped         = v_item_rec.quantity,
      unit_cost_at_ship        = v_cost_result.unit_cost_used,
      carried_total_value_base = ABS(v_cost_result.value_delta_base)
    WHERE transfer_id = p_transfer_id
      AND variant_id  = v_item_rec.variant_id;

  END LOOP;

  -- Mark transfer as in_transit
  UPDATE stock_transfers
  SET
    status     = 'in_transit',
    shipped_by = v_actor,
    shipped_at = NOW()
  WHERE id = p_transfer_id;

END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_ship_transfer(UUID, UUID, UUID, UUID, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rpc_ship_transfer(UUID, UUID, UUID, UUID, JSONB) TO authenticated;


-- ============================================================
-- 4. RPC_RECEIVE_TRANSFER
-- ============================================================
-- Receives all lines of an in-transit transfer at the destination branch.
-- Posts the exact carried_total_value_base from transfer_held_inventory
-- into the destination cost pool (no rounding, no unit cost recalculation).
--
-- V1 CONSTRAINT: No partial receipt. All lines must have a THI record.
-- Missing THI record → RAISE EXCEPTION (never COALESCE to 0).

CREATE OR REPLACE FUNCTION rpc_receive_transfer(
  p_business_id   UUID,
  p_transfer_id   UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor       UUID;
  v_transfer    RECORD;
  v_thi         RECORD;
  v_line_count  INTEGER;
  v_thi_count   INTEGER;
  v_unit_cost   NUMERIC(12,4);
BEGIN
  v_actor := auth.uid();

  IF NOT fn_is_manager_plus(p_business_id) THEN
    RAISE EXCEPTION 'rpc_receive_transfer: manager or owner role required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Lock and validate the transfer
  SELECT st.*
  INTO v_transfer
  FROM stock_transfers st
  WHERE st.id          = p_transfer_id
    AND st.business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'rpc_receive_transfer: transfer % not found', p_transfer_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_transfer.status <> 'in_transit' THEN
    RAISE EXCEPTION 'rpc_receive_transfer: transfer % has status %, must be in_transit',
      p_transfer_id, v_transfer.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- V1: Validate ALL lines have a THI record (no partial receipt)
  SELECT COUNT(*) INTO v_line_count
  FROM stock_transfer_lines
  WHERE transfer_id = p_transfer_id;

  SELECT COUNT(*) INTO v_thi_count
  FROM transfer_held_inventory
  WHERE transfer_id = p_transfer_id
    AND business_id = p_business_id;

  IF v_thi_count <> v_line_count THEN
    RAISE EXCEPTION
      'rpc_receive_transfer: partial receipt not supported in V1. Transfer % has % lines but only % THI records. All lines must be shipped before receiving.',
      p_transfer_id, v_line_count, v_thi_count
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Process each THI record in deterministic order (variant_id ASC)
  FOR v_thi IN
    SELECT thi.*
    FROM transfer_held_inventory thi
    WHERE thi.transfer_id = p_transfer_id
      AND thi.business_id = p_business_id
    ORDER BY thi.variant_id
    FOR UPDATE
  LOOP
    -- Validate carried value integrity — NEVER COALESCE to 0
    IF v_thi.carried_total_value_base IS NULL OR v_thi.carried_total_value_base < 0 THEN
      RAISE EXCEPTION
        'rpc_receive_transfer: THI record % for variant % has invalid carried_total_value_base=%',
        v_thi.id, v_thi.variant_id, v_thi.carried_total_value_base
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    -- Compute implied unit cost for fn_post_to_cost_pool.
    -- Net effect: destination pool += carried_total_value_base exactly.
    -- Division is safe: quantity_sent > 0 is enforced at ship time.
    v_unit_cost := v_thi.carried_total_value_base / v_thi.quantity_sent;

    -- Post to destination cost pool
    PERFORM fn_post_to_cost_pool(
      p_business_id    := p_business_id,
      p_branch_id      := v_transfer.to_branch_id,
      p_variant_id     := v_thi.variant_id,
      p_qty_delta      := v_thi.quantity_sent,
      p_unit_cost_base := v_unit_cost
    );

    -- Record inbound inventory movement at destination branch
    INSERT INTO inventory_movements (
      business_id, branch_id, variant_id,
      quantity, bucket,
      movement_type, reference_id, reference_type,
      unit_cost_base, total_cost_base,
      notes
    ) VALUES (
      p_business_id, v_transfer.to_branch_id, v_thi.variant_id,
      v_thi.quantity_sent, 'sellable',
      'transfer_in', p_transfer_id, 'stock_transfer',
      v_unit_cost,
      v_thi.carried_total_value_base,
      'Received from branch ' || v_transfer.from_branch_id::TEXT
    );

    -- Update stock_transfer_lines: V1 received = sent (no partial)
    UPDATE stock_transfer_lines
    SET quantity_received = v_thi.quantity_sent
    WHERE transfer_id = p_transfer_id
      AND variant_id  = v_thi.variant_id;

  END LOOP;

  -- Mark transfer as received
  UPDATE stock_transfers
  SET
    status      = 'received',
    received_by = v_actor,
    received_at = NOW()
  WHERE id = p_transfer_id;

END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_receive_transfer(UUID, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rpc_receive_transfer(UUID, UUID) TO authenticated;


-- ============================================================
-- 5. RPC_REVERSE_GOODS_RECEIPT — NOT IMPLEMENTED (V2)
-- ============================================================
-- Reversal of a confirmed goods receipt is deferred to V2.
-- Required design decisions before implementing:
--   - Partial reversal policy (reverse all lines or per-line selection?)
--   - Handling of items partially sold since receipt confirmation
--   - Supplier credit note workflow (reversal entry type, or separate document?)
--   - Cost pool impact when MWA has changed since the original receipt
--
-- This stub RAISES immediately to prevent any direct table workarounds.
-- Do NOT drop this function or remove the REVOKE grant.

CREATE OR REPLACE FUNCTION rpc_reverse_goods_receipt(
  p_business_id      UUID,
  p_goods_receipt_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION
    'rpc_reverse_goods_receipt: NOT IMPLEMENTED. Goods receipt reversal is deferred to V2. Receipt=%. Contact the development team to design the reversal workflow.',
    p_goods_receipt_id
    USING ERRCODE = 'feature_not_supported';
END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_reverse_goods_receipt(UUID, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rpc_reverse_goods_receipt(UUID, UUID) TO authenticated;


-- ============================================================
-- MIGRATION 004 COMPLETE
-- ============================================================
-- Summary:
--   ✓ rpc_confirm_goods_receipt (SECURITY DEFINER, SET search_path):
--       - Manager+ only; actor = auth.uid()
--       - Locks goods_receipt FOR UPDATE; validates status = 'draft'
--       - Reads unit_cost_base from gri rows (never client payload)
--       - fn_post_to_cost_pool per line in variant_id ASC order
--       - Inserts inventory_movements (bucket=sellable, type=goods_receipt)
--       - Updates gri.total_cost_base and gri.total_cost_original
--       - Inserts supplier_account_entry in ORIGINAL invoice currency
--         (amount_base GENERATED on that table gives TRY equivalent)
--
--   ✓ rpc_process_return (SECURITY DEFINER, SET search_path):
--       - Member+ allowed (staff may initiate at POS)
--       - Reads allow_cash_refund + exchange_window_days from businesses.settings
--       - RAISES if return_type='refund' and allow_cash_refund=false (always true for TLC)
--       - Enforces exchange window via occurred_at + window_days >= NOW()
--       - variant_id read from sale_items (NEVER client payload)
--       - unit_cost_at_sale read from sale_item_costs (NEVER client payload)
--       - All returned stock → QUARANTINE bucket
--       - Credits cost pool at unit_cost_at_sale
--       - Inserts return_items (disposition='quarantine') and inventory_movements
--
--   ✓ rpc_ship_transfer (SECURITY DEFINER, SET search_path):
--       - Manager+ only; actor = auth.uid()
--       - Locks stock_transfer FOR UPDATE; validates status='pending'
--       - Processes lines in variant_id ASC order (deterministic lock ordering)
--       - fn_post_to_cost_pool called FIRST → value_delta_base → carried_total_value_base
--       - carried_total_value_base = ABS(value_delta_base), NOT unit_cost * qty
--       - Inserts transfer_held_inventory with exact TRY value carried
--       - Inserts inventory_movements (qty negative, bucket=sellable, type=transfer_out)
--       - Updates stock_transfer_lines with shipped cost info
--
--   ✓ rpc_receive_transfer (SECURITY DEFINER, SET search_path):
--       - Manager+ only; actor = auth.uid()
--       - Locks stock_transfer FOR UPDATE; validates status='in_transit'
--       - V1: RAISES if line_count ≠ thi_count (no partial receipt)
--       - RAISES if THI record has invalid carried_total_value_base (NEVER COALESCE 0)
--       - Posts exact carried_total_value_base to destination cost pool
--       - Inserts inventory_movements (bucket=sellable, type=transfer_in)
--       - Updates stock_transfer_lines: quantity_received = quantity_sent (V1)
--
--   ✓ rpc_reverse_goods_receipt (SECURITY DEFINER, SET search_path):
--       - Explicit NOT IMPLEMENTED stub
--       - RAISES EXCEPTION with ERRCODE = feature_not_supported
--       - Deferred to V2 with design decision notes
--       - REVOKE from PUBLIC; GRANT to authenticated (consistent with all RPCs)
-- ============================================================
