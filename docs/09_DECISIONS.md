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

---

## ADR-14 · businesses.status is Platform Controlled

**Status:** DECIDED (Phase 3.5G)

**Decision:** `businesses.status` is a platform field. A tenant owner may edit every other
column of their own business row — name, address, phone, email, logo_url, settings — but
may not move `status` in any direction.

**Why:** the status column is what a subscription lapse, a payment failure or an abuse
report will act on. If the tenant can set it back to `active`, the enforcement built in
Phase 3.5A is decorative.

**Mechanism:** RLS cannot compare OLD and NEW, so the rule is the trigger
`trg_businesses_status_guard` (`BEFORE UPDATE OF status ON businesses`). It accepts a
change on exactly two paths:

1. **Audited platform path** — a transaction-local marker naming this business AND an
   active `platform_admins` row for `auth.uid()`. Both halves are required. The marker
   alone is forgeable (`set_config` is unprivileged) and being inside a SECURITY DEFINER
   function proves nothing, since every RPC in this schema is owned by `postgres`; so the
   guard re-derives the caller's identity itself. A platform admin who edits the table
   directly has no marker and is refused, which is what makes the audit row unavoidable.
2. **Break-glass maintenance** — `current_user` is a superuser or BYPASSRLS role
   (`postgres`, `service_role`) and no marker is set. Bootstrap of the first platform
   admin and disaster recovery need this. It is the only unaudited path and it requires
   database credentials; a tenant session runs as `authenticated`, which is neither.

Everything else raises `PLATFORM_MANAGED_FIELD` (SQLSTATE 42501).

**Consequence:** `rpc_platform_set_business_status` is the only application-level way to
change tenant status, and every such change is written to `platform_audit_log`.

---

## ADR-15 · Business Creation and First Owner Must Be Atomic

**Status:** TODO (Phase 8)

The last-owner invariant (Phase 3.5B, `trg_bm_last_owner`) guards a transition: *if* a
business has an active owner, that owner cannot be removed. It deliberately does **not**
require that a business always has one, because a business row can legitimately exist for
a moment before its first membership is written — that is exactly what the pilot seed and
the concurrency fixture do, and blocking it would deadlock onboarding on its first member.

The gap this leaves is that a business can be created and then left ownerless. That is not
a Phase 3.5 blocker (there is no self-service signup yet; businesses are created
out-of-band), but it must be closed when public signup lands.

**Required in Phase 8:** a single SECURITY DEFINER RPC that creates the business row and
its first `owner` membership in one transaction, so no code path can produce an ownerless
business. Once that RPC is the only way in, the invariant can be tightened from
"the last owner cannot be lost" to "every business has an owner".

---

## ADR-16 · Reporting Reads the Operational Records, in the Tenant's Calendar

**Decision (Phase 10B):**
1. There is no reporting ledger. Every report figure is a PostgreSQL aggregate over the
   operational tables (completed sales / items / payments, `sale_item_costs`, returns /
   `return_item_costs`, the inventory ledger, posted goods receipts, customers). One
   bounded `rpc_report_*` per surface returns JSONB; the browser never receives rows to sum.
2. Profit is historical: COGS is the cost captured at sale time, returned COGS the cost
   captured at return time. A report never re-prices old sales with today's cost pool, and
   the stock valuation (current pools) is never used for margin.
3. Days are the tenant's calendar days: `settings.timezone` (IANA, trigger-validated,
   `rpc_business_set_timezone` owner/manager). When absent the platform default
   `Europe/Istanbul` is used and the payload says `timezone_set=false`, which the UI shows
   as "ayarlanmamış — ayarla"; reports are never silently grouped by server UTC.
4. Financial keys (COGS, gross profit, margin, valuation, purchasing, supplier liability,
   payments) exist in the payload only when the RPC established owner/manager rank.
   sales_staff receive units, counts and selling totals under `sales_visibility_scope`;
   stock_staff have the stock report only. `p_business_id` selects the tenant and is
   always re-proven against the membership — it never authorises.
5. Returns are dated by their own instant, not their sale's; an exchange's replacement sale
   counts fully in net sales and the returned goods count in returns, so
   `net_sales − returns_value` is the merchandise that stayed sold.

**Why:** a second ledger drifts from the first and needs its own proofs; the operational
tables already are the proofs. The 366-day bound and the indexes added with the phase keep
the aggregates in the tens of milliseconds at pilot scale and under 0.5 s at 40k sales/year.

---

## ADR-17 · Fashion Intelligence is Rules over Records, Never a Score

**Decision (Phase 11A):**
1. Every intelligence signal is a deterministic rule over the operational records via
   `fn_intel_facts` (supply, first arrival, buckets, holds, window and lifetime sales /
   returns per variant). No model, no prediction, no composite score; each row carries the
   inputs and a sentence built from them ("Son 30 günde 8 adet satıldı, 2 adet müsait kaldı.").
2. Thresholds are RPC parameters with documented defaults, echoed back in the payload and
   shown on the page. Percentages (shares, return rates) appear only above a sample size;
   below it the count is shown and the page says "küçük örneklem" / "Henüz yeterli veri yok".
3. Sell-through is the all-time cohort per variant (no lot tracking) and is named so; stock
   age counts from the first sellable arrival and is not reset by a restock; velocity uses
   active selling days so a newly received product is neither "slow" nor a "bestseller".
4. Replenishment and excess are candidates with explanations — no purchase order, no
   discount, no supplier lead time (not stored, therefore not guessed).
5. Access follows ADR-16: manager+ everything incl. value; sales_staff scoped sales signals
   without money; stock_staff stock-side sections only.

**Why:** a boutique owner acts on a sentence they can check against the shelf; a score they
cannot audit is noise, and with the pilot's sparse history any "trend" would be fiction.

---

## ADR-18 · Purchase Orders Plan, Only Posted Receipts Post

**Decision (Phase 12A):**
1. A purchase order is a commercial planning document. Creating, approving, marking ordered,
   cancelling or closing one never writes an inventory movement, a cost pool change or a
   supplier ledger entry. The Phase 8A goods receipt POST remains the single accounting and
   inventory event; a receipt may reference a PO, the PO never references stock.
2. Received quantities are derived from posted, non-reversed linked receipt items — no
   counters. The receipt POST trigger validates under the PO row lock (variant on the PO,
   total ≤ ordered → `OVER_RECEIPT`, PO open, same supplier) so two receipts cannot
   over-receive; a reversal lowers the received total and the status follows.
3. Expected unit cost is planning information in the PO currency; it is never copied into
   a receipt. A receipt created from a PO carries the remaining quantities and no cost; the
   manager prices what actually arrived, with its own FX snapshot.
4. After approval the commercial terms are frozen; expected date, reference and note stay
   editable. A partly received order is closed with its balance abandoned, not cancelled;
   received / closed / cancelled orders are immutable and never deleted.
5. Roles follow Phase 8A: owner / manager manage the document and see expected cost;
   stock_staff sees the operational document and may create the draft receipt; sales_staff
   has no procurement access. Intelligence only prefills a draft — it never orders.

**Why:** one accounting path keeps stock, cost and liability provable from the ledger alone;
deriving received quantities avoids drifting counters; keeping expected cost out of the
receipt keeps the MWA honest when the invoice differs from the plan.
