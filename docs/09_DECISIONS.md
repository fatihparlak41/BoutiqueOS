# ButikOS — Architecture Decision Records (ADRs)

**Version:** Rev 3 · 2026-09-08

---

## ADR-01 · Moving Weighted Average (MWA) for Cost Accounting

**Decision:** Use Moving Weighted Average, computed and stored in `variant_cost_pools`, updated atomically on every goods receipt and sale.

**Alternatives considered:**
- FIFO: Accurate but requires tracking individual lot IDs through each sale. Adds significant complexity for V1.
- Standard cost: Simple but inaccurate for a boutique with varying supplier prices.

**Consequences:**
- Cost pool must be locked FOR UPDATE on every inventory movement (deadlock prevention via variant_id ASC order).
- MWA at exact depletion: when `on_hand_qty` reaches 0, `total_value_base` is set to exactly 0 (no rounding residue).
- PRE-movement MWA is used as `unit_cost_used` for outbound movements (sale, transfer-out).

---

## ADR-02 · Cost Split Tables (sale_item_costs, sale_costs)

**Decision:** Store cost/margin data in separate tables from `sale_items`/`sales`, with manager-only RLS policies.

**Rationale:** `SALES_STAFF` must be blocked at the PostgreSQL level from reading unit costs, gross margin, and cost-pool values. Adding RLS to the main `sale_items` table would block staff from reading their own sale lines. Splitting into separate cost tables allows fine-grained RLS.

**Consequences:**
- Two extra tables to maintain.
- `rpc_process_sale` must INSERT into `sale_item_costs` and `sale_costs` in addition to `sale_items`.
- Reporting queries must JOIN cost tables, which only managers can do.

---

## ADR-03 · Immutable FX Rate Records

**Decision:** FX rates are INSERT-only. A correction creates a new record and supersedes the old one via `superseded_by` link. The `rpc_set_fx_rate` function uses a 4-step atomic operation: lock → deactivate old → insert new → set superseded_by.

**Rationale:**
- Owner may enter a wrong rate and need to correct it without losing the audit trail.
- Direct UPDATE would destroy the audit trail.
- 4-step order is critical: the partial UNIQUE index `WHERE is_current = true` would reject the new INSERT if the old row still has `is_current = true`.

**Consequences:**
- No UPDATE or DELETE policies on `fx_rates`.
- `rpc_set_fx_rate` is SECURITY DEFINER (must bypass RLS to write `is_current = false` on the old row).
- Reporting must filter `WHERE is_current = true` for current rates.

---

## ADR-04 · Cross-Tenant Composite FK Pattern

**Decision:** All major entity tables carry `UNIQUE(business_id, id)`. Child tables store `(business_id, entity_id)` as a composite FK, preventing cross-tenant references at the DB level.

**Rationale:** A simple FK on `variant_id` alone would allow Business A to reference a variant belonging to Business B. Composite FK enforces tenant isolation without application code.

**Applied to:** branches, brands, categories, suppliers, product_options, products, product_variants, goods_receipt_items.

**Consequence:** `business_id` must be propagated to child tables. Done via BEFORE INSERT triggers (`trg_variant_business_id`, `trg_gri_business_id`) so callers cannot spoof it.

---

## ADR-05 · Transfer Value: carried_total_value_base = ABS(value_delta_base)

**Decision:** When shipping a transfer, store the exact TRY value removed from the source cost pool (`ABS(value_delta_base)` from `fn_post_to_cost_pool`) in `transfer_held_inventory.carried_total_value_base`. Do NOT recompute as `unit_cost × quantity`.

**Rationale:** Division followed by multiplication introduces rounding drift for odd quantities. Example: pool value = 100 TRY, qty = 3. MWA = 33.3333 TRY/unit. 3 × 33.3333 = 99.9999 ≠ 100. Storing the exact `value_delta_base` preserves accounting accuracy.

