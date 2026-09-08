# ButikOS — Requirements

**Version:** Rev 3 · 2026-09-08  
**Pilot:** Things Like Crop (TLC) · Lefkoşa

---

## Business Requirements

### BR-01 · Multi-Tenant Isolation
Each boutique (business) is fully isolated. No user from Business A can read or modify any data belonging to Business B. Isolation is enforced at the PostgreSQL row-level (RLS + composite FKs), not by application code alone.

### BR-02 · Role-Based Access
Four roles with strictly decreasing privilege:

| Role | Can do |
|------|--------|
| `owner` | Everything including role management, business settings |
| `manager` | Goods receipts, FX rates, transfers, discounts > staff limit, returns, cost visibility |
| `sales_staff` | POS sales, exchanges within policy, reservations |
| `stock_staff` | Goods receipt entry (draft), stock counts, label printing |

### BR-03 · Inventory Ledger
Stock is tracked as an immutable signed ledger (`inventory_movements`). Physical location of stock is represented by bucket:
- `sellable` — available for sale
- `quarantine` — returned, pending inspection
- `damaged` — written off or awaiting disposal

In-transit stock (between branches) is NOT in any bucket; it lives in `transfer_held_inventory` until received.

### BR-04 · Cost Accounting (Moving Weighted Average)
Every unit has a TRY-denominated cost tracked at the (business, branch, variant) level via `variant_cost_pools`. Cost is computed as Moving Weighted Average (MWA) on each goods receipt. Cost is NEVER read from a client payload or from `product_variants`.

### BR-05 · Cost Visibility Restriction
`SALES_STAFF` must be prevented **by PostgreSQL** from reading:
- Unit cost at time of sale
- Average / last purchase cost
- Supplier cost, cost-pool value, gross margin

This is enforced via table-level RLS on `sale_item_costs`, `sale_costs`, `variant_cost_pools`. Frontend filtering is not sufficient.

### BR-06 · Foreign Currency Support
TLC accepts GBP, EUR, USD in addition to TRY. Payment amounts are recorded in the tendered currency. The TRY base amount is computed from the daily FX rate set by the owner/manager. FX rates are immutable — a correction inserts a new record and supersedes the old one.

### BR-07 · No Cash Refunds (TLC-specific)
`allow_cash_refund = false` in TLC business settings. The database layer (`rpc_process_return`) enforces this — it cannot be bypassed by app code.

### BR-08 · Exchange Window
Returns/exchanges are only accepted within `exchange_window_days` (default 3) of the original sale date. Enforced at DB level by `rpc_process_return`.

### BR-09 · Final-Sale Categories
Categories marked `is_final_sale = true` (Bikiniler, Mayo) cannot be returned or exchanged. Enforced by `rpc_process_return` checking `categories.is_final_sale`.

### BR-10 · Idempotent POS Transactions
Network retries on the POS must not create duplicate sales. `client_transaction_id` is unique per business. Sending the same ID with a different payload returns `IDEMPOTENCY_CONFLICT`.

### BR-11 · Server-Authoritative Pricing
The price charged to the customer comes from the database (`products.default_sale_price` or `product_variants.sale_price_override`), never from the client. The client sends `expected_list_price` for stale-price detection; if it doesn't match the DB price, the RPC raises `PRICE_CHANGED`.

### BR-12 · Inter-Branch Transfers
Stock can be transferred between branches. The exact TRY cost value is carried without rounding (`carried_total_value_base`). V1: no partial receipt — all lines must be received together.

### BR-13 · Reservations
Customers can reserve stock for a configurable duration. Reserved units are unavailable for ordinary sales until the reservation expires or is converted. Conversion of a reservation to a sale is allowed even when it is the last unit.

### BR-14 · Supplier Current Account
Every goods receipt creates a supplier liability entry in the original invoice currency. Running balance is the sum of `amount_base` (TRY equivalent). Direct client INSERT to `supplier_account_entries` is blocked by RLS.

### BR-15 · Register Session Reconciliation
Each shift has a register session with opening cash count and closing count. Cash movements are recorded per transaction. Discrepancies are visible at close.

---

## Non-Functional Requirements

### NFR-01 · PostgreSQL / Supabase
Schema must run on Supabase (PostgreSQL 15+). No proprietary extensions beyond `uuid-ossp` and `pg_trgm`.

### NFR-02 · RLS on All Tables
Every table has `ENABLE ROW LEVEL SECURITY`. No table is left unsecured.

### NFR-03 · Posting Functions Only
No client may directly INSERT/UPDATE/DELETE on accounting or cost tables. All such mutations go through SECURITY DEFINER RPCs.

### NFR-04 · Deadlock Prevention
All multi-row locking operations acquire locks in deterministic order (`variant_id ASC`).

### NFR-05 · No Application-Layer Cost Logic
Cost pool updates, MWA calculation, and cost pool debit/credit must be done inside PostgreSQL functions — never in application code.

### NFR-06 · Audit Trail
`inventory_movements`, `fx_rates`, `supplier_account_entries` are INSERT-only historical ledgers. No UPDATE or DELETE is permitted via RLS.

### NFR-07 · Test Coverage
All behavioral rules in BR-01 through BR-15 must have corresponding executable SQL tests in `005_verification_tests.sql` before the schema is applied to production.
