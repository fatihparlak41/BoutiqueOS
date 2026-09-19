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

---

## ADR-19 · A Business Exists Only After Platform Approval, With Its Owner

**Decision (Phase 13A):**
1. Public registration creates an Auth account and nothing else. The business the
   registrant described waits in the signup metadata until the address is confirmed; the
   application itself (`business_applications`) is written by a confirmed user through one
   RPC, one open application per person, replayed on a double submit. Rejected and
   withdrawn applications stay as history.
2. The pending state lives in the application, never in `businesses`. `business_status`
   keeps active / suspended / cancelled; a business row is created only by
   `rpc_platform_approve_application`, in one transaction with its first owner membership,
   its "Merkez" branch, its default settings, a pending subscription and the audit row.
   There is never an active business without an owner and never a half-created tenant;
   a retry or a second administrator replays the first approval.
3. Plans are data (`saas_plans`): code, interval, amount, currency, active flag. No price
   is written in code; the registration page renders the catalogue. `business_subscriptions`
   is a commercial record separate from POS money: pending at approval, activated by the
   platform by hand in 13A (period from the plan interval), never touching tenant status.
   Provider fields exist and stay empty until the billing phase.
4. Platform authority stays a separate surface: every `rpc_platform_*` proves the platform
   role inside the database; status changes keep using the audited 3.5G RPC; no tenant
   RLS policy grants anything via the platform role; the console 404s for tenants.
5. Tenant entry is unchanged for members. Only the zero-membership branch asks one extra
   question (`rpc_my_onboarding`) to send the visitor to the waiting page, the safe status
   page, the console or the application form.

**Why:** the tenant schema must never hold an orphan; putting the wait in the application
keeps every existing "active business" invariant and every RLS policy exactly as it was,
and an audited, idempotent approval is the only door into the multi-tenant space.

## ADR-20 · SaaS Billing is a Manual Ledger of Its Own; Payment Activates, Nothing Suspends

**Decision (Phase 13B):**
1. SaaS billing lives in its own tables (`saas_invoices`, `saas_invoice_items`,
   `saas_payments`, `saas_invoice_sequences`, `platform_settings`) and never touches
   `sales`, `sale_payments`, register sessions, `cash_movements`, supplier liabilities or
   any tenant inventory/accounting table. Money is `money2` (NUMERIC(12,2)), computed in
   SQL only; every row carries an explicit currency.
2. An invoice is a snapshot: plan code/name/interval, the catalogue price at issue time,
   the period (calendar interval: `+1 month` / `+1 year`, never 30/365 days), tax under the
   documented policy `none_unconfigured` (0, no VAT inferred from the country), due date
   from `platform_settings.invoice_due_days`. A later plan-price change never rewrites an
   issued invoice; the next invoice uses the then-current catalogue price (no grandfathering).
   The document is an "abonelik ödeme özeti", never called a legal tax invoice.
3. Exactly one live (non-void) invoice per `(subscription, period_start)` and one OPEN
   invoice per subscription at a time; issuing is idempotent (replay of the open one); a
   renewal is issued only after the previous invoice is paid; numbering `BOS-YYYY-NNNNNN`
   comes from a per-year sequence row locked in the transaction and is a reference, not an
   authorisation.
4. There is no payment provider. Money arrives outside the app (bank transfer / cash /
   other manual); a platform admin records it with a reference. `(invoice, reference)` is
   unique, so the same bank line recorded twice — by two admins or a retry — is one payment.
   Overpayment is refused (no credit balance is invented); a partial payment is recorded
   and the invoice stays open. A FULL payment settles the invoice and, in the same
   transaction, activates / re-activates the subscription for the invoiced period
   (`starts_at` from the first period, `ends_at = period_end`). Manual activation without
   a paid invoice no longer exists (`USE_PAYMENT`).
5. Paid and void invoices are immutable and issued documents, items and payments are
   never deleted (triggers). Void keeps the row with actor and reason; a partially paid
   invoice cannot be voided. Provider columns exist, stay NULL and are constrained to NULL.
6. Overdue is derived at read time (`open AND due_at < now()`); nothing depends on a job.
   `rpc_platform_billing_sweep`, run by a platform admin, may materialise `past_due` for an
   overdue open invoice and cancel a subscription whose scheduled end has passed — and does
   nothing else. `business.status`, `subscription.status` and `invoice.status` remain three
   separate facts; a past-due subscription does not suspend the business (grace days are
   data in `platform_settings`, displayed, not enforced). Cancellation is `at_period_end`
   (paid period kept, renewals refused, materialised by the sweep) or `immediate` (refused
   while an invoice is open); no prorated refund.
