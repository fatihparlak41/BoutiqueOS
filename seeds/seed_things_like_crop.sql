-- ============================================================
-- BoutiqueOS  •  Seed  •  Things Like Crop (pilot)  •  Rev 3
-- ============================================================
-- Idempotent (fixed UUIDs + ON CONFLICT DO NOTHING). Run as postgres
-- AFTER migrations. Contains ONLY confirmed pilot facts:
--   1 business, 1 branch (LFT), options, categories (Bikini/Mayo final sale),
--   1 cash register. NO products, NO stock, NO users, NO FX rates,
--   NO max_discount_pct (J-4), NO tax/markup/reservation defaults.
-- Users/members are created through Supabase Auth + owner UI (or tests).
-- ============================================================
BEGIN;

INSERT INTO businesses (id, name, code, sector, base_currency, address, status, settings)
VALUES (
  'b0000000-0000-4000-8000-000000000001',
  'Things Like Crop', 'TLC', 'women_fashion_boutique', 'TRY', 'Lefkoşa, KKTC', 'active',
  jsonb_build_object(
    'money_refund_allowed', false,            -- J-2: no money refund (cash/card/bank alike)
    'store_credit_allowed', false,            -- J-2: not enabled until pilot approves
    'exchange_window_days', 3,                -- confirmed: 3-day exchange window
    'accepted_currencies', jsonb_build_array('TRY','GBP','EUR','USD')
  )
) ON CONFLICT (id) DO NOTHING;

INSERT INTO branches (id, business_id, name, code, address, is_default, status)
VALUES ('b1000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
        'Lefkoşa Mağaza', 'LFT', 'Lefkoşa, KKTC', true, 'active')
ON CONFLICT (id) DO NOTHING;

-- Product options
INSERT INTO product_options (id, business_id, name, sort_order) VALUES
  ('c0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001', 'Size',     1),
  ('c0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000001', 'Color',    2),
  ('c0000000-0000-4000-8000-000000000003', 'b0000000-0000-4000-8000-000000000001', 'Cup Size', 3),
  ('c0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-000000000001', 'Length',   4)
ON CONFLICT (id) DO NOTHING;

