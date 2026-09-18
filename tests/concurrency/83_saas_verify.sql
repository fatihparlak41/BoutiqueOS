-- Verify: app_x approved once → exactly one business, one owner membership, one subscription, one approval audit row
-- (the second admin's attempt left no trace of a second tenant); applicant Y has exactly one pending application.
\set ON_ERROR_STOP on
DO $$
DECLARE st TEXT; biz UUID; nb INT; nm INT; ns INT; na INT; ny INT; nby INT;
BEGIN
  SELECT status::text, business_id INTO st, biz FROM business_applications WHERE id = (SELECT v FROM zz_saas_ctx WHERE k='app_x');
  SELECT count(*) INTO nb FROM businesses WHERE name LIKE 'ZZ Race Butik %';
  SELECT count(*) INTO nm FROM business_members WHERE business_id = biz;
  SELECT count(*) INTO ns FROM business_subscriptions WHERE business_id = biz;
  SELECT count(*) INTO na FROM platform_audit_log WHERE action = 'approve_application' AND target_application_id = (SELECT v FROM zz_saas_ctx WHERE k='app_x');
  SELECT count(*) INTO ny FROM business_applications WHERE applicant_user_id = 'dddddddd-0000-4000-8000-000000000002';
  SELECT count(*) INTO nby FROM business_members WHERE user_id = 'dddddddd-0000-4000-8000-000000000002';
  IF st = 'approved' AND biz IS NOT NULL AND nb = 1 AND nm = 1 AND ns = 1 AND na = 1 AND ny = 1 AND nby = 0 THEN
    RAISE NOTICE '[PASS] saas races: one business, one owner, one subscription, one audit row; applicant Y has one pending application';
  ELSE
    RAISE NOTICE '[FAIL] saas races: status=% biz=% businesses=% members=% subs=% audit=% y_apps=% y_members=%', st, biz, nb, nm, ns, na, ny, nby;
  END IF;
END $$;