7. The owner reads own billing through one owner-only RPC (`rpc_my_billing`); managers and
   staff have no SaaS billing surface; tenants hold no privilege on the ledger tables; the
   owner page carries no pay button — it says the platform will share payment details and
   activate after the money arrives.

**Why:** the platform must be able to bill and account for tenants before any card
processor exists, without ever mixing SaaS money with boutique money, without a document
that can change after it was issued, and without a job or a status coupling that could
lock a shop out of its own data by accident.

## ADR-21 · One Catalogue, an Explicit Publish Switch, a Read-Only Public Boundary

**Decision (Phase 14A):**
1. BoutiqueOS stays the only catalogue. The public storefront (`/shop/[slug]`) reads
   products, variants, options, images, price and availability from the operational tables
   through explicitly shaped, read-only, anon-callable RPCs (`rpc_shop_resolve`, `_home`,
   `_products`, `_product`, `_availability`, `_resolve_host`). `anon` gets no table row:
   the operational tables stay behind membership RLS whose helpers anon may not even
   execute, and the RPCs return only public fields — never SKU, barcode, cost, supplier,
   notes, internal ids beyond the variant id a cart line needs, or a private storage path.
2. Publishing is a decision, not a side effect of being active: `products.web_published`
   (+ `web_title`, `web_description`, `web_slug`, `web_featured`, `web_sort_order`) and
   `product_variants.web_enabled`. Publishing needs an active product, at least one active
   web-enabled variant and a selling price above zero; stock is not required (a published
   product may read "Tükendi"). A product that stops being active is unpublished by trigger
   and is not republished by itself.
3. Web price is the current selling price (`COALESCE(variant override, product default)`).
   There is no second price list; a web-only price is a later decision.
4. Public availability is `sellable ledger − active, unexpired holds` at the storefront's
   fulfillment branch (its configured branch, else the default one), shown as a state
   (in_stock / low / sold_out with a merchant-set threshold) or, when the merchant chooses,
   the exact number. Damaged and quarantine buckets never count; on-hand totals, cost and
   MWA are never exposed. Availability is re-read on every request and by the cart.
5. Images: the private `product-images` bucket stays private and signed. A published image
   is a copy in the public `storefront-images` bucket at
   `store/<business>/products/<product>/<image>.<ext>`, recorded in
   `product_images.public_path`; the copy is made by the merchant's own session under the
   bucket's storage policies (manager+, own tenant). Only `product_main`, `product_gallery`
   and `variant` roles may carry a public path (CHECK + trigger); `label_tag` and
   `receiving_proof` can never be published. Public URLs need no signing and are cacheable.
6. Storefront settings are one row per business (`storefronts`): enabled, platform-unique
   slug (the public URL), store name, tagline, announcement, about, Instagram, WhatsApp,
   contact, fulfillment branch, stock display, threshold. `storefront_domains` and
   `rpc_shop_resolve_host` are the custom-domain foundation only — no DNS automation, and
   no host is routed in 14A. `/shop/*` is excluded from the auth middleware: no session, no
   redirect, no Auth round trip per public request.
7. The cart is browser state for ONE store (`localStorage`, `bos_cart:<slug>`), capped at
   20 lines × 10 units, re-checked against live availability on every visit. It reserves
   nothing and creates no movement — CART ≠ RESERVATION; a hold is a checkout/order concern
   of a later phase. There is no checkout, no payment, no customer account; the cart page
   hands the basket to the boutique (WhatsApp / Instagram / e-mail).
8. Public catalogue copy is cached briefly (store 120 s, home/listing 60 s, product 300 s)
   under the tag `shop:<slug>` and dropped by tag on every publish / settings change;
   availability is never cached.

**Why:** the merchant must never maintain a second catalogue, a customer must never see an
operational fact, and a public page must never depend on a session — while the private
image store, the ledger and the reservation rules stay exactly as they are.

## ADR-22 · An Online Order Is an Orchestration Document, Never a Second Ledger