INSERT INTO option_values (id, business_id, product_option_id, value, sort_order) VALUES
  ('c1000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'XS', 1),
  ('c1000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'S',  2),
  ('c1000000-0000-4000-8000-000000000003', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'M',  3),
  ('c1000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'L',  4),
  ('c1000000-0000-4000-8000-000000000005', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'XL', 5),
  ('c1000000-0000-4000-8000-000000000006', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'STD',6),
  ('c1000000-0000-4000-8000-000000000011', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002', 'Siyah', 1),
  ('c1000000-0000-4000-8000-000000000012', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002', 'Beyaz', 2),
  ('c1000000-0000-4000-8000-000000000013', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002', 'Bej',   3),
  ('c1000000-0000-4000-8000-000000000014', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002', 'Kırmızı', 4),
  ('c1000000-0000-4000-8000-000000000015', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002', 'Lacivert', 5),
  ('c1000000-0000-4000-8000-000000000021', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003', 'A', 1),
  ('c1000000-0000-4000-8000-000000000022', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003', 'B', 2),
  ('c1000000-0000-4000-8000-000000000023', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003', 'C', 3),
  ('c1000000-0000-4000-8000-000000000024', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003', 'D', 4),
  ('c1000000-0000-4000-8000-000000000031', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000004', 'Mini', 1),
  ('c1000000-0000-4000-8000-000000000032', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000004', 'Midi', 2),
  ('c1000000-0000-4000-8000-000000000033', 'b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000004', 'Maxi', 3)
ON CONFLICT (id) DO NOTHING;

-- Categories (Bikiniler / Mayo = final sale: no exchange, no return)
INSERT INTO categories (id, business_id, parent_id, name, slug, sort_order, is_final_sale) VALUES
  ('d0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001', NULL, 'Elbise',      'elbise',      1, false),
  ('d0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000001', NULL, 'Üst Giyim',   'ust-giyim',   2, false),
  ('d0000000-0000-4000-8000-000000000003', 'b0000000-0000-4000-8000-000000000001', NULL, 'Alt Giyim',   'alt-giyim',   3, false),
  ('d0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-000000000001', NULL, 'Takım',       'takim',       4, false),
  ('d0000000-0000-4000-8000-000000000005', 'b0000000-0000-4000-8000-000000000001', NULL, 'Plaj Giyim',  'plaj-giyim',  5, false),
  ('d0000000-0000-4000-8000-000000000006', 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000005', 'Bikiniler', 'bikiniler', 1, true),
  ('d0000000-0000-4000-8000-000000000007', 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000005', 'Mayo',      'mayo',      2, true),
  ('d0000000-0000-4000-8000-000000000008', 'b0000000-0000-4000-8000-000000000001', NULL, 'Aksesuar',    'aksesuar',    6, false)
ON CONFLICT (id) DO NOTHING;

-- Cash register
INSERT INTO cash_registers (id, business_id, branch_id, name, is_active)
VALUES ('e0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
        'b1000000-0000-4000-8000-000000000001', 'Ana Kasa', true)
ON CONFLICT (id) DO NOTHING;

-- Additional pilot option values (name-based, idempotent; business_id filled by trigger)
INSERT INTO option_values (product_option_id, value, sort_order)
SELECT po.id, v.value, v.sort_order
FROM product_options po
CROSS JOIN (VALUES ('XXL',7),('One Size',8),('32',9),('34',10),('36',11),('38',12),('40',13)) AS v(value, sort_order)
WHERE po.business_id = 'b0000000-0000-4000-8000-000000000001' AND po.name = 'Size'
ON CONFLICT (product_option_id, value) DO NOTHING;

INSERT INTO option_values (product_option_id, value, sort_order)
SELECT po.id, v.value, v.sort_order
FROM product_options po
CROSS JOIN (VALUES ('Krem',6),('Gri',7),('Kahve',8),('Mavi',9),('Pembe',10),('Yeşil',11),('Sarı',12),('Turuncu',13),('Mor',14),('Desenli',15)) AS v(value, sort_order)
WHERE po.business_id = 'b0000000-0000-4000-8000-000000000001' AND po.name = 'Color'
ON CONFLICT (product_option_id, value) DO NOTHING;

INSERT INTO option_values (product_option_id, value, sort_order)
SELECT po.id, v.value, v.sort_order
FROM product_options po
CROSS JOIN (VALUES ('DD',5),('E',6)) AS v(value, sort_order)
WHERE po.business_id = 'b0000000-0000-4000-8000-000000000001' AND po.name = 'Cup Size'
ON CONFLICT (product_option_id, value) DO NOTHING;

INSERT INTO option_values (product_option_id, value, sort_order)
SELECT po.id, v.value, v.sort_order
FROM product_options po
CROSS JOIN (VALUES ('Crop',4),('Normal',5)) AS v(value, sort_order)
WHERE po.business_id = 'b0000000-0000-4000-8000-000000000001' AND po.name = 'Length'
ON CONFLICT (product_option_id, value) DO NOTHING;

-- Pilot sub-categories (from pilot analysis) under the top-level groups above
INSERT INTO categories (business_id, parent_id, name, slug, sort_order, is_final_sale)
SELECT 'b0000000-0000-4000-8000-000000000001', c.parent_id, c.name, c.slug, c.sort_order, false
FROM (VALUES
  ('d0000000-0000-4000-8000-000000000002'::uuid, 'Crop Toplar', 'crop-toplar', 1),
  ('d0000000-0000-4000-8000-000000000002'::uuid, 'Korsetler',   'korsetler',   2),
  ('d0000000-0000-4000-8000-000000000002'::uuid, 'Gömlekler',   'gomlekler',   3),
  ('d0000000-0000-4000-8000-000000000002'::uuid, 'Bluzlar',     'bluzlar',     4),
  ('d0000000-0000-4000-8000-000000000002'::uuid, 'T-Shirtler',  't-shirtler',  5),
  ('d0000000-0000-4000-8000-000000000003'::uuid, 'Etekler',     'etekler',     1),
  ('d0000000-0000-4000-8000-000000000003'::uuid, 'Şortlar',     'sortlar',     2),
  ('d0000000-0000-4000-8000-000000000003'::uuid, 'Pantolonlar', 'pantolonlar', 3),
  (NULL::uuid,                                   'Dış Giyim',   'dis-giyim',   7)
) AS c(parent_id, name, slug, sort_order)
ON CONFLICT (business_id, slug) DO NOTHING;

-- Sanity: every policy key fn_setting() will read at posting time must exist
DO $$
DECLARE k TEXT;
BEGIN
  FOREACH k IN ARRAY ARRAY['money_refund_allowed','store_credit_allowed','exchange_window_days','accepted_currencies'] LOOP
    PERFORM fn_setting('b0000000-0000-4000-8000-000000000001', k);
  END LOOP;
  RAISE NOTICE 'seed OK: TLC policy settings readable';
END $$;

COMMIT;
