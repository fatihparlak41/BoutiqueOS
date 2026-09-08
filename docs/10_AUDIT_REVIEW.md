# ButikOS — Security & Schema Audit Report

**Version:** Rev 3 · 2026-09-08  
**Scope:** Migrations 001–004 + seed_things_like_crop.sql  
**Status:** Pre-dev-apply gate · CONDITIONALLY FROZEN (pending consignment decision)

---

## 1. Security Definer Function Audit

All SECURITY DEFINER functions must satisfy all 7 columns. Any ✗ is a blocker.

| Function | Caller Role Checked | SET search_path | Uses auth.uid() | Membership Validated | Role Validated | Tenant Validated | REVOKE PUBLIC | GRANT authenticated |
|----------|--------------------|-----------------|-----------------|--------------------|----------------|-----------------|---------------|---------------------|
| `rpc_set_fx_rate` | manager+ | ✓ | ✓ (created_by) | ✓ fn_is_manager_plus | ✓ | ✓ p_business_id | ✓ | ✓ |
| `rpc_confirm_goods_receipt` | manager+ | ✓ | ✓ (confirmed_by) | ✓ fn_is_manager_plus | ✓ | ✓ p_business_id + GR.business_id | ✓ | ✓ |
| `rpc_process_return` | member+ | ✓ | ✓ (processed_by) | ✓ fn_is_member | ✓ (member = any role) | ✓ sale.business_id check | ✓ | ✓ |
| `rpc_ship_transfer` | manager+ | ✓ | ✓ (shipped_by on stock_transfers) | ✓ fn_is_manager_plus | ✓ | ✓ transfer.business_id | ✓ | ✓ |
| `rpc_receive_transfer` | manager+ | ✓ | ✓ (received_by) | ✓ fn_is_manager_plus | ✓ | ✓ transfer.business_id | ✓ | ✓ |
| `rpc_reverse_goods_receipt` | — (stub) | ✓ | — (raises immediately) | — (raises immediately) | — | — | ✓ | ✓ |
| `fn_post_to_cost_pool` | internal | ✓ | n/a (called by SD RPCs only) | n/a | n/a | n/a (caller validates) | ✓ | n/a (not user-callable) |
| `rpc_process_sale` | member+ | ✓ | ✓ (sold_by) | ✓ fn_is_member | ✓ | ✓ | ✓ | ✓ |

**Result: All SD functions PASS audit.**

---

## 2. Direct-Write Audit (13 Tables × 4 Operations)

Policy: `ALLOWED` = client may perform this operation via RLS. `DENIED` = no RLS policy; blocked at DB level.

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|-------|--------|--------|--------|--------|-------|
| `businesses` | ALLOWED (member) | DENIED | ALLOWED (owner only) | DENIED | Owner can update settings |
| `branches` | ALLOWED (member) | DENIED (owner/manager only via future RPC) | ALLOWED (manager+) | DENIED | |
| `inventory_movements` | ALLOWED (member) | DENIED | DENIED | DENIED | INSERT-only ledger; writes via RPCs only |
| `variant_cost_pools` | DENIED (manager+ only) | DENIED | DENIED | DENIED | All writes via fn_post_to_cost_pool (SD) |
| `sales` | ALLOWED (member) | DENIED | DENIED | DENIED | Writes via rpc_process_sale (SD) |
| `sale_items` | ALLOWED (member) | DENIED | DENIED | DENIED | Writes via rpc_process_sale (SD) |
| `sale_item_costs` | DENIED (manager+ only) | DENIED | DENIED | DENIED | Writes via rpc_process_sale (SD) |
| `sale_costs` | DENIED (manager+ only) | DENIED | DENIED | DENIED | Writes via rpc_process_sale (SD) |
| `fx_rates` | ALLOWED (member) | DENIED | DENIED | DENIED | Writes via rpc_set_fx_rate (SD) |
| `supplier_account_entries` | ALLOWED (manager+) | DENIED | DENIED | DENIED | Writes via rpc_confirm_goods_receipt (SD) |
| `returns` | ALLOWED (member) | DENIED | DENIED | DENIED | Writes via rpc_process_return (SD) |
| `return_items` | ALLOWED (member) | DENIED | DENIED | DENIED | Writes via rpc_process_return (SD) |
| `transfer_held_inventory` | ALLOWED (manager+) | DENIED | DENIED | DENIED | Writes via rpc_ship_transfer (SD) |

**Result: No cost-sensitive table is directly writable by any client role.**

---

## 3. Cost Security Verification

Objective: SALES_STAFF must not be able to retrieve `unit_cost_at_sale`, `average_cost`, `last_purchase_cost`, any cost-pool value, or gross margin — **by PostgreSQL enforcement, not frontend filtering**.

| Table | Contains Cost Data | SALES_STAFF SELECT | Enforcement Method |
|-------|--------------------|-------------------|-------------------|
| `sale_item_costs` | unit_cost_at_sale, line_cost | DENIED | RLS: `fn_is_manager_plus(business_id)` |
| `sale_costs` | total_cost, gross_margin | DENIED | RLS: `fn_is_manager_plus(business_id)` |
| `variant_cost_pools` | average_cost_base, total_value_base | DENIED | RLS: `fn_is_manager_plus(business_id)` |
| `goods_receipt_items` | unit_cost, unit_cost_base | ALLOWED (manager+ only) | RLS: `fn_is_manager_plus` |
| `sale_items` | unit_price_at_sale (NOT cost) | ALLOWED (member) | No cost data in this table |

**Result: SALES_STAFF cannot read any cost field through any SELECT path.**

---

## 4. Consignment Status

**Status: UNKNOWN**

