# ButikOS — Project Overview

**Version:** Rev 3 · 2026-09-08  
**Status:** Schema frozen (conditionally) · Pre-dev-apply gate

---

## What Is ButikOS?

ButikOS is a multi-tenant boutique retail management SaaS built for small-to-medium fashion and apparel boutiques operating in Turkish-speaking markets (Northern Cyprus, Turkey). It handles the full retail loop: goods receipt → inventory → POS sales → returns/exchanges → inter-branch transfers → supplier current account — all with a cost-accounting layer (Moving Weighted Average) that is invisible to sales staff.

---

## Pilot Tenant

**Things Like Crop (TLC)**  
Sector: Kadın Giyim  
Branch: Lefkoşa (LFT)  
Currency: TRY (also accepts GBP, EUR, USD)  
Policy: No cash refunds · Exchange window 3 days · Bikini/Mayo = final sale

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Supabase / PostgreSQL                  │
│                                                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │ 001      │  │ 002      │  │ 003      │  │ 004     │ │
│  │ Core     │  │ Sales /  │  │ FX Rates │  │ Posting │ │
│  │ Schema   │  │ Inventory│  │ Pilot    │  │ RPCs    │ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────┘ │
│                                                           │
│  RLS policies on every table · SECURITY DEFINER RPCs     │
│  Cost split tables (manager+ only)                        │
└─────────────────────────────────────────────────────────┘
              │
    Supabase PostgREST / Auth JWT
              │
┌─────────────────────────┐
│   React / Next.js App   │
│   (not started yet)     │
└─────────────────────────┘
```

---

## Migration Order

| File | Contents |
|------|----------|
| `000_test_harness.sql` | Local test shim only — Supabase auth mock, test helpers |
| `001_schema.sql` | Core entities: businesses, branches, profiles, products, variants, goods receipts, suppliers |
| `002_schema_cont.sql` | Inventory ledger, cost pools, sales, returns, transfers, register sessions, reservations |
| `003_schema_pilot.sql` | FX rates (versioned/immutable), `rpc_set_fx_rate` |
| `004_rpc_posting.sql` | Posting RPCs: confirm GR, process return, ship/receive transfer, reverse GR stub |
| `seed_things_like_crop.sql` | TLC pilot seed: business, branch, options, categories, cash register |

---

## Key Design Principles

1. **Multi-tenant isolation** — `business_id` on every row; cross-tenant composite FKs at DB level.
2. **Immutable ledger** — `inventory_movements` is INSERT-only; signed quantity per bucket (`sellable`, `quarantine`, `damaged`).
3. **Moving Weighted Average (MWA) cost** — computed and stored in `variant_cost_pools` per branch; updated atomically by posting RPCs.
4. **Cost security** — `unit_cost_at_sale`, pool values, gross margin are in separate tables (`sale_item_costs`, `sale_costs`) with manager-only RLS. Sales staff cannot see any cost field.
5. **Server-authoritative pricing** — RPCs fetch price from DB; client `expected_list_price` is validated but never trusted as the price to charge.
6. **Idempotency** — `UNIQUE(business_id, client_transaction_id)` on sales; payload change detection via `idempotency_key_hash`.
7. **FX immutability** — `fx_rates` records are INSERT-only; `rpc_set_fx_rate` supersedes (never updates) old rates.
8. **SECURITY DEFINER hardening** — Every SD function: `SET search_path = pg_catalog, public`; actor = `auth.uid()`; `REVOKE from PUBLIC, GRANT to authenticated`.
9. **Transfer value integrity** — `carried_total_value_base = ABS(value_delta_base)` (exact TRY, not unit × qty).
10. **No direct client mutation** — All accounting and cost mutations go through trusted posting RPCs.

---

## What Is NOT In Scope (V1)

- Login / Auth UI (not started)
- Product catalog UI (not started)
- Goods receipt reversal (`rpc_reverse_goods_receipt` is a NOT IMPLEMENTED stub)
- Accounting/bookkeeping role (deferred — awaiting pilot confirmation)
- TCMB FX API integration (manual entry only)
- Consignment stock (UNKNOWN — no decision made; schema currently cannot model it)
- Partial transfer receipt (V1 requires all lines received together)
- Multi-branch reporting / consolidated views

---

## Repository Structure (Planned)

```
butikos/
├── supabase/
│   └── migrations/
│       ├── 001_schema.sql
│       ├── 002_schema_cont.sql
│       ├── 003_schema_pilot.sql
│       └── 004_rpc_posting.sql
├── seeds/
│   └── seed_things_like_crop.sql
├── tests/
│   ├── 000_test_harness.sql
│   └── 005_verification_tests.sql
└── docs/
    ├── 00_PROJECT_OVERVIEW.md   ← this file
    ├── 01_REQUIREMENTS.md
    ├── 02_DOMAIN_MODEL.md
    └── 09_DECISIONS.md
```
