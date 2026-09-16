-- ============================================================
-- Phase 10A — customer archive is a manager act
-- ============================================================
-- Live smoke: sales_staff may edit operational customer fields (RLS + column grant), but
-- archiving / restoring a customer (is_active) is not an operational edit. The column stays
-- writable for the row-level path the app uses; the trigger refuses the transition unless the
-- actor is owner/manager. Maintenance sessions (no JWT) are unaffected.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_customer_archive_role()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF NEW.is_active IS DISTINCT FROM OLD.is_active AND auth.uid() IS NOT NULL AND NOT fn_is_manager_plus(NEW.business_id) THEN
    RAISE EXCEPTION 'FORBIDDEN: only owner or manager may archive or restore a customer' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_customer_archive_role BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION fn_customer_archive_role();
