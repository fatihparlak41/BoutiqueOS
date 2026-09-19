-- Verify: one first invoice (paid) + one renewal (open) → 2 invoices, 1 payment, exactly one activation, snapshots consistent:
-- the paid invoice kept the old catalogue price, the renewal's price is either the old or the new price but equals its own
-- item line, and the catalogue now shows the new price. Then restore the catalogue price (data, not code).
\set ON_ERROR_STOP on
DO $$
DECLARE sub UUID := (SELECT v::uuid FROM zz_bill_ctx WHERE k = 'sub_z'); p0 NUMERIC := (SELECT v::numeric FROM zz_bill_ctx WHERE k = 'price_before');
        ninv INT; npaid INT; nopen INT; npay INT; nact INT; st TEXT; first_sub NUMERIC; ren_sub NUMERIC; ren_item NUMERIC; nissue INT; nrec INT; p_now NUMERIC;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE status = 'paid'), count(*) FILTER (WHERE status = 'open') INTO ninv, npaid, nopen FROM saas_invoices WHERE subscription_id = sub;
  SELECT count(*) INTO npay FROM saas_payments WHERE subscription_id = sub;
  SELECT status::text INTO st FROM business_subscriptions WHERE id = sub;
  SELECT count(*) INTO nact FROM platform_audit_log WHERE action = 'record_payment' AND (payload ->> 'subscription_id')::uuid = sub AND payload ->> 'to' = 'active';
  SELECT count(*) INTO nissue FROM platform_audit_log WHERE action = 'issue_invoice' AND (payload ->> 'subscription_id')::uuid = sub;
  SELECT count(*) INTO nrec FROM platform_audit_log WHERE action = 'record_payment' AND (payload ->> 'subscription_id')::uuid = sub;
  SELECT subtotal INTO first_sub FROM saas_invoices WHERE subscription_id = sub AND status = 'paid';
  SELECT i.subtotal, it.line_total INTO ren_sub, ren_item FROM saas_invoices i JOIN saas_invoice_items it ON it.invoice_id = i.id WHERE i.subscription_id = sub AND i.status = 'open';
  SELECT price_amount INTO p_now FROM saas_plans WHERE code = 'starter';
  IF ninv = 2 AND npaid = 1 AND nopen = 1 AND npay = 1 AND st = 'active' AND nact = 1 AND nissue = 2 AND nrec = 1
     AND first_sub = p0 AND ren_sub = ren_item AND ren_sub IN (p0, p0 + 7) AND p_now = p0 + 7 THEN
    RAISE NOTICE '[PASS] billing races: 2 invoices (1 paid, 1 open), 1 payment, 1 activation, snapshots consistent (renewal at % while catalogue is %)', ren_sub, p_now;
  ELSE
    RAISE NOTICE '[FAIL] billing races: invoices=% paid=% open=% payments=% status=% activations=% issues=% records=% first=% renewal=% item=% catalogue=%', ninv, npaid, nopen, npay, st, nact, nissue, nrec, first_sub, ren_sub, ren_item, p_now;
  END IF;
END $$;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000011","role":"authenticated"}', true);
SELECT rpc_platform_upsert_plan('starter', 'BoutiqueOS Starter', NULL, 'annual', (SELECT v::numeric FROM zz_bill_ctx WHERE k = 'price_before'), 'USD', true, 10) IS NOT NULL AS price_restored;
COMMIT;
