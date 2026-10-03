-- Verify: archived once, exactly one audit event (A's), then clean up nothing (db_fresh resets).
SELECT v AS product FROM zz_pst_ctx WHERE k = 'product' \gset
SELECT CASE WHEN (SELECT status::text FROM products WHERE id = :'product') = 'archived'
             AND (SELECT count(*) FROM product_status_events WHERE product_id = :'product') = 1
             AND (SELECT reason FROM product_status_events WHERE product_id = :'product') = 'yarış A'
            THEN '[PASS] archived once, one event (session A)'
            ELSE '[FAIL] status=' || (SELECT status::text FROM products WHERE id = :'product')
                 || ' events=' || (SELECT count(*) FROM product_status_events WHERE product_id = :'product') END AS verdict;
