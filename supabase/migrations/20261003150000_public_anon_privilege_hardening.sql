-- ============================================================
-- BoutiqueOS  •  public anon privilege hardening (defense in depth)
-- ============================================================
-- Why: Supabase's default ACLs grant every new public table / view ALL privileges, every
-- sequence SELECT/UPDATE/USAGE and every function EXECUTE to `anon`. Until now the only
-- thing standing between anon and tenant data was RLS — specifically, that every policy
-- calls an RLS helper (fn_is_member, fn_is_manager_plus, …) that anon cannot execute. One
-- future policy written without a helper (USING (true), USING (status = 'active')) would
-- have opened its table to anyone, because the table grant was already there. TRUNCATE is
-- not governed by RLS at all, and v_fx_rates_current is an auto-updatable view.
--
-- After this migration anon holds NO direct privilege on any public table, view or
-- sequence. The public surface is the explicit SECURITY DEFINER RPC allowlist below
-- (owned by postgres, BYPASSRLS, no FORCE RLS — they never needed the anon table grants)
-- plus the public `storefront-images` bucket under its existing storage policy.
--
-- Scope, deliberately narrow (audit of 2026-10-03):
--   * anon only; authenticated table grants are unchanged (separate audit), service_role
--     and ownership untouched;
--   * saas_plans direct SELECT removed: /kayit reads plans through rpc_saas_plans();
--   * product_status_events_seq_seq: no anon / authenticated privilege (identity values
--     are written only inside rpc_product_set_status);
--   * fn_storage_business_id / fn_store_business_id: anon EXECUTE removed (the only storage
--     policy anon reaches, pol_storefront_images_select, tests bucket_id only); the
--     authenticated storage policies keep using them;
--   * trigger functions, pg_trgm functions and the global PUBLIC EXECUTE default are NOT
--     changed here.
--
-- Future objects: default privileges for objects created BY ROLE postgres in schema public
-- (the role every migration of this project runs as — all 82 public relations are owned
-- by postgres) no longer reach anon. Objects created by supabase_admin are not covered;
-- this migration cannot and does not change that role's defaults. Functions still receive
-- PostgreSQL's global PUBLIC EXECUTE default — every function migration keeps its explicit
-- REVOKE … FROM PUBLIC, anon, authenticated and grants only what it means to expose.
--
-- Rollback: GRANT the previous privileges back (see docs/10 §38 for the exact matrix) and
-- re-add the three default-privilege grants. No data is touched.
-- ============================================================

-- ------------------------------------------------------------ tables (53) and views (7)
REVOKE ALL ON TABLE
  public.barcodes, public.branches, public.brands, public.business_invites, public.business_members,
  public.businesses, public.cash_movements, public.cash_registers, public.categories,
  public.customer_sources, public.customers, public.document_sequences, public.fx_rates,
  public.goods_receipt_charges, public.inventory_adjustments, public.inventory_movement_costs,
  public.inventory_movements, public.option_values, public.product_images, public.product_options,
  public.product_price_history, public.product_variants, public.products, public.profiles,
  public.register_session_currency_counts, public.register_sessions, public.reservation_items,
  public.reservations, public.return_item_costs, public.return_items, public.return_reasons,
  public.returns, public.saas_plans, public.sale_costs, public.sale_item_costs, public.sale_items,
  public.sale_payments, public.sales, public.stock_count_lines, public.stock_count_scans,
  public.stock_counts, public.stock_transfer_lines, public.stock_transfers,
  public.supplier_account_entries, public.supplier_payment_allocations, public.supplier_payments,
  public.supplier_return_items, public.supplier_returns, public.suppliers, public.team_audit_log,
  public.transfer_held_inventory, public.variant_cost_pools, public.variant_option_values,
  public.v_fx_rates_current, public.v_reserved_qty, public.v_sale_item_returned,
  public.v_stock_available, public.v_stock_by_bucket, public.v_supplier_balance,
  public.v_supplier_balance_by_currency
FROM anon;

-- ------------------------------------------------------------ sequence
REVOKE ALL ON SEQUENCE public.product_status_events_seq_seq FROM anon, authenticated;

-- ------------------------------------------------------------ storage path helpers
REVOKE EXECUTE ON FUNCTION public.fn_storage_business_id(TEXT), public.fn_store_business_id(TEXT) FROM anon;

-- ------------------------------------------------------------ the public RPC allowlist (exact live signatures)
GRANT EXECUTE ON FUNCTION
  public.rpc_shop_resolve(TEXT),
  public.rpc_shop_home(TEXT, INTEGER),
  public.rpc_shop_products(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT[], BOOLEAN),
  public.rpc_shop_product(TEXT, TEXT),
  public.rpc_shop_availability(TEXT, UUID[]),
  public.rpc_shop_resolve_host(TEXT),
  public.rpc_shop_create_order(TEXT, TEXT, JSONB, JSONB, TEXT),
  public.rpc_shop_order(TEXT, TEXT),
  public.rpc_shop_cancel_order(TEXT, TEXT, TEXT),
  public.rpc_saas_plans()
TO anon;

-- ------------------------------------------------------------ future postgres-owned objects
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- ============================================================
-- END public anon privilege hardening
-- ============================================================
