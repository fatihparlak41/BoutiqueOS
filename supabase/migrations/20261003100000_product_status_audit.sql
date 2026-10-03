-- ============================================================
-- BoutiqueOS  •  TLC pilot integrity patch  •  audited product status
-- ============================================================
-- Until now products.status moved through a plain table UPDATE (archive button, edit
-- form) under the 6A manager+ policy. Nothing recorded who archived or restored a
-- product, when, or why (docs/14 §C: two TLC products were archived with only
-- updated_at left behind).
--
-- After this migration a status change has exactly one application path:
--   rpc_product_set_status(product, target, reason)  owner/manager, row lock,
--   one product_status_events row + the status UPDATE in the same transaction.
--
-- Lifecycle (unchanged, no new state):  draft → active | archived,
--   active → archived, archived → active.  Nothing returns to draft: draft is the
--   state a product is born in, "not on sale any more" is archived.
-- Same-state requests are an idempotent no-op (changed=false, no event) so a retry or
-- a double click never writes a second status effect.
--
-- Why a dedicated table and not team_audit_log / platform_audit_log: team_audit_log is
-- the closed whitelist of membership facts (target_user_id/invite), platform_audit_log
-- is platform authority unreadable by tenants. Status history of a product is a domain
-- event like storefront_order_events — append-only, one table, no generic framework.
--
-- Guard: RLS cannot compare OLD and NEW, so trg_products_status_guard
-- (BEFORE UPDATE OF status) accepts a change only when the product's LATEST event was
-- written in the CURRENT transaction (txid) for exactly this OLD → NEW. Tenants cannot
-- insert events (no grant), so the audit row is unavoidable; there is no set_config
-- marker to forge. "Latest" matters: once the RPC has applied an event the row sits at
-- its to_status, and since from <> to the same event can never authorise a second
-- change, not even later in the same transaction. Break-glass maintenance (superuser / BYPASSRLS session, as 3.5G) stays
-- possible and is the only unaudited path; a tenant session runs as `authenticated`.
--
-- Historical rows are not back-filled: no event is invented for earlier changes.
-- Rollback: drop the trigger, the RPC, the guard functions and the table. No product row
-- is rewritten by this migration.
-- ============================================================

CREATE TABLE product_status_events (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seq            BIGINT GENERATED ALWAYS AS IDENTITY,   -- write order (now() is constant in a transaction)
  business_id    UUID NOT NULL REFERENCES businesses(id),
  product_id     UUID NOT NULL,
  from_status    product_status NOT NULL,
  to_status      product_status NOT NULL,
  reason         TEXT CHECK (reason IS NULL OR (length(reason) BETWEEN 1 AND 500)),
  actor_user_id  UUID NOT NULL REFERENCES profiles(id),
  occurred_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- binds the event to the transaction that changes the row (read by the guard only)
  xact_id        BIGINT NOT NULL DEFAULT txid_current(),
  CHECK (from_status <> to_status),
  FOREIGN KEY (business_id, product_id) REFERENCES products (business_id, id)
);
CREATE INDEX ix_product_status_events_product ON product_status_events (product_id, seq DESC);
CREATE INDEX ix_product_status_events_business ON product_status_events (business_id, occurred_at DESC);

ALTER TABLE product_status_events ENABLE ROW LEVEL SECURITY;
-- manager+ read, like the other audit trails; no write policy: the RPC is the only writer
CREATE POLICY pol_pse_select ON product_status_events FOR SELECT USING (fn_is_manager_plus(business_id));
REVOKE ALL ON product_status_events FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON product_status_events FROM anon, authenticated;
GRANT SELECT ON product_status_events TO authenticated;

CREATE OR REPLACE FUNCTION fn_product_status_events_frozen()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE: product status events are never changed or deleted' USING ERRCODE = '55000';
END $$;
REVOKE EXECUTE ON FUNCTION fn_product_status_events_frozen() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_product_status_events_frozen BEFORE UPDATE OR DELETE ON product_status_events
  FOR EACH ROW EXECUTE FUNCTION fn_product_status_events_frozen();