**Consequence:** The destination pool receives exactly the same TRY value that left the source pool. `unit_cost` for the destination `fn_post_to_cost_pool` call is computed as `carried_total_value_base / quantity` (implied unit cost), which may not be a round number but is mathematically exact.

---

## ADR-06 · V1 Transfer: No Partial Receipt

**Decision:** `rpc_receive_transfer` requires ALL lines to have a `transfer_held_inventory` record. If any line is missing, the function raises an exception.

**Rationale:** Partial receipt requires tracking which lines have been received vs. still in transit, updating the transfer header status conditionally, and handling cost pool splits for partially-received transfers. This is out of scope for V1.

**Consequence:** `stock_transfer_lines.quantity_received = quantity_sent` always (V1). The transfer status jumps directly from `shipped` to `received` with no intermediate state.

---

## ADR-07 · All Returns → QUARANTINE Bucket

**Decision:** All returned items, regardless of `return_item_condition`, enter the `quarantine` inventory bucket. Disposition to `sellable` or `damaged` is a separate, manual operation (V2).

**Rationale:** TLC's process is to inspect returned items before putting them back on the floor. The DB should not assume an item is resellable upon return.

**Consequence:** The `return_items.condition` column records what the staff member observed at return time, but does not trigger an automatic bucket transition. A future `rpc_quarantine_to_sellable` or `rpc_write_off_damaged` will handle disposition.

---

## ADR-08 · Idempotency via client_transaction_id + idempotency_key_hash

**Decision:** `UNIQUE(business_id, client_transaction_id)` on `sales`. On duplicate key: if `idempotency_key_hash` matches → return existing `sale_id` (idempotent success). If hash differs → raise `IDEMPOTENCY_CONFLICT`.

**Rationale:** Network retries on a POS device must not create duplicate sales. But a retry with a different payload (accidental reuse of a UUID with different items) is a programming error and must be surfaced, not silently accepted.

---

## ADR-09 · Server-Authoritative Pricing + Stale Price Detection

**Decision:** `rpc_process_sale` fetches `COALESCE(pv.sale_price_override, p.default_sale_price)` from the DB. The client sends `expected_list_price` for stale detection. If client price ≠ DB price → raise `PRICE_CHANGED` (no writes occur).

**Rationale:** The POS app may have a cached price that has since changed. Charging the wrong price silently is a business risk. Raising `PRICE_CHANGED` lets the app refresh its display and ask the cashier to confirm.

---

## ADR-10 · Goods Receipt Reversal Deferred to V2

**Decision:** `rpc_reverse_goods_receipt` is a NOT IMPLEMENTED stub that raises `feature_not_supported`.

**Open questions for V2:**
1. Partial reversal (all lines or per-line selection)?
2. Items partially sold since receipt — how to handle?
3. Supplier credit note workflow (reversal entry, or separate document type)?
4. Cost pool impact when MWA has changed since original receipt.

**V1 workaround:** Owner creates a manual inventory adjustment entry and a manual supplier credit note.

---

## ADR-11 · Consignment Stock

**Status:** UNKNOWN

**Decision pending.** No pilot decision has been made about whether TLC will operate consignment inventory. The current schema cannot model consignment (stock owned by a third party but held in the boutique). This must be resolved before V2 planning.

---

## ADR-12 · Accounting Role

**Status:** DEFERRED

The `user_role` enum does not include an `accounting` role. This was removed from Rev 3 because the pilot stakeholder had not confirmed what an accounting user should and should not be able to see. The `alter type user_role add value 'accounting'` migration is ready to add when the decision is made.

---

## ADR-13 · Security Definer Standard

**Decision:** Every SECURITY DEFINER function must:
1. Include `SET search_path = pg_catalog, public` (prevents search-path hijacking)
2. Derive actor from `auth.uid()` (never from a client parameter)
3. Validate caller's business membership/role as the first check
4. `REVOKE EXECUTE ... FROM PUBLIC`
5. `GRANT EXECUTE ... TO authenticated`

This is a project-wide invariant. Any RPC that does not follow this pattern is a security bug.