The pilot has not made a decision on consignment inventory. The current schema models only owned inventory. Consignment would require:
- A new ownership flag on `inventory_movements` or `variant_cost_pools`
- Consignment supplier liability (different from purchase liability)
- Sale flow that doesn't debit the boutique's cost pool (the stock is not owned)

**This must be resolved before V2 planning begins.**  
Schema is CONDITIONALLY FROZEN pending this answer.

---

## 5. V1 Goods Receipt Reversal — Design Notes

`rpc_reverse_goods_receipt` is a NOT IMPLEMENTED stub (raises `feature_not_supported`).

**Why it is not implemented in V1:**

A confirmed goods receipt has already:
1. Posted stock into `inventory_movements` (sellable bucket)
2. Updated `variant_cost_pools` (MWA recalculated)
3. Created a `supplier_account_entries` debit
4. Possibly been partially or fully sold

Reversing this requires answering four open questions:

**Q1: Partial reversal?**  
Should a reversal be all-or-nothing (all lines reversed) or can individual lines be selectively reversed?

**Q2: Units partially sold?**  
If 5 units were received and 3 have already been sold, can you still reverse the receipt? The cost pool may have changed (further receipts, sales). Full reversal would require unwinding MWA history — mathematically complex.

**Q3: Supplier credit note workflow**  
A reversal creates a credit on the supplier account. Should this be:
- A `return` entry type on `supplier_account_entries`, or
- A separate `supplier_return` document with its own lifecycle?

**Q4: Cost pool impact after MWA drift**  
If the MWA has changed since the original receipt (due to other receipts), reversing the original receipt at the current MWA produces a different result than reversing at the original cost. Which is correct?

**V1 Workaround:**  
Owner creates a manual inventory adjustment (negative) and a manual supplier credit note entry. A formal reversal RPC will be designed in V2 after the pilot provides feedback.

---

## 6. Known Bugs in 004_rpc_posting.sql (Rev 3)

The following column name bugs were identified during schema cross-verification. `004_rpc_posting.sql` must be corrected before the compile test can pass:

| Location | Bug | Correct Value |
|----------|-----|---------------|
| All `inventory_movements` INSERTs | `movement_type` column | `reason` |
| All `inventory_movements` INSERTs | `unit_cost_base`, `total_cost_base` | `unit_cost_snapshot` (only; no `total_cost_base` column) |
| All `inventory_movements` INSERTs | `notes` (plural) | `note` (singular) |
| `rpc_confirm_goods_receipt` | `v_item.quantity_received` | `v_item.quantity` |
| `rpc_confirm_goods_receipt` | `v_item.unit_cost_original` | `v_item.unit_cost` |
| `rpc_confirm_goods_receipt` | `UPDATE gri SET total_cost_original` | Remove — GENERATED column, cannot UPDATE |
| `rpc_confirm_goods_receipt` | `v_receipt.currency` | `v_receipt.invoice_currency` |
| `rpc_confirm_goods_receipt` | `unit_cost_base` pre-checked as populated | Must be computed: `v_item.unit_cost * v_receipt.exchange_rate` |
| `rpc_process_return` | `returns.sale_id` | `original_sale_id` |
| `rpc_process_return` | invented `status`, `processed_at` columns on `returns` | Remove — these columns do not exist |
| `rpc_process_return` | `return_items.disposition` | Remove — column does not exist |
| `rpc_process_return` | Missing `unit_price_at_sale` on `return_items` INSERT | Add — column is NOT NULL |
| `rpc_process_return` | `unit_cost_at_return` on `return_items` | Correct column name: `unit_cost_at_sale` |
| `rpc_ship_transfer` | `transfer_held_inventory.transfer_id` | `stock_transfer_id` |
| `rpc_ship_transfer` | `transfer_held_inventory.quantity_sent` | `quantity` |
| `rpc_ship_transfer` | `transfer_held_inventory.shipped_by`, `.shipped_at` | Remove — columns do not exist |
| `rpc_ship_transfer` | `stock_transfer_lines` UPDATE sets `unit_cost_at_ship`, `carried_total_value_base` | Remove — these columns do not exist on `stock_transfer_lines` |
| `rpc_receive_transfer` | `thi.transfer_id` | `thi.stock_transfer_id` |
| `rpc_receive_transfer` | `thi.quantity_sent` | `thi.quantity` |
| `supplier_account_entries` INSERT | `notes` (plural) | `note` (singular) |
| `supplier_account_entries` INSERT | `v_receipt.currency` | `v_receipt.invoice_currency` |

**Status: NEEDS REVISION before compile test.**

---

## 7. Final Verdict

| Item | Status |
|------|--------|
| 001_schema.sql | ✓ READY |
| 002_schema_cont.sql | ✓ READY |
| 003_schema_pilot.sql | ✓ READY |
| 004_rpc_posting.sql | ✗ NEEDS REVISION (column name bugs above) |
| seed_things_like_crop.sql | ✓ READY |
| 005_verification_tests.sql | ⚠ PARTIAL (behavioral tests A–L not yet added) |
| Compile test | ✗ NOT COMPLETED (blocked on 004 revision) |
| Security Definer audit | ✓ PASS |
| Direct-write audit | ✓ PASS |
| Consignment decision | ✗ UNKNOWN |
| GR Reversal V1 docs | ✓ DOCUMENTED (stub in place) |

**Overall: NEEDS REVISION**  
**Schema freeze: CONDITIONALLY FROZEN**  
**Do NOT apply to real Supabase project.**

Next steps:
1. Fix 004_rpc_posting.sql (all column name bugs above)
2. Run compile test: 000 → 001 → 002 → 003 → 004 from empty DB
3. Apply seed
4. Add behavioral tests A–L to 005
5. Run full test suite; report per-test PASS/FAIL
6. Resolve consignment question with pilot
7. → READY FOR DEV APPLY