-- ------------------------------------------------------------ guard
-- Definer helper so the guard sees the event regardless of the caller's RLS.
CREATE OR REPLACE FUNCTION fn_product_status_event_in_tx(p_product_id UUID, p_from product_status, p_to product_status)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE((SELECT e.xact_id = txid_current() AND e.from_status = p_from AND e.to_status = p_to
                     FROM product_status_events e
                    WHERE e.product_id = p_product_id
                    ORDER BY e.seq DESC LIMIT 1), false);
$$;
REVOKE EXECUTE ON FUNCTION fn_product_status_event_in_tx(UUID, product_status, product_status) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_guard_product_status()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_cur BOOLEAN; v_sess BOOLEAN;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- 1. audited path: the product's latest event is this change, written in this transaction
  IF fn_product_status_event_in_tx(NEW.id, OLD.status, NEW.status) THEN
    RETURN NEW;
  END IF;

  -- 2. break-glass maintenance (database credentials only)
  SELECT COALESCE(bool_or(rolsuper OR rolbypassrls), false) INTO v_cur  FROM pg_roles WHERE rolname = current_user;
  SELECT COALESCE(bool_or(rolsuper OR rolbypassrls), false) INTO v_sess FROM pg_roles WHERE rolname = session_user;
  IF v_cur AND v_sess THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'USE_RPC: products.status changes only through rpc_product_set_status (product %, % -> %)',
    NEW.id, OLD.status, NEW.status USING ERRCODE = '42501';
END $$;
REVOKE EXECUTE ON FUNCTION fn_guard_product_status() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_products_status_guard BEFORE UPDATE OF status ON products
  FOR EACH ROW EXECUTE FUNCTION fn_guard_product_status();

-- ------------------------------------------------------------ rpc_product_set_status (owner/manager)
CREATE OR REPLACE FUNCTION rpc_product_set_status(
  p_product_id UUID, p_status product_status, p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_biz UUID; p products; v_reason TEXT; v_event UUID;
BEGIN
  IF p_status IS NULL THEN RAISE EXCEPTION 'INVALID_STATUS: target status is required' USING ERRCODE = '22023'; END IF;

  -- tenant and role first, so a foreign caller never takes a lock on another tenant's row
  SELECT business_id INTO v_biz FROM products WHERE id = p_product_id;
  IF v_biz IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: product %', p_product_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager']::user_role[]);

  SELECT * INTO p FROM products WHERE id = p_product_id FOR UPDATE;

  -- retry / double click: nothing to do, nothing recorded
  IF p.status = p_status THEN
    RETURN jsonb_build_object('product_id', p.id, 'previous_status', p.status, 'status', p.status,
                              'changed', false, 'event_id', NULL);
  END IF;

  IF p_status = 'draft' OR NOT (
       (p.status = 'draft'    AND p_status IN ('active', 'archived'))
    OR (p.status = 'active'   AND p_status = 'archived')
    OR (p.status = 'archived' AND p_status = 'active')) THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: product % cannot go from % to %', p.id, p.status, p_status USING ERRCODE = '55000';
  END IF;

  v_reason := NULLIF(left(trim(p_reason), 500), '');

  INSERT INTO product_status_events (business_id, product_id, from_status, to_status, reason, actor_user_id)
  VALUES (p.business_id, p.id, p.status, p_status, v_reason, v_actor)
  RETURNING id INTO v_event;

  UPDATE products SET status = p_status, updated_at = now() WHERE id = p.id;

  RETURN jsonb_build_object('product_id', p.id, 'previous_status', p.status, 'status', p_status,
                            'changed', true, 'event_id', v_event);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_product_set_status(UUID, product_status, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_product_set_status(UUID, product_status, TEXT) TO authenticated;

-- ============================================================
-- END product status audit
-- ============================================================