**Decision (Phase 14B):**
1. A guest checkout produces an **order request** (`storefront_orders` + frozen
   `storefront_order_items` + append-only `storefront_order_events`), created by the one
   anon-callable write RPC `rpc_shop_create_order` in **one transaction with its hold**: the
   hold is an ordinary Phase 10A reservation (`reservations.storefront_order_id`, `source
   online`, guest `hold_name`, no CRM customer), placed by `fn_reservation_hold` under the
   same pool locks the POS uses. The order never decrements inventory, never writes cost,
   COGS, payment or a sale row, and is never counted by any report.
2. Prices, totals and availability are server-authoritative: the browser sends variant ids
   and quantities; `unit_price` in the request is ignored, the snapshot is written from
   `fn_web_price`, and `total = subtotal − discount_total` is a CHECK. Limits: 1..10 per
   line, ≤ 30 units, an idempotency key of 32..128 chars; the same key on the same store
   replays the same order and token (`UNIQUE (storefront_id, idempotency_key_hash)`).
3. Identity: `WEB-YYYY-NNNNNN` (`fn_next_sequence(biz,'WEB')`) is a label, not an
   authorization. The customer's only credential is a 64-hex tracking token derived from
   the idempotency key and the store (`sha256('token:'||key||':'||storefront_id)`); only
   `sha256(token)` is stored (`tracking_token_hash`, UNIQUE). Neither key nor token is ever
   stored or logged. Reads (`rpc_shop_order`) and customer cancellation
   (`rpc_shop_cancel_order`, pending only) need slug + token; the order number, a token on
   another store or a wrong token yield nothing.
4. Status is a small state machine owned by RPCs: `pending_confirmation → confirmed →
   ready → completed`, plus `cancelled` (customer while pending; owner/manager with a
   reason until completed) and `expired`. `fn_online_order_guard` freezes the snapshot
   (`ORDER_SNAPSHOT_LOCKED`), refuses deletes (`ORDER_RETAINED`), refuses any move out of a
   final state (`ORDER_FINAL`) and lets `converted_sale_id` be written only by the POS
   conversion (`ORDER_SALE_ONLY_BY_POS`); items and events are frozen by trigger.
5. Expiry is **derived, not scheduled**: the hold's `expires_at` (`order_hold_minutes` per
   storefront, 30 min..7 days, restarted on confirmation) is what frees the unit —
   `fn_reserved_qty` already ignores lapsed holds, so availability returns without any
   job. Reads compute `expired` on the fly (`fn_online_order_public_status`);
   `rpc_online_orders_sweep` (run on merchant list load) only materialises that fact.
   `rpc_online_order_rereserve` (manager+) is the one way back: a fresh hold, stock
   re-checked under lock, the old hold kept as history. The **current hold** of an order is
   always the active one, else the newest (`fn_online_order_reservation`); nothing may
   look at "all holds of an order" (20260919190000 fixed the sweep and the replay branch
   that did).
6. POS conversion is the only place a sale is bound to an order:
   `rpc_pos_complete_online_order(order, register_session, payments, client_transaction_id,
   …)` builds the item list from the order (quantity from the order, price =
   `LEAST(order price, current list price)`, so a price rise is honoured and a price drop
   is passed on) and runs the **existing** sale core with `p_reservation_id` = the hold —
   session, payment rule, stock, historical COGS and reservation fulfilment are unchanged
   Phase 9A/10A code. The same transaction marks the order `completed` and writes the
   `converted` + `completed` events. Retries with the same `client_transaction_id`, or any
   attempt on a completed order, replay the one sale; a cancelled or lapsed order converts
   nothing. The terminal pins the lines (no add / remove / reprice).
7. Roles: customers touch only `rpc_shop_*` (anon has no row on any order table). Owner and
   manager confirm, re-reserve, cancel (reason required) and convert; `sales_staff` sees
   the queue, marks ready and converts at the POS; `stock_staff` has no access at all
   (PII). Every transition is an event with actor type customer / tenant / system.
8. Copy is honest and fulfilment is store pickup only: "Sipariş talebiniz alındı", the hold
   deadline and the pickup branch; never "ödemeniz tamamlandı". No online payment
   provider, no shipping, no customer account, no CRM row is created by a checkout. Public
   order pages are `noindex`, uncached and outside the auth middleware.

**Why:** the boutique already has the truth of stock, cost and money in the ledger, the
reservation engine and the POS sale; an online order must orchestrate those and leave no
second copy that could disagree with them.
