-- ============================================================
-- Drop the Rev 3 inventory count stubs, superseded by the Phase 7A stock count engine
-- ============================================================
-- Audit (DEV, 2026-09-15): inventory_counts / inventory_count_lines held 0 rows, had no
-- RPC, no view, no function body referencing them, no incoming foreign key, no app or
-- test code path; only their own policies, the business_id trigger and the
-- inventory_count_status enum (used by that one column) pointed at them. Rows never
-- existed, so nothing is lost. Forward-only; the Rev 3 migration files stay untouched.
-- ============================================================
DROP TABLE inventory_count_lines;
DROP TABLE inventory_counts;
DROP TYPE inventory_count_status;
