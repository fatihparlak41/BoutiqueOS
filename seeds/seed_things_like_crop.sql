-- ============================================================
-- ButikOS — Seed Data: Things Like Crop  (TLC)
-- Run AFTER all schema migrations (001 → 004) have been applied.
-- Safe to re-run: uses ON CONFLICT DO NOTHING / DO UPDATE.
-- Rev 3  •  2026-09-08
-- ============================================================


-- ============================================================
-- BUSINESS
-- ============================================================

INSERT INTO businesses (name, code, sector, currency, settings)
VALUES (
  'Things Like Crop',
  'TLC',
  'Kadın Giyim',
  'TRY',
  '{
    "allow_cash_refund": false,
    "exchange_window_days": 3,
    "base_currency": "TRY",
    "accepted_currencies": ["TRY","GBP","EUR","USD"],
    "receipt_header": "Things Like Crop",
    "label_template": "default"
  }'::jsonb
)
ON CONFLICT (code) DO UPDATE
  SET settings = businesses.settings || EXCLUDED.settings,
      name     = EXCLUDED.name;


-- ============================================================
-- BRANCH
-- ============================================================

INSERT INTO branches (business_id, name, code, is_default)
SELECT id, 'Things Like Crop Lefkoşa', 'LFT', true
FROM businesses WHERE code = 'TLC'
ON CONFLICT (business_id, code) DO NOTHING;


-- ============================================================
-- PRODUCT OPTIONS
-- ============================================================

INSERT INTO product_options (business_id, name, sort_order)
SELECT b.id, o.name, o.sort_order
FROM businesses b,
(VALUES
  ('Size', 1),
  ('Color', 2),
  ('Cup Size', 3),
  ('Length', 4)
) AS o(name, sort_order)
WHERE b.code = 'TLC'
ON CONFLICT (business_id, name) DO NOTHING;


-- ============================================================
-- OPTION VALUES — Size
-- ============================================================

INSERT INTO option_values (product_option_id, value, sort_order)
SELECT po.id, v.value, v.sort_order
FROM product_options po
JOIN businesses b ON b.id = po.business_id
CROSS JOIN (VALUES
  ('XS',       1),
  ('S',        2),
  ('M',        3),
  ('L',        4),
  ('XL',       5),
  ('XXL',      6),
  ('One Size', 7),
  ('32',       8),
  ('34',       9),
  ('36',      10),
  ('38',      11),
  ('40',      12)
) AS v(value, sort_order)
WHERE b.code = 'TLC' AND po.name = 'Size'
ON CONFLICT (product_option_id, value) DO NOTHING;


-- ============================================================
-- OPTION VALUES — Color (base palette; extend as needed)
-- ============================================================

INSERT INTO option_values (product_option_id, value, sort_order)
SELECT po.id, v.value, v.sort_order
FROM product_options po
JOIN businesses b ON b.id = po.business_id
CROSS JOIN (VALUES
  ('Siyah',    1),
  ('Beyaz',    2),
  ('Krem',     3),
  ('Gri',      4),
  ('Bej',      5),
  ('Kahve',    6),
  ('Lacivert', 7),
  ('Mavi',     8),
  ('Kırmızı',  9),
  ('Pembe',   10),
  ('Yeşil',   11),
  ('Sarı',    12),
  ('Turuncu', 13),
  ('Mor',     14),
  ('Desenli', 15)
) AS v(value, sort_order)
WHERE b.code = 'TLC' AND po.name = 'Color'
ON CONFLICT (product_option_id, value) DO NOTHING;


-- ============================================================
-- OPTION VALUES — Cup Size (for bikini/lingerie)
-- ============================================================

INSERT INTO option_values (product_option_id, value, sort_order)
SELECT po.id, v.value, v.sort_order
FROM product_options po
JOIN businesses b ON b.id = po.business_id
CROSS JOIN (VALUES
  ('A', 1), ('B', 2), ('C', 3), ('D', 4),
  ('DD', 5), ('E', 6)
) AS v(value, sort_order)
WHERE b.code = 'TLC' AND po.name = 'Cup Size'
ON CONFLICT (product_option_id, value) DO NOTHING;


-- ============================================================
-- OPTION VALUES — Length
-- ============================================================

INSERT INTO option_values (product_option_id, value, sort_order)
SELECT po.id, v.value, v.sort_order
FROM product_options po
JOIN businesses b ON b.id = po.business_id
CROSS JOIN (VALUES
  ('Mini',   1),
  ('Midi',   2),
  ('Maxi',   3),
  ('Crop',   4),
  ('Normal', 5)
) AS v(value, sort_order)
WHERE b.code = 'TLC' AND po.name = 'Length'
ON CONFLICT (product_option_id, value) DO NOTHING;


-- ============================================================
-- CATEGORIES
-- ============================================================
-- is_final_sale = true for Bikini and Swimwear (pilot decision:
-- "Bikiniler değişim ve iade kabul edilmiyor")

INSERT INTO categories (business_id, name, slug, sort_order, is_final_sale)
SELECT b.id, c.name, c.slug, c.sort_order, c.is_final_sale
FROM businesses b,
(VALUES
  ('Elbiseler',      'elbiseler',    1,  false),
  ('Üstler',         'ustler',       2,  false),
  ('Crop Toplar',    'crop-toplar',  3,  false),
  ('Korsetler',      'korsetler',    4,  false),
  ('Gömlekler',      'gomlekler',    5,  false),
  ('Bluzlar',        'bluzlar',      6,  false),
  ('T-Shirtler',     't-shirtler',   7,  false),
  ('Etekler',        'etekler',      8,  false),
  ('Şortlar',        'sortlar',      9,  false),
  ('Pantolonlar',    'pantolonlar', 10,  false),
  ('Takımlar',       'takimlar',    11,  false),
  ('Bikiniler',      'bikiniler',   12,  true),   -- Final sale: no exchange/return
  ('Mayo',           'mayo',        13,  true),   -- Final sale: no exchange/return
  ('Dış Giyim',      'dis-giyim',   14,  false),
  ('Aksesuarlar',    'aksesuarlar', 15,  false)
) AS c(name, slug, sort_order, is_final_sale)
WHERE b.code = 'TLC'
ON CONFLICT (business_id, slug) DO UPDATE
  SET is_final_sale = EXCLUDED.is_final_sale,
      sort_order    = EXCLUDED.sort_order;


-- ============================================================
-- CASH REGISTER (default)
-- ============================================================

INSERT INTO cash_registers (business_id, branch_id, name, is_active)
SELECT b.id, br.id, 'Ana Kasa', true
FROM businesses b
JOIN branches br ON br.business_id = b.id AND br.code = 'LFT'
WHERE b.code = 'TLC'
ON CONFLICT (branch_id, name) DO NOTHING;


-- ============================================================
-- END OF SEED FILE
-- ============================================================
-- Notes:
--   - No FX rates seeded: owner enters today's rate manually before first
--     foreign-currency sale via rpc_set_fx_rate()
--   - No default_reservation_hours in settings: duration varies by customer;
--     set explicitly per reservation in the app
--   - No default_tax_rate in settings: not confirmed by pilot (HIGH 21 — removed)
--   - No markup_multiplier: pricing is a UX concern, not schema state
--   - Accounting role: deferred; not seeded here
-- ============================================================
