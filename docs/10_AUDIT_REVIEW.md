# BoutiqueOS — Rev 3 Schema & Security Audit

**Sürüm:** Rev 3 · 2026-09-08
**Kapsam:** `supabase/migrations/20260908000001..04`, `seeds/seed_things_like_crop.sql`, `tests/000_test_harness.sql`, `tests/005_verification_tests.sql`, `tests/concurrency/*`
**Durum:** **BACKEND GATE KAPANDI** · DEV Supabase'e uygulandı · **Frontend Faz 1 DOĞRULANDI**
(2026-09-08) · **Frontend Faz 2 ÜRÜN KATALOĞU DOĞRULANDI** (2026-09-09) ·
**Frontend Faz 3 TEDARİKÇİLER + MAL KABUL + STOK DOĞRULANDI** (TRY manuel DEV smoke, 2026-09-09;
non-TRY FX ve rol smoke DEFERRED) · Sıradaki modüller başlamadı

> Bu rapordaki her bulgu **statik incelemeye** dayanır (kod okuma + `tools/lint_sql.py` + audit betikleri).
> Hiçbir SQL henüz bir PostgreSQL örneğinde çalıştırılmadı. "PASS" ifadesi bu belgede **yoktur**;
> yalnızca "statik olarak tutarlı" (S-OK) veya "açık" (OPEN) vardır. Rev 2 raporundaki
> koşulmamış "PASS" hatası tekrarlanmıyor. Gerçek sonuç `tests/results/last_run.log` ile gelir.

---

## 0. Rev 2 → Rev 3 ne değişti (özet)

| Rev 2 defekti (11_REV3_PREFLIGHT_REPORT) | Rev 3 çözümü | Kanıt |
|---|---|---|
| `rpc_process_sale` lock bloğu derlenmiyor (`JOIN LATERAL (INSERT…)`) | `fn_lock_pools`: upsert + `ORDER BY variant_id FOR UPDATE`; satış çekirdeği `fn_sale_core` iki geçişli (validate → write) | 004 |
| ~20 kolon/enum uyumsuzluğu | INSERT kolon listeleri, enum literalleri, fonksiyon imzaları `tools/lint_sql.py` ile 001–004+seed+tests arasında çapraz kontrol: **0 hata** | §6 |
| Harness'ta `authenticated` rolü yok | Harness `anon/authenticated/service_role` + Supabase-eşdeğeri default privileges | 000 |
| Maliyet sızıntısı (`inventory_movements.unit_cost_snapshot`, `return_items.unit_cost_at_sale`, THI) | Maliyet ayrı tablolara taşındı: `inventory_movement_costs`, `sale_item_costs`, `sale_costs`, `variant_cost_pools`, `transfer_held_inventory` → hepsi `fn_is_manager_plus` | §3 |
| `unit_price` client'tan | Server-authoritative: liste fiyatı DB'den; `expected_list_price` ≠ liste → `PRICE_CHANGED`; `unit_price` ≤ liste, indirim `max_discount_pct` (J-4) | 004 `fn_sale_core` |
| Rezervasyon dönüştürme yok | `p_reservation_id`: kilit, adet eşleşmesi (`RESERVATION_MISMATCH`), `converted_to_sale_id`, AVAILABLE hesabında kendi rezervasyonu hariç | 004 |
| Eksik FX → sessizce 1 | `fn_get_fx_rate` → `FX_RATE_MISSING`; override yalnız owner/manager (`FX_OVERRIDE_NOT_AUTHORIZED`), `fx_overridden` işaretlenir | 002/004 |
| Over-return SUM yok | `sale_items` satır kilidi altında `SUM(return_items.quantity)` → `OVER_RETURN` | `fn_return_core` |
| Final-sale kontrolü yok | Kategori `is_final_sale` → `FINAL_SALE` | `fn_return_core` |
| Allocation tek `amount` | `liability_currency_amount_applied` / `payment_currency_amount_applied` / `base_amount_applied` / `settlement_fx_rate` / `settlement_basis` | 001 + `rpc_allocate_supplier_payment` |
| Composite FK eksikleri | `(business_id, id)` UNIQUE + composite FK: category/brand/supplier/branch/register/sale/return/transfer/… | 001/003 |
| Void / adjustment / state-change / write-off / supplier payment / reservation RPC'leri yok | Hepsi yazıldı (§2) | 004 |

---

## 1. Migration sırası ve bağımlılık (statik)

Dosyalar Supabase CLI timestamp formatında; eski `001_…004_` adları **silinir** (karışım `db_fresh.ps1` tarafından reddedilir).

| # | Dosya | İçerik | Bağımlılık |
|---|---|---|---|
| 1 | `20260908000001_core_schema.sql` | `pg_trgm`; 5 domain, 23 enum; 20 tablo (businesses…goods_receipt_items); yardımcı `fn_*`; trigger'lar; RLS + 38 policy | `auth.users`, `auth.uid()`, roller `anon/authenticated/service_role` (Supabase ya da harness) |
| 2 | `20260908000002_fx_rates.sql` | `fx_rates` (versiyonlu, supersession), `rpc_set_fx_rate`, `fn_get_fx_rate`, `rpc_get_fx_rate`, `v_fx_rates_current` | 001 (`fn_is_manager_plus`, `iso_currency`) |
| 3 | `20260908000003_inventory_sales_schema.sql` | 26 tablo (pools, ledger, transfers/THI, sequences, adjustments, counts, customers, reservations, registers, sales, returns, supplier_returns); immutability trigger'ları; 6 view (`security_invoker`); 35 policy | 001, 002 (`fx_rates` FK) |
| 4 | `20260908000004_posting_rpcs.sql` | 33 fonksiyon: internal `fn_*` + 22 `rpc_*` | 001–003 |

Audit betiği: tablo/tip/fonksiyon referansları tanımdan önce mi (fonksiyon gövdeleri hariç — runtime'da çözülür) → **0 sorun**. `reservations.converted_to_sale_id` FK'sı `sales`'tan sonra `ALTER TABLE` ile; `returns.replacement_sale_id` FK'sı `DEFERRABLE INITIALLY DEFERRED` (exchange önce return, sonra sale yazar).

Toplam: **47 tablo**, 28 tip, 58 fonksiyon, 74 policy, 7 view. Test T01 47'yi doğrular.

Minimum PostgreSQL: **15** (`security_invoker` view'ler). Supabase hosted 15/17, yerel 18: uyumlu.

---

## 2. SECURITY DEFINER / RPC audit

Kural: her `fn_*`/`rpc_*` `SECURITY DEFINER SET search_path = pg_catalog, public`; her fonksiyon `REVOKE … FROM PUBLIC, anon, authenticated`; yalnız `rpc_*` `GRANT … TO authenticated`. Betik sonucu: search_path'siz SD fonksiyon **0**, GRANT'sız rpc **0**, REVOKE'suz rpc **0**. `authenticated`'a açık `fn_*` yalnız RLS policy'lerinin çağırdığı üyelik yardımcıları (`fn_is_member`, `fn_my_role`, `fn_has_role`, `fn_is_manager_plus`, `fn_is_procurement`, `fn_my_business_ids`). `fn_setting` Rev 3'te **internal** yapıldı (client `businesses.settings`'i RLS ile okur).

| RPC | Rol | Döner | Başlıca hata kodları |
|---|---|---|---|
| `rpc_set_fx_rate` | owner, manager | UUID | FORBIDDEN, INVALID_CURRENCY, INVALID_DATE, INVALID_RATE |
| `rpc_get_fx_rate` | any member | TABLE | FORBIDDEN, FX_RATE_MISSING |
| `rpc_create_variant` | owner, manager | UUID | INVALID_PRODUCT, INVALID_OPTION_VALUE, 23505 (aynı aktif kombinasyon) |
| `rpc_assign_internal_barcode` | owner, manager, stock_staff | TEXT | INVALID_VARIANT |
| `rpc_post_goods_receipt` | owner, manager, stock_staff (**J-3**) | VOID | NOT_FOUND, INVALID_STATE, EMPTY_DOCUMENT, INVALID_FX |
| `rpc_reverse_goods_receipt` | — | — | **NOT_IMPLEMENTED (DEFERRED)** |
| `rpc_process_sale` → `fn_sale_core` | any member | JSONB | INVALID_REGISTER_SESSION, REGISTER_CLOSED, INVALID_OCCURRED_AT, PRICE_CHANGED, INVALID_PRICE, DISCOUNT_NOT_AUTHORIZED, INSUFFICIENT_STOCK, RESERVATION_MISMATCH, CURRENCY_NOT_ACCEPTED, FX_RATE_MISSING, FX_OVERRIDE_NOT_AUTHORIZED, PAYMENT_SHORT, PAYMENT_MISMATCH, IDEMPOTENCY_CONFLICT, VARIANT_NOT_SELLABLE |
| `rpc_void_sale` | owner, manager | VOID | NOT_FOUND, ALREADY_VOIDED, VOID_BLOCKED (iade var / kasa kapalı) |
| `rpc_process_return` → `fn_return_core` | any member | JSONB | USE_EXCHANGE_RPC, REFUND_NOT_ALLOWED, STORE_CREDIT_NOT_ALLOWED, NOT_IMPLEMENTED (store credit), EXCHANGE_WINDOW_EXPIRED, FINAL_SALE, OVER_RETURN, DISPOSITION_NOT_AUTHORIZED |
| `rpc_process_exchange` | any member | JSONB | EMPTY_CART, IDEMPOTENCY_CONFLICT + return/sale kodları (**J-1**, tek transaction) |
| `rpc_create_reservation` / `rpc_cancel_reservation` | any member | UUID / VOID | INVALID_EXPIRY, IDENTITY_REQUIRED, INSUFFICIENT_STOCK, INVALID_STATE |
| `rpc_post_inventory_adjustment` | owner, manager | UUID | COST_REQUIRED, COST_CONFIRMATION_MISMATCH, NO_PURCHASE_HISTORY, INSUFFICIENT_STOCK |
| `rpc_change_stock_condition` | owner, manager, stock_staff | UUID | INSUFFICIENT_STOCK, INVALID_STATE_CHANGE (değer deltası 0) |
| `rpc_write_off` | owner, manager | UUID | INSUFFICIENT_STOCK |
| `rpc_ship_transfer` / `rpc_receive_transfer` | owner, manager | VOID | INVALID_STATE, EMPTY_DOCUMENT, INSUFFICIENT_STOCK, PARTIAL_RECEIPT_NOT_SUPPORTED |
| `rpc_open_register_session` / `rpc_close_register_session` | any member | UUID / JSONB | REGISTER_ALREADY_OPEN, CURRENCY_NOT_ACCEPTED, COUNT_REQUIRED, INVALID_COUNT, INVALID_STATE |
| `rpc_record_supplier_payment` / `rpc_allocate_supplier_payment` | owner, manager (**J-3 muhasebe ayrımı**) | UUID | INVALID_SUPPLIER, INVALID_LIABILITY, OVER_ALLOCATION |
| `rpc_post_supplier_return` | — | — | **NOT_IMPLEMENTED (J-5 DEFERRED)** |

Actor: her RPC `fn_actor()` = `auth.uid()`; NULL → `UNAUTHENTICATED`. Tenant: `p_business_id` üyeliği `fn_require_member` ile; belge bazlı RPC'ler belgenin `business_id`'sini okur, ayrıca `fn_assert_branch` / `fn_assert_variant`.

İdempotency: `client_transaction_id` başına `pg_advisory_xact_lock`; `request_fingerprint = sha256(payload)`; aynı id + aynı payload → replay (`replayed:true`), farklı payload → `IDEMPOTENCY_CONFLICT`. Exchange için fingerprint tüm exchange payload'ını kapsar.

---

## 3. Direct-write ve görünürlük audit'i (RLS)

Betik çıktısı (47 tablo): **RLS'siz tablo 0**; ledger/posted/RPC-only tablolarda client INSERT/UPDATE/DELETE policy'si **0**. `FORCE ROW LEVEL SECURITY` kullanılmıyor (SD RPC'ler tablo sahibi olarak çalışır; bilinçli).

| Grup | Tablolar | SELECT | Client yazma |
|---|---|---|---|
| Tenant master | businesses, branches, business_members, brands, categories, product_options, option_values, products, product_variants, variant_option_values, barcodes, product_images, cash_registers, customers | member | member (branches/members/business update: **owner**) |
| Procurement (J-3) | suppliers, goods_receipts, goods_receipt_items, stock_transfers(+lines), inventory_counts(+lines) | owner/manager/stock_staff | aynı roller, yalnız **draft** (posted → trigger `IMMUTABLE`) |
| Supplier muhasebe (J-3) | supplier_account_entries, supplier_payments, supplier_payment_allocations | **manager+** | yok (RPC) |
| Maliyet | variant_cost_pools, inventory_movement_costs, sale_item_costs, sale_costs, transfer_held_inventory, inventory_adjustments, product_price_history, document_sequences | **manager+** | yok |
| Ledger / posted | inventory_movements, sales, sale_items, sale_payments, returns, return_items, cash_movements, register_sessions, register_session_currency_counts, reservations, reservation_items, fx_rates | member (adet/fiyat, maliyet yok) | yok (RPC) |
| Deferred (J-5) | supplier_returns, supplier_return_items | manager+ | yok |
| Self | profiles | `id = auth.uid()` | kendi satırı |

Maliyet kolonu taraması (`cost|value_base|mwa|margin` içeren kolon × member/procurement policy): yalnız `goods_receipt_items.unit_cost*` (J-3: stock_staff mal kabul maliyetini görür — **kasıtlı**) ve `returns.credit_value_base` (satış fiyatı bazlı müşteri kredisi, maliyet değil). SALES_STAFF hiçbir maliyet kolonunu göremez (T06a/b, T08c/d, T34j).

View'ler: 7 view `WITH (security_invoker = true)` → çağıranın RLS'i uygulanır; `v_supplier_balance*` base tabloları manager+ olduğu için stock_staff'a boş döner.

---

## 4. Stok / maliyet invariantları (statik)

Tek yazma kanalı: ledger yalnız `fn_ledger_post`, havuz yalnız `fn_post_to_cost_pool`; THI yalnız `rpc_ship_transfer`/`rpc_receive_transfer`. Doğrudan `INSERT INTO inventory_movements|variant_cost_pools|inventory_movement_costs` içeren başka fonksiyon **yok** (betik).

| Invariant | Mekanizma |
|---|---|
| Havuz koşul-nötr: business+branch+variant | `variant_cost_pools` PK; bucket geçişi (`rpc_change_stock_condition`) iki ledger satırı, havuza dokunmaz (değer deltası 0) |
| Giriş maliyet zorunlu | `fn_post_to_cost_pool` inflow: `COST_REQUIRED`; GR: `unit_cost_base = unit_cost × fx_snapshot` (cost6), toplam = Σ satır |
| Çıkış = giriş öncesi MWA | `v_avg` kilit altında hesaplanır, çıkış deltası `round(qty×avg, 6)` — havuz ve ledger **aynı** deltayı alır |
| Tam tükenme → değer tam 0 | `v_new_qty = 0 ⇒ v_delta = −v_val` (T15) |
| Negatif stok yok | AVAILABLE kontrolü (`on_hand − reserved`) satış/rezervasyonda kilit altında; `NEGATIVE_POOL` son savunma; CHECK `on_hand_qty ≥ 0`, `total_value_base ≥ 0`, `(qty=0 ⇒ value=0)` |
| İade orijinal maliyetle girer | `sale_item_costs.unit_cost_at_sale` → inflow; MWA'yı bozmaz (T24c, T29c) |
| Void orijinal maliyetle geri koyar | aynı (T30e) |
| Transfer: THI tam değer taşır | ship: çıkış deltası THI'ye; receive: aynı değerle giriş (T32c/g); kısmi receipt yok |
| Havuz = Σ ledger delta, on_hand = Σ ledger qty | T31p/T31q her havuz satırı için |
| Adjustment maliyet kaynağı açık | `current_mwa` / `last_purchase_cost_confirmed` (onay değeri eşleşmeli) / `manual_cost` |

Kilit sırası: `fn_lock_pools` varyant id sırasıyla `FOR UPDATE` (deadlock önleme); satış → `sale_items` satır kilidi iadelerde; kasa oturumu `FOR UPDATE`.

---

## 5. Politika kararlarının koda izdüşümü (J-1…J-5)

| Karar | Kod | Test |
|---|---|---|
| J-1 disposition default QUARANTINE; owner/manager SELLABLE/DAMAGED; sales_staff zorlanır | `fn_return_core` `DISPOSITION_NOT_AUTHORIZED` | T24a, T24b, T24d |
| J-1 exchange = return + sale, tek transaction, `exchange_group_id` + `replacement_sale_id` | `rpc_process_exchange` (return, sonra kredi uygulanmış sale; deferred FK) | T29a–g (atomiklik: T29f/g) |
| J-2 refund/store_credit enum kalır, TLC policy kapalı | `fn_setting('money_refund_allowed'/'store_credit_allowed')` → `REFUND_NOT_ALLOWED` / `STORE_CREDIT_NOT_ALLOWED`; store credit ledger `NOT_IMPLEMENTED` | T28a/b, seed |
| J-3 GR: owner/manager/stock_staff; supplier muhasebe manager+ | `fn_is_procurement` policy'leri + `rpc_post_goods_receipt` rol listesi; muhasebe tabloları/RPC'leri manager+ | T07a, T08a–d, T33a |
| J-4 `business_members.max_discount_pct`; seed'de yok; sales_staff 0% | `fn_sale_core`: `unit_price < list` ⇒ `DISCOUNT_NOT_AUTHORIZED` (staff, NULL/0 yetki); owner/manager sınırsız | T18a–c |
| J-5 SupplierReturn DEFERRED | şema kalır; policy: manager+ SELECT, yazma yok; `rpc_post_supplier_return` → `NOT_IMPLEMENTED` | T34f, T34h |

Seed'de **bilinçli olarak yok**: `max_discount_pct`, `fx_rates`, `default_tax_rate`, markup, rezervasyon süresi varsayılanı, üyeler. Eksik policy anahtarı → `SETTING_MISSING` (T34i); varsayılan uydurulmaz.

---

## 6. Statik lint sonuçları (`tools/lint_sql.py`, 2026-09-08)

```
tables=49 (47 + 2 temp)  enums=23  funcs=58
INSERT kolon listeleri vs CREATE TABLE ........ 0 hata
'literal'::enum ............................... 0 hata
fn_/rpc_ çağrıları tanımlı mı ................. 0 hata
UPDATE … SET kolonları ........................ 0 hata
REVOKE/GRANT eksikleri ........................ 0 uyarı
tests: beklenen hata kodu 004'te yok .......... 0
tests: RPC çağrı arity'si ..................... 0 (JSON/ARRAY içi virgül yanlış pozitifleri elle doğrulandı)
```

Lint'in yakalayamadığı ve **yalnız çalıştırmayla** görülecek sınıflar: plpgsql sözdizimi (`CREATE FUNCTION` gövdeyi parse etmez → ilk çağrıda), tip uyuşmazlıkları (`money2` vs NUMERIC atamaları, `::cost6` domain CHECK), RLS policy'lerinin `SET ROLE authenticated` altında gerçek davranışı, trigger sırası, transition table'lı statement trigger'ları, `security_invoker` altındaki view planları, Windows psql encoding.

---

## 7. Test harness uyumluluğu

Migration'ların Supabase'e özgü bağımlılıkları: `auth.users` (profiles FK + trigger), `auth.uid()` (RLS/actor), roller `anon/authenticated/service_role`, `pg_trgm`. Harness (`000_test_harness.sql`, yalnız Plain mod) tam olarak bunları sağlar; `auth.uid()` Supabase ile aynı çözümleme sırasını (`request.jwt.claim.sub` → `request.jwt.claims->>'sub'`) kullanır, dolayısıyla `005` her iki modda **değişmeden** çalışır (`t_login` claim'leri set eder + `SET ROLE authenticated`).

`005_verification_tests.sql`: 143 assertion (T01–T34), tek transaction, sonunda `ROLLBACK`; herhangi bir `[FAIL]` → `RAISE EXCEPTION` → psql exit ≠ 0 → `db_fresh.ps1` exit 1. Fixture adımları (`t_set(... rpc ...)`) exception yakalamaz: fixture'ın kendisi hata verirse dosya orada durur — bu da bir bulgudur.

`tests/concurrency/concurrency_run.ps1`: iki gerçek psql oturumu; A son birimi satar ve 3 sn kilit tutar, B 1 sn sonra girer, kilitte bekler ve A commit edince `INSUFFICIENT_STOCK` almalı; doğrulama 1 satış / havuz 0/0. (`db_fresh.ps1`'den sonra, Plain modda; commit eder, ardından `db_fresh.ps1` tekrar.)

---

## 8. Açık maddeler / DEFERRED (pilot başlangıcını bloke etmez)

| # | Madde | Durum |
|---|---|---|
| D-1 | Supplier return posting (`rpc_post_supplier_return`) ve UI | **DEFERRED** (J-5) — stub, yazma kapalı |
| D-2 | Goods receipt reversal (`rpc_reverse_goods_receipt`) | **DEFERRED** — stub; posted GR düzeltmesi V1'de adjustment ile |
| D-3 | Store credit ledger | **DEFERRED** — policy kapalı + `NOT_IMPLEMENTED` |
| D-4 | Kısmi transfer receipt | **NOT SUPPORTED** (tam receipt zorunlu) |
| D-5 | Kampanya/promosyon motoru | V1 dışı (J-4) |
| D-6 | `-Mode Supabase` yerelde Docker gerektirir; makinede Docker yok | Plain mod tek doğrulama yolu; Supabase-local ikinci geçiş Docker kurulunca |
| D-7 | `sale_item_costs` iade sırasında `unit_cost_at_sale` snapshot'ı eksikse `INTEGRITY` | Rev 3 satış yolu her zaman yazar; eski veri yok |

---

## 9. Doğrulama sonucu (gerçek koşu, 2026-09-08)

`.\scripts\db_fresh.ps1` (Plain, PostgreSQL 18.6, port 5433):

```
harness -> 4 migration -> seed -> 005
BoutiqueOS Rev 3 verification: 149 passed, 0 failed
PASS: 149   FAIL: 0   psql errors: 0   exit: 0
```

§6'daki "yalnız çalıştırmayla görülür" sınıfı böylece kapandı. Koşu sırasında bulunup düzeltilen defektler:

| # | Dosya | Defekt | Düzeltme |
|---|---|---|---|
| R-1 | 004 | `rpc_void_sale`: `RAISE EXCEPTION 'VOID_BLOCKED: sale %'` argümansız → derlenmiyor | `, p_sale_id` eklendi; lint'e RAISE placeholder/argüman kuralı eklendi |
| R-2 | 005 | `t_set(k,v)`: parametre adı kolon adıyla çakışıyor (`ON CONFLICT (k)` ambiguous) | parametreler `p_k`/`p_v` |
| R-3 | 004 + 005 | `rpc_create_variant` varyantı `''` fingerprint ile yazıp opsiyonları sonra bağlıyordu → `uix_variant_active_fingerprint` çakışması | fingerprint INSERT'ten önce hesaplanıp veriliyor (trigger formülüyle birebir); fixture opsiyonları her varyanttan hemen sonra bağlıyor (+T34k) |
| R-4 | 001 | `fn_log_price_change`: `TG_TABLE_NAME='products' AND NEW.default_sale_price…` tek ifade olarak planlanıyor → `product_variants` UPDATE'inde "record new has no field" | tablo testi ile alan referansı ayrı `IF`'lere bölündü |
| R-5 | 002 | `fx_rates.superseded_by` FK anında kontrol ediliyor; supersession yeni satırdan **önce** yazılmak zorunda (kısmi unique index) → FK ihlali | FK `DEFERRABLE INITIALLY DEFERRED` |
| R-6 | 001/002/003 | **Void hiç çalışmıyordu**: guard trigger'ları `to_jsonb(NEW)`/`to_jsonb(OLD)` karşılaştırıyor; BEFORE trigger'da GENERATED kolonlar NEW'de NULL (`sales.amount_due_base`) → her void `IMMUTABLE` | `fn_row_comparable()` generated kolonları iki taraftan çıkarıyor; tüm guard'lar (sales, fx_rates, THI, transfer lines, posted GR) kullanıyor |
| R-7 | 004 | `rpc_allocate_supplier_payment`: `CASE … 'paid' … END` text → `goods_receipt_payment_status` kolonuna atanamıyor | `::goods_receipt_payment_status` cast |
| R-8 | 005 | T11d/T20e/T20f yanlış katmanı ölçüyordu: üye için RLS yazma policy'si yok ⇒ UPDATE/DELETE **0 satır** (sessiz), trigger yalnız RLS-baypas rolleri için | iddialar ikiye bölündü: üye tarafı 0 satır, postgres tarafı `IMMUTABLE`, artı değerin değişmediği |
| R-9 | scripts | `db_fresh.ps1`: psql'in stderr'e yazdığı NOTICE, `$ErrorActionPreference=Stop` altında terminating hata sayılıyordu | native çağrılar `Invoke-Native` ile `Continue` altında; karar yalnız `$LASTEXITCODE` |

R-1, R-3, R-4, R-5, R-6, R-7 üretim kodu defektleridir; R-2, R-8 test, R-9 tooling.

## 10. Gate durumu (2026-09-08)

| Gate | Durum |
|---|---|
| Plain fresh-DB (harness + 4 migration + seed + 005) | **PASS** 149/149 |
| Concurrency (son birim oversell yarışı) | **PASS** |
| Supabase-local (`-Mode Supabase`) | **DEFERRED** — Docker/Podman kurulu değil |
| DEV Supabase migration apply (`supabase db push`) | **APPLIED** — 20260908000001–04, Local/Remote eşleşiyor |
| Things Like Crop seed (DEV) | **APPLIED** |
| Remote smoke kontrolleri | **PASS** |
| İlk owner Auth kullanıcısı + üyelik | **CREATED** — Things Like Crop / Lefkoşa Mağaza / owner / aktif |
| Frontend Faz 1 — bağımlılık + build | **VERIFIED** — `npm ls` / `audit` / `lint` / `build` / `typecheck` tümü PASS |
| Frontend Faz 1 — auth + tenant girişi | **VERIFIED** — manuel smoke DEV Supabase'e karşı PASS |
| Frontend Faz 2 — ürün kataloğu (ürün / varyant / barkod) | **VERIFIED** — manuel DEV smoke 2026-09-09'da PASS |
| Frontend Faz 3 — tedarikçiler + mal kabul + stok | **VERIFIED** — TRY manuel DEV smoke 2026-09-09'da PASS |
| Faz 3 — non-TRY FX manuel smoke | **DEFERRED** — DEV'de kullanılabilir FX kaydı yok |
| Faz 3 — sales_staff rol smoke | **VERIFIED** (2026-09-14) — bkz. §12 |
| Gerçek cross-tenant test | **VERIFIED** (2026-09-14) — bkz. §12 |
| GAP-1 `rpc_create_goods_receipt` (20260909062632) | **APPLIED** — remote'ta kayıtlı, local/remote eşleşiyor |
| Faz 3.5 tenant/platform sertleştirme (`20260909102950`–`105530`) | **APPLIED** — DEV'de kayıtlı |
| Faz 4 Ekip & Kimlik (`20260909132840`–`134539`) | **DEPLOYED TO DEV** (2026-09-14) — bkz. §12 |
| Faz 5+ (Kasa, Satış, Raporlar…) | **READY FOR DESIGN SYSTEM** — kodlama başlamadı |
| Deploy (Vercel) | **PILOT DEPLOYED** (2026-09-09) — https://butikos.parlakmediatech.com.tr · özel alan adı geçerli · Supabase Auth Site/Redirect URL güncellendi |
| Production Supabase projesi | **KURULMADI** — pilot dağıtım DEV projesine bağlı |

Supabase-local ertelendiği için gerçek `auth.uid()` yolu DEV üzerindeki remote smoke ile doğrulandı;
Docker kurulduğunda `.\scripts\db_fresh.ps1 -Mode Supabase` ikinci bir doğrulama katmanı olarak koşulabilir.

## 12. Faz 4 — Ekip & Kimlik: canlı E2E ve yetki denetimi (2026-09-14)

Tümü **canlı adres** (Vercel Production → DEV Supabase) üzerinde, gerçek Gmail teslimatıyla.
Fixture tenant'lar: `ZZ E2E TEAM TEST A` (`7ce74377-…`) ve `ZZ E2E TEAM TEST B` (`6f79372f-…`);
test hesabı `fatihparlak1+butikos-e2e@gmail.com` (`64cfef13-…`). Gerçek TLC verisine hiçbir yazma yapılmadı.

### E-posta akışları

| Case | Akış | Sonuç |
|---|---|---|
| A | Yeni kullanıcı daveti (`inviteUserByEmail`) → Gmail → `/auth/confirm` → parola → `/davet/<id>` kabul → A'da `sales_staff` | **PASS** — `invite_created` → `invite_resent` → `invite_accepted` + `member_added` tek transaction; OTT tüketildi |
| B | Mevcut kullanıcıya ikinci tenant daveti → `signInWithOtp(shouldCreateUser:false)` magic link → resend → kabul → B'de `stock_staff`, A üyeliği korunarak | **PASS** — yeni auth user yok, aynı `user_id`; ilk resend 60 sn GoTrue aralığına takıldı (429, ürün hatası değil), ikincisi geçti ve OTT yenilendi |
| C | `/sifre-sifirla` → Reset Password maili → `/auth/confirm` → `/sifre-belirle` → parola → `/auth/session-ready` → `/app` | **PASS** (üç turda) — bkz. aşağıdaki bulgular; son turda parola 10:50:58 UTC'de güncellendi, sunucu hatası yok |

Gmail'de doğrulanan gönderici `BoutiqueOS <noreply@parlakmediatech.com.tr>` (custom SMTP); ilk Case A denemesi
SMTP düzeltilmeden önce FAIL almıştı (`inviteUserByEmail` rollback, kullanıcı yaratılmadı).

### Case C'de bulunan ve kapatılan defektler

| # | Bulgu | Düzeltme |
|---|---|---|
| C-1 | `requestPasswordResetAction` `resetPasswordForEmail` sonucunu okumuyordu; taşıma/gateway hatası hiçbir yerde iz bırakmıyordu | `c0ba4e2` — `settleResetRequest`: operatöre metadata-only server log, ziyaretçiye değişmeyen generic yanıt |
| C-2 | Supabase `POST /auth/v1/recover` aralıklı **HTTP 525** (edge↔origin TLS; istek GoTrue'ya varmıyor) — 08:55 ve 10:20 UTC | `3a8c613` — yalnız 525'te, 1,7 s sonra tek retry; başarılı retry `warn`, ikinci hata `error` logu |
| C-3 | Parola güncellemesinden hemen sonra PostgREST **PGRST303 "JWT issued at future"** → `/app` bootstrap'ında Next server exception (digest 711079145) — 09:29 ve 10:37 UTC | `ba52575` tek 1,2 s retry (yetersiz kaldı) → `38759e5` — `/auth/session-ready` bekleme odası: tenant verisi okumaz, salt-okuma probe'u 0/1/2/4/8 s yoklar, `next` allowlist; `setPasswordAction` artık doğrudan `/app`'e değil odaya yönlendirir |
| C-4 | `/sifre-belirle` herhangi bir oturumla (owner parola girişi dahil) parola formunu gösteriyordu | `ba52575` — recovery gate; `setPasswordAction` da gate'i Auth'a dokunmadan önce değerlendirir |

**Gate'in dayandığı gerçek:** `auth.mfa_amr_claims` ve supabase/auth `verify.go` — GoTrue her e-posta linkine
`amr=otp` yazar, `recovery` AMR yöntemi e-posta kurtarmada yoktur. Gate = `otp` + bekleyen `recovery_sent_at` +
oturum (`amr.timestamp`) istekten sonra doğmuş. Bilinen ve kabul edilen sınır: magic link de `recovery_sent_at`
yazdığı için magic-link oturumu da gate'i geçer (aynı posta kutusu kanıtı); parola girişi her durumda reddedilir.

**Upstream olaylar düzeltilmiş değildir.** Uygulama tarafındaki önlemler geçici toleranstır; `docs/13` support notu hazır, gönderilmedi.

### Canlı yetki smoke'u (gerçek alias oturumu, RLS altında; service-role yalnız test hesabına giriş linki üretmek için kullanıldı)

Sayfa katmanı (cookie'li HTTP, kullanıcı tarayıcısına dokunmadan) + doğrudan PostgREST/RPC: **77 doğrudan + 21 sayfa iddiası PASS**.
Not: server-component `redirect()` streaming sonrasında **HTTP 200 + `<meta http-equiv="refresh">` + `NEXT_REDIRECT`** döner (T-11 ile aynı davranış);
reddedilen sayfalarda gövdeye yalnız `<title>` ve yükleme iskeleti gider, veri gitmez.

| Rol / tenant | İzinli | Reddedilen |
|---|---|---|
| `sales_staff` @ A | `/app`, `/app/urunler`, `/app/stok`, `/app/ayarlar` (maliyet/marj işareti yok) | `/app/ayarlar/ekip`, `/ekip/gecmis`, `/app/tedarikciler(/yeni)`, `/app/mal-kabul(/yeni)`, `/app/urunler/yeni` |
| `stock_staff` @ B | `/app`, `/app/stok`, `/app/mal-kabul`, `/app/tedarikciler` (TLC/A verisi yok) | `/app/ayarlar/ekip`, `/ekip/gecmis` |
| Cookie `bos_active_business = TLC` | — | TLC bağlamına girilmedi (`/select-business`) |

Doğrudan RLS/RPC (alias JWT): `rpc_list_team` / `rpc_list_invites` / `rpc_create_invite` / `rpc_resend_invite` / `rpc_revoke_invite` /
`rpc_invite_delivery_target` / `rpc_platform_set_business_status` → **FORBIDDEN** (A, B ve TLC için); `team_audit_log`, `business_invites`,
`suppliers`, `goods_receipts(_items)`, `variant_cost_pools`, `supplier_account_entries`, `inventory_movement_costs`, `product_price_history`,
`products`, `product_variants`, `inventory_movements`, `platform_*` → **0 satır** (TLC'de veri olmasına rağmen); `business_members` yalnız
kendi satırları; `businesses`/`branches` yalnız A ve B; `profiles` yalnız kendi; kendi rolünü yükseltme, owner'ı pasifleştirme/silme,
indirim değiştirme, işletme adı değiştirme, kabul edilmiş daveti açma, TLC'ye kendini ekleme → **0 satır / reddedildi**; üyelikler değişmedi.

### Fixture temizliği

`rpc_platform_set_business_status` (platform admin = owner, `platform_audit_log`'a yazıldı) ile A ve B `cancelled` (11:09:33 UTC).
Silinmedi: işletmeler, 7 üyelik, 11 ekip audit kaydı, alias Auth kullanıcısı (gelecek regresyonlar için). Alias'ın aktif işletmede
üyeliği kalmadı → picker'da görünmez. TLC sonrası: 3 aktif owner, ekip audit 0, mal kabul 1 posted / 5 cancelled / **9 draft** (draft
item 0), cost pool 8 adet / 3.260 TRY, tedarikçi borcu 3.260 TRY, son `updated_at` 2026-09-09 — değişmedi.

### Faz 4 test envanteri (plain Node, `npm run test:auth`)

redirect 25 · reset 108 · jwt-skew 27 · recovery 30 · session-ready 62 — tümü PASS. SQL tarafı `db_fresh` 508/508.

## 13. Faz 6A — Moda ürün ana verisi (2026-09-14)

### Şema denetimi → karar

| Alan | CURRENT | REQUIRED | Uygulanan |
|---|---|---|---|
| Ürün | `sku_prefix` zorunlu, model kodu yok | isteğe bağlı model/stil kodu, tekil değil | `products.style_code` (index, uyarı; constraint yok) |
| Seçenekler | tenant-geneli `product_options`/`option_values`, metadata yok | renk/beden türü, sıralama, kısa kod, swatch | `product_options.kind`, `option_values.code/color_hex`; `sort_order` zaten vardı |
| Varyant | `sku` zorunlu, aktif kombinasyon tekilliği (fingerprint) | matris üretimi, tekrar üretmede tekrarsızlık | `rpc_generate_variants` (atomik, idempotent, 500 üst sınır); `sku` DB'de zorunlu kalır, UI türetir |
| Barkod | `(business_id, barcode)` tekil, internal/supplier, primary | çoklu kod, tenant-güvenli çözümleme | `rpc_resolve_barcode` (üyelik zorunlu, barkod → SKU fallback) |
| Görsel | `product_images.url` zorunlu, rol/depolama yok, bucket yok | roller, özel bucket, tenant RLS, tür/boyut doğrulama | rol enum, `storage_path/mime/byte_size/…`, `product-images` bucket (5 MB, jpeg/png/webp), `storage.objects` politikaları, tek ana görsel (partial unique), `rpc_set_main_image` |
| Silme | envanter/satış FK'ları RESTRICT | history'li kayıt asla silinmez | doğrulandı (T60bj/bk); UI arşivler. Kapanışta bulgu: history'siz ürünü owner API'den silebiliyordu (RLS `FOR ALL`) → `20260914150000_phase6a_archive_only_lifecycle` ile DB düzeyinde kapatıldı (aşağıda) |

Migration eklemelidir; geri alma: politikalar, RPC'ler, index'ler, kolonlar, enum'lar, bucket satırı ters sırayla düşürülür; önceki veri etkilenmez.

### Testler
`tests/005` T60a–T60bp (**68** yeni) + T61 (**25**, arşiv-only yaşam döngüsü); toplam **601/0**, concurrency PASS. Harness'a `storage` shim'i eklendi.
Kapsam: seçenek metadata (geçersiz hex red), style_code çoğaltma (uyarı), matris 2×3 / idempotent / aynı seçenekten iki değer red / yabancı değer red / tek beden / boş matris, barkod (alternatif kod, SKU fallback, bilinmeyen, başka tenant red, aynı kod iki tenant'ta), görsel kısıtları ve RLS (sales_staff ve diğer tenant red), storage RLS (kendi yol OK, başka tenant yolu / gevşek yol red, çapraz okuma/silme 0 satır, staff yükleyemez), `business_id` yeniden yazma nötr, arşiv semantiği, tenant izolasyonu.

### Canlı DEV smoke (fixture tenant `ZZ E2E PRODUCT TEST C`, alias hesabı owner; sonra audited RPC ile `cancelled`)
API/RPC/Storage düzeyi (gerçek alias JWT, RLS altında): ürün + model kodu, çoğaltma uyarısı, seçenekler/değerler, 2×3 matris → 6, yeniden çalıştırma → 0, tek beden → 1, yalnız renk → 2, EAN + eski etiket + iç barkod (`ZZE2EC2026000001`) çözümleme, TLC'de çözümleme red, storage yükleme + imzalı URL + dosya servisi, varyant görseli, ikinci ana görsel red, ana görsel takası, GIF red, XL ekleme → 2 yeni/1 mevcut, arşivli kombinasyonun yeniden açılması, ürün arşivi, çapraz tenant (TLC ürün/görsel görünmez, TLC yoluna yükleme/imzalama red, yabancı varyant bağlama red) — **46/46**. Sayfa render'ları (cookie'li HTTP): liste (thumbnail, model kodu, barkod arama), ürün sayfası (matris, özet, görseller, benzer ürün uyarısı, maliyet yok), TLC ürünü 404, yeni ürün stepper — **8/8**.

**Gözlem:** taze oturumun ilk saniyelerinde `/app*` iki kez 500 döndü, ardından aynı oturumla 200 (upstream taze-JWT/Auth gecikmesiyle uyumlu; `/auth/confirm` bir kez 30 sn'yi aştı). Rota incelemesi kapanış bölümünde.

### Kapanış sertleştirmesi (2026-09-15)

**Arşiv-only yaşam döngüsü — `20260914150000_phase6a_archive_only_lifecycle`.** Önce: `pol_products_write` / `pol_variants_write` `FOR ALL` (manager+ ve aktif işletme) → history'siz ürün/varyantı owner API'den silebiliyordu; `authenticated` rolünde tablo düzeyinde DELETE yetkisi vardı. Sonra: `REVOKE DELETE, TRUNCATE ON products, product_variants FROM anon, authenticated`; `FOR ALL` politikaları INSERT ve UPDATE olarak ayrıldı, DELETE politikası yok. Kaçış yolu yok: owner dahil hiçbir tenant rolü fiziksel silemez (42501); `status = 'archived'` ve geri alma, varyant `is_active`/durum güncellemesi manager+ için çalışır. Barkod (`variant_barcodes`) ve görsel (`product_images`) satırları önceki silme semantiğini korur. T61 (25): yetki/politika envanteri, owner/manager/stock_staff/sales_staff/başka tenant DELETE → 42501, arşiv/geri alma/pasifleştirme OK, sales_staff UPDATE 0 satır, stock_staff barkod silme OK, manager görsel silme OK, history FK 23503. DEV'de doğrulandı: iki tabloda DELETE grant yok, politikalar insert/select/update.

**Etkileşimli UI QA (canlı DEV, fixture tenant `ZZ E2E PRODUCT TEST D`, alias hesabı owner; sonra audited RPC ile `cancelled`).** 1440 (tarayıcı): yeni model + model kodu + fiyat; Renk (swatch'li) ve Beden seçenekleri; 2×3 matris, bir kombinasyon kapatıldı ve bir SKU düzenlendi → 5 varyant; birincil + alternatif barkod, çoğaltılan barkod UI'da red; barkod arama (`?barkod=`) doğru varyanta; Leopar eklendi → yalnız eksik 4 üretildi, 5 "zaten var"; ana / varyant / etiket görseli yüklendi, ana görsel takas, etiket görseli kaldırıldı; varyant arşivi; ürün arşiv + geri alma; ekranda silme denetimi yok. 768 ve 390 (aynı kaynaktan iframe): sayfa yatay taşmıyor, matris kart görünümü ve barkod formu kullanılabilir, stepper tek sütuna iniyor.

**Görsel düzeltmeler (`197cd92`):** seçenek değeri `sort_order` sunucuda `max+10` (hızlı eklemede S/L/M eşit sıra alıyordu); matris seçenek varken boş seçimde kombinasyon üretmiyor; varyant matrisi renk→beden sırasında; kartlarda yalnız gerçek görsel; ürün sayfasında tek-tek varyant ekleme formu gizli (matris var); "<1 KB".

**Taze-JWT 500 rota gözlemi (kod değişikliği yok).** 500 dönen rotalar: `/app`, `/app/urunler` ve `/app/stok` (zincir `/app/stok → 307 /login → 307 /app → 500`). Üçü de `app/app/layout.tsx` → `requireTenant()` → `loadMemberships()` üzerinden geçer; bu yol `withFreshJwtRetry` (yalnız "JWT issued at future", 1,2 sn) + `failTenantRead` → `/auth/session-ready` ile korunur, yani rotalar session-ready mimarisini **baypas etmiyor**. Yanıt düz 500 idi (Next digest yok) — RSC render hatası değil, muhtemelen middleware/oturum-yenileme aşamasında Auth üst akış gecikmesi (aynı pencerede `/auth/v1/verify` > 30 sn). Tekrar üretilemedi; spekülatif retry genişletmesi yapılmadı, `docs/13` addendum'una işlendi.

**Güvenlik yeniden kontrolü (politika değişikliği sonrası, alias JWT, RLS altında): 18/18** — owner ürün/varyant DELETE 42501, arşiv/geri alma OK, TLC izolasyonu, barkod çözümleme/tekillik, TLC yoluna yükleme/imzalama red, çapraz tenant görsel bağlama red, `business_id` tahrifi nötr, varyant satırlarında maliyet kolonu yok.

### TLC
Ürün, varyant, barkod, mal kabul, stok ve borç verisine dokunulmadı. Aktif işletme yalnız TLC; fixture C ve D `cancelled`.

**Düzeltme (2026-09-15, salt okunur mutabakat sonrası):** bu bölümün önceki sürümü "1 ürün / 2 varyant / 0 görsel" diyordu ve kapanışta "yeniden doğrulandı" olarak işaretlenmişti. Satır, görsel yüklenmeden önce alınan 6A canlı-smoke snapshot'ından taşınmıştı; kapanış doğrulama sorgusu `product_images` saymadı ve eski satır olduğu gibi kaldı. Gerçek durum: TLC'de **1 `product_images` satırı** (`67ec4696-5ecb-4fd7-b5ae-d0df435e3d49`, role `product_main`, created_at 2026-09-14 13:47 UTC, created_by null — damgalama trigger'ı 6B'de geldi) ve **1 storage nesnesi** (`product-images`, 627.035 B, owner gerçek sahip hesabı) vardır. Görsel, Faz 6A penceresinde uygulamanın normal ürün-sayfası yükleme yoluyla ve gerçek sahip oturumuyla oluşturuldu; script/maintenance yazması değildir. `max_updated` yalnız `products.updated_at` ve `goods_receipts.updated_at` üzerinden hesaplanır, **`product_images` eklemelerini yakalamaz** — 2026-09-09'da kalması görselle çelişmez.

**Yetkili TLC taban çizgisi (2026-09-15):** aktif · 3 aktif owner · 1 ürün (TEST Keten Crop Bluz) · 2 aktif varyant · 2 barkod (1 internal CODE128, 1 supplier EAN13) · 1 product_image (product_main, 2026-09-14 13:47 UTC, created_by null) · 1 storage nesnesi · 17 kategori · 2 marka · 10 tedarikçi · inventory_movements 2 · cost pool 2 satır · on_hand 8 · toplam envanter değeri 3.260 TRY · MWA S 400 / M 420 · tedarikçi borcu 3.260 TRY · mal kabul 9 draft / 1 posted / 5 cancelled · gerçek draft item 0 · receipt item toplam 4 · products/receipts max_updated 2026-09-09.

**Yetkili TLC taban çizgisi (2026-09-17, salt okunur mutabakat sonrası — 2026-09-15 satırının yerini alır):** Faz 10A sırasında gerçek TLC owner hesabı (`3918a623…`; alias ve platform admin değil) canlı adresten iki işlem yaptı; bunlar **insan işlemidir, geri alınmadı, değiştirilmedi**. Yeni durum: aktif · 3 aktif owner · **2 ürün** (TEST Keten Crop Bluz [TEST-KETEN-CROP]; **FATİH PARLAK** [sku_prefix `test`, style `test`, fiyat 121.212, KDV 0, kategori yok, marka `5669f738…`, tedarikçi yok, `is_final_sale` false], `c38f5cc0-f1a1-4527-8bb2-b126fade9965`, 2026-09-16 12:37:43 UTC, created_by owner, updated 12:38:08) · **20 aktif varyant** (2 + 18: Size STD/XL/XXL × Color Kırmızı/Krem/Lacivert × Cup C/D, ayrıca TEST Renk=Siyah, TEST Beden=M, Length=Midi sabit; hepsi 12:38:04 UTC'de matris RPC ile, created_by owner) · 2 barkod (yeni üründe **0** barkod) · 1 product_image + 1 storage nesnesi (yeni üründe **0** görsel) · 17 kategori · 2 marka · 10 tedarikçi · **inventory_movements 3** (2 mal kabul girişi 2026-09-09 + **1 satış çıkışı 2026-09-16 12:03:46**; yeni ürün için 0 hareket / 0 havuz satırı / 0 mal kabul satırı) · movement_costs 3 · cost pool 2 satır, **on_hand 7, değer 2.840 TRY** (S 5@400 = 2.000; M 2@420 = 840) · **1 satış S-2026-000001**: 2026-09-16 12:03:46 UTC, Lefkoşa Mağaza, kasa "Ana Kasa" oturumu RS-2026-000001 (owner tarafından 12:03:07'de 2.500 TRY açılış nakdiyle açıldı, **hâlâ açık**), kasiyer = satıcı = owner hesabı, müşteri yok, 1 satır TEST-KETEN-CROP-M-SIYAH ×1 liste 1.250 = birim 1.250, indirim 0, toplam 1.250, ödeme nakit 1.250 TRY (kur 1), para üstü 0, `client_transaction_id` var (POS yolu), tarihsel COGS 420 (satış anı MWA) → `sale_item_costs` 420 / `sale_costs` 420, defterde `sale −1 sellable` (birim maliyet 420, değer −420), M havuzu 3/1.260 → 2/840 · 1 nakit hareketi (`sale_cash` +1.250) · 0 müşteri · 0 rezervasyon · 0 iade · mal kabul 9 draft / 1 posted / 5 cancelled · receipt item 4 · tedarikçi borcu 1 kayıt / 3.260 TRY · 0 stok sayımı · ayar anahtarları değişmedi (return_policy / reservation_default_hours yok) · en son damgalar: products 2026-09-16 12:38:08, variants 12:38:04, movements 12:03:46, sales 12:03:46, receipts 2026-09-09 10:10:30. Faz 6A–10A oturumlarının alias/admin hesapları TLC'de 0 ürün, 0 satış, 0 müşteri, 0 rezervasyon üretti.

### Ertelenen
Tek başına çoklu ürün tablosu için stok özeti (liste), etiket görselinin mal kabul akışıyla bağlanması (`receiving_proof` modellendi, UI yok), stock_staff görsel yükleme (manager+ tutuldu), görsel boyut/oran otomatik okuma (`width/height` kolonları boş), fuzzy ad benzerliği (yalnız ön ek ilike), varyant başına stok özeti çok şubede.

## 14. Faz 6B — Fiziksel katalog onboarding (2026-09-15, AÇIK)

### Teslim
`/app/urunler/katalog-ekle`: 1 Barkod (okuyucu/klavye, bilinen kod hard stop) → 2 Ürün (ad, model kodu, kategori önerileri tenant verisi olarak, fiyat isteğe bağlı, ürün + etiket fotoğrafı) → 3 Renk/Beden (yalnız işaretlenen; satır içi yeni değer; seçeneksiz için açık "tek varyant") → 4 Varyant matrisi (aç/kapat, SKU, etiket barkodu olduğu gibi, isteğe bağlı renk fotoğrafı; **kontrole geçmeden her barkod sunucuda doğrulanır**) → 5 Kontrol + tek "Ürünü kataloğa ekle". Mevcut modele eksik varyant ekleme aynı akışta. Migration'lar `20260915090000_phase6b_catalog_onboarding` (rpc_onboard_product / rpc_onboard_variants, `product_variants.created_by`, `fn_stamp_created_by`) ve `20260915120000_phase6b_image_path_tenant_check`.

### Testler
T62 (**43**): atomik onboarding, verbatim barkod/EAN13/birincil, çoğaltma rollback (çağrı dışı ve çağrı içi), mevcut ürüne ekleme + idempotency, roller/çapraz tenant red, doğrulama, **T62f sıfır stok/maliyet/borç/mal kabul etkisi**, T62g yabancı tenant görsel yolu red. Toplam **644/0**, concurrency PASS, `test:auth` 25/108/27/30/62, lint/typecheck/build temiz, tracked dosyalarda secret yok.

### Sentetik pilot (fixture `ZZ E2E CATALOG TEST E`, canlı UI; sonra ürünler arşivli, tenant audited RPC ile `cancelled`)
A Satin Dress 2×3 → 1 kapatıldı, 1 SKU düzenlendi → 5 varyant + ana/etiket/varyant görseli · B Knit Top tek beden 1 barkod · C Trousers yalnız beden 3 varyant · D Scarf yalnız renk (Leopar/Çok Renkli hex'siz) · E Bikini birincil + tedarikçi barkodu aynı varyanta çözümlendi · F Belt barkodsuz/modelsiz. Çoğaltma: bilinen barkod hard stop; E'nin barkodu F'ye → UI red + DB 23505 (satır kalmadı); aynı model kodu güçlü uyarı; `" zz test satin dress "` normalize ad uyarısı. Mevcut ürüne Zeytin: yalnız eksikler üretildi, mevcut Siyah/Bordo dokunulmadı; tekrar → 0 (UI "0 eklenecek, 9 zaten var", RPC created=0). Görsel: galeri yükleme, ana görsel takası, etiket kaldırma (satır + nesne), F'de yer tutucu; TLC yoluna yükleme/imzalama/listeleme/bağlama red. Responsive 1440/768/390: liste+barkod, ürün sayfası, 5 adım — yatay taşma yok. Sıfır yan etki: movement 0, cost pool 0, borç 0, mal kabul 0. TLC before/after snapshot **birebir aynı**.

**TLC:** before/after snapshot birebir aynı — snapshot **görseli zaten içeriyordu** (1 product_image + 1 storage nesnesi, 6A penceresinden). 6B sentetik pilotu TLC'yi değiştirmedi; §13'teki düzeltme notu ve yetkili taban çizgisi geçerlidir.

### Bulgular ve düzeltmeler
`fb81984` normalize ad uyarısı kısa ilk kelimede atlanıyordu · `78cd2e9` `product_images.storage_path` yabancı tenant yolunu kabul ediyordu (bayt okunamıyordu, satır sarkık kalıyordu) → CHECK · `a4576ab` bilinen barkod kontrolü yalnız blur'da çalışıyordu (okuyucu Enter gönderir) → kontrole geçmeden sunucu doğrulaması.

**Ortam notu:** claude-in-chrome otomasyon uzantısı altında "ara → Seç" yolu taze sekmede tarayıcı render'ını dondurdu (4/4); uzantısız temiz Chrome'da aynı yol 4/4 ve tüm QA PASS; konsolda uygulama hatası yok, istisna uzantının fetch sarmalayıcısında. Uygulama hatası olarak değerlendirilmedi; gerçek telefon turunda gözlenmeli.

### Açık
Gerçek TLC ürün batch'i (5–10 fiziksel ürün) sahibin onayıyla girilecek; TLC seed seçeneklerinin `kind` düzeltmesi (Color→color, Size→size) yapıldı, başka TLC yazması yok.

## 15. Faz 7A — Fiziksel stok sayımı motoru (2026-09-15)

### Envanter denetimi → karar
| Alan | CURRENT | REQUIRED | Uygulanan |
|---|---|---|---|
| Defter | `inventory_movements` append-only, `bucket` (sellable/quarantine/damaged) = durum modeli, `reason` enum'unda `adjustment` var, `reference_type/id` | sayım kaynaklı düzeltme, kalıcı bağ | reason `adjustment`, reference_type `stock_count_line`, reference_id = satır; `uix_movement_stock_count_line` (satır başına tek hareket) — enum'a değer eklenmedi |
| Maliyet | `variant_cost_pools` yalnız `fn_post_to_cost_pool` yazar; çıkış pre-movement MWA; giriş maliyet ister (`COST_REQUIRED`) | sayım farkı için güvenli kural | eksik → MWA çıkışı; fazla → mevcut MWA devri; pool boşsa bloklanır; borç yok |
| Kilit / yarış | `fn_lock_pools` variant sırasıyla FOR UPDATE | çift işleme, eş zamanlı stok değişimi | header FOR UPDATE + pool kilidi + satır bazlı defter yeniden okuma (`STALE_COUNT`) |
| Sayım stub'ları | `inventory_counts/_lines` (Rev 3, 0 satır, RPC/UI yok, istemci yazabilir) | yaşam döngüsü draft/counting/review/posted/cancelled | yeni `stock_counts/_lines/_scans` (RPC-only); stub'lar kapanış denetiminde (0 satır, gelen FK yok, fonksiyon/görünüm/uygulama referansı yok, yalnız kendi politika+trigger+enum'u) `20260915170000_drop_legacy_inventory_count_stubs` ile kaldırıldı |
| Roller | procurement = owner/manager/stock_staff; adjustment RPC manager+ | POST yetkisi | sayma/inceleme procurement; POST + iptal owner/manager; sales_staff hiç görmez |

### Mimari
`20260915150000_phase7a_stock_count_engine`: `stock_count_status/type` enum'ları; `stock_counts` (şube, tür full/cycle, not, created/reviewed/posted/cancelled_by/at, `review_ledger_watermark`), `stock_count_lines` (variant × bucket tekil; `expected_quantity` inceleme snapshot'ı, `counted_quantity` NULL = çözümsüz, `zero_confirmed`, `posted_delta`, `movement_id`), `stock_count_scans` (append-only olay günlüğü: kind scan/undo/set/zero_confirm, delta, `client_transaction_id` tekil → replay no-op, `device_id`, `client_at`, server `created_at` — çevrimdışıya hazır alanlar). RPC'ler: `rpc_stock_count_create` (procurement, `SC-YYYY-000001`), `_scan` (±n), `_set_quantity` (tam miktar; 0 = açık sıfır onayı), `_review` (FULL: defterde olup taranmayan her variant×bucket için çözümsüz satır; herkes için expected snapshot; tekrar çağrı = yeniden hesap), `_reopen`, `_cancel` (manager+), `_post` (manager+). `fn_guard_stock_count(_line)` trigger'ları posted/cancelled belgeleri herkese karşı dondurur. RLS: SELECT procurement; INSERT/UPDATE/DELETE grant'i yok.

### POST (tek transaction)
rol → işletme aktif → şube → durum = review (posted → `ALREADY_POSTED`) → çözümsüz satır yok (`UNRESOLVED_LINES`) → pool kilidi → her satır için `fn_bucket_qty` yeniden okunur, snapshot'tan farklıysa `STALE_COUNT` ("Stok sayım sırasında değişti. Farkları yeniden hesaplayın.") → fark ≠ 0 satırlara `fn_post_to_cost_pool` + `fn_ledger_post` → satırlara `posted_delta/movement_id` → header posted. Çift gönderim: header kilidinde bekleyen ikinci çağrı `ALREADY_POSTED` alır; ayrıca unique index ikinci hareketi imkânsız kılar.

### Testler
T63 (**87**): yetki envanteri, tarama/tekrar/replay/undo/negatif red, aynı varyant iki durumda iki satır, yabancı varyant red, draft/counting/review/cancelled'da sıfır hareket-maliyet-borç-mal kabul, FULL inceleme çözümsüz satır, `UNRESOLVED_LINES`, açık sıfır onayı, `COST_REQUIRED` (boş pool) bloklar ve hiçbir şey yazmaz, araya giren hareket → `STALE_COUNT` → yeniden inceleme, atomik post (5 hareket; MWA doğrulaması: eksik 4/400, fazla 2/140, net sıfır 3/150, sıfır onay 0/0), `ALREADY_POSTED`, posted/cancelled immutability (maintenance dahil), unique index, cycle sayım yalnız kendi satırları, iptal kaydı, pasif şube red, çapraz tenant (okuma/yazma/şube/varyant/business_id/hareket sahteciliği) red, stock_staff POST red, sales_staff hiç. Toplam **731/0**; `tools/lint_sql.py` düzeltildi (Windows yol ayracı yüzünden migration'ları hiç okumuyordu → çok kolonlu ALTER, DROP TABLE/TYPE, ALTER TYPE ADD VALUE öğrenildi; 0 hata / 0 uyarı, baseline yok); concurrency `count_double_post_run.ps1` PASS (A işledi, B `ALREADY_POSTED`, tek hareket), satış yarışı PASS; `test:auth` 25/108/27/30/62; lint/typecheck/build temiz; secret scan 0.

### Sentetik canlı smoke (fixture `ZZ E2E STOCK COUNT TEST`, alias owner, uzantısız Chrome, 390 px, gerçek klavye/tarayıcı girişi)
Açılış stoğu adjustment RPC ile: A 5@400, B 3@420, C 2@350, D sellable 2 / damaged 1 @380, E 1@350, F stoksuz. Sayım: A 4 ardışık okutma (queue) → 4, 5. okutma aynı satır → 5, geri al → 4; bilinmeyen barkod uyarı + hiçbir şey oluşmadı + alan temizlendi; C ×2, D sellable ×1; durum → Hasarlı, D ×2 (ayrı satır); F ×1; arama (barkodsuz) ile B +1 / −1; incelemeye geç → E (defterde 1, taranmadı) **çözümsüz**, "Sayımı işle" kapalı; sayıma dön, B ×3; inceleme: filtreler (farklar/eksik/fazla/sayılmamış/0 onay); E için "0 adet olarak doğrula" → cnt 0; POST → `COST_REQUIRED` (F, pool boş) — hiçbir şey yazılmadı; F maliyeti adjustment ile çözüldü → POST → `STALE_COUNT` → "Farkları yeniden hesapla" → POST: 7 satır, 4 hareket, −3 eksik, +1 fazla. Sonuç: A 4, B 3, C 2, D sellable 1 / damaged 2, E 0, F 1; pool A 4/1600, D 3/1140, C 2/700, E 0/0, F 1/350; tedarikçi kaydı/mal kabul yok. API: çift POST `ALREADY_POSTED`, posted satır update/delete/insert grant yok, TLC sayımı görünmez/oluşturulamaz, TLC varyantı sayılamaz, iptal edilen sayımlar korunuyor. Responsive 390/768/1440: liste, sayma, inceleme, sonuç — yatay taşma yok. Tenant sonra archived + audited RPC ile `cancelled`.

### TLC
Before/after snapshot (ürün/varyant/barkod/görsel/hareket/pool/borç/mal kabul/sayım) **birebir aynı**; TLC'de 0 sayım. Gerçek TLC sayımı yapılmadı.

### Ertelenen (7A)
Çevrimdışı senkron (alanlar hazır), çoklu sayaç (aynı sayımda cihaz bazlı ayrım `device_id` ile kayıtlı, UI yok), sayım sırasında beklenen miktarı gösterme (bilinçli gizli), sayım PDF/rapor, `COST_REQUIRED` fazlası için sayım içinden maliyet girişi (şimdilik ayrı adjustment).

### Frontend bağımlılık taban çizgisi (Faz 1)

Next 15.5.25 · React 19.0.0 · Tailwind 3.4.17 · `@supabase/supabase-js ^2.116.0` · `@supabase/ssr 0.12.6` ·
`postcss 8.5.23` (devDependency + `overrides`, iki spec birebir aynı; Next'in altındaki eski sürümü bastırmak için).
`@supabase/auth-js` transitive'dir ve supabase-js ≥ 2.116 ile yamalı sürüme çözülür.
`npm audit fix --force` ve Next 16 geçişi kapsam dışıdır.

Doğrulama 2026-09-08'de yerel makinede koşuldu ve çıktılar görüldü:

| Komut | Sonuç |
|---|---|
| `npm ls @supabase/supabase-js @supabase/auth-js @supabase/ssr next postcss` | **PASS** — `invalid` yok |
| `npm audit --omit=dev` | **PASS** — 0 vulnerabilities |
| `npm run lint` | **PASS** |
| `npm run build` | **PASS** |
| `npm run typecheck` | **PASS** |

Çözülen sürümler: `@supabase/ssr` 0.12.6 · `@supabase/supabase-js` 2.116.0 · `@supabase/auth-js` 2.116.0 ·
`postcss` 8.5.23 (Next'in nested kopyası dahil deduped).

### Faz 1 manuel smoke (2026-09-08, DEV Supabase)

Tarayıcıdan owner hesabıyla koşuldu; her adım hem ekran gözlemi hem dev sunucu logu ile doğrulandı.

| Test | Sonuç |
|---|---|
| Owner girişi (e-posta + parola) | **PASS** |
| Tenant çözümlemesi — Things Like Crop / Lefkoşa Mağaza (LFT) / owner | **PASS** |
| F5 sonrası oturum kalıcılığı | **PASS** |
| Yeni sekmede `/app` | **PASS** |
| Oturum açıkken `/login` → `/app` | **PASS** |
| Oturumsuz `/app` → `/login` | **PASS** |
| Çıkış | **PASS** |
| Çıkış sonrası `/app` → `/login` | **PASS** |
| Token refresh + cache-header yolu | **KOŞULMADI** — access token süresi dolmadan tetiklenmiyor; PASS işaretlenmedi |

### Operasyonel not — `JWT issued at future` (2026-09-08, çözüldü)

Faz 1 smoke'u sırasında `loadMemberships()` aralıklı olarak PostgREST'ten `JWT issued at future` hatası
aldı (`lib/tenant.ts:64`) ve aynı nedenle `getClaims()` taze token'ı reddederek kullanıcıyı anonim saydı.
Kök neden **Windows Time servisinin durmuş olması** ve yerel saatin NTP'siz kaymasıydı: token'ın `iat`
alanı doğrulayanın saatine göre gelecekte kalıyordu. Servis başlatılıp `w32tm /resync /force` çalıştırıldıktan
sonra hata dört ardışık smoke turunda tekrarlamadı.

**Bu bir uygulama veya veritabanı defekti değildir; bu nedenle hiçbir kod, şema veya RLS değişikliği
yapılmadı.** `w32time` başlangıç türü hâlâ `Manual`; makine yeniden başlatıldığında saat tekrar kayarsa aynı
belirti dönebilir (kalıcı çözüm: yönetici olarak `Set-Service w32time -StartupType Automatic`).


### Faz 2 manuel smoke (2026-09-09, DEV Supabase, owner oturumu)

Ürün kataloğu modülü (ürün / varyant / barkod) tarayıcıdan sürüldü. Her adım hem DOM'dan
okunarak hem dev sunucu logundan doğrulandı.

| Akış | Sonuç |
|---|---|
| Ürün listesi / arama / kategori · marka · durum filtresi | **PASS** |
| Ürün oluşturma / düzenleme | **PASS** |
| Marka oluşturma | **PASS** |
| Dinamik seçenek ve değer oluşturma | **PASS** |
| Varyant oluşturma (`rpc_create_variant`) | **PASS** |
| Varyant düzenleme | **PASS** |
| Dahili barkod (`rpc_assign_internal_barcode`) | **PASS** |
| Harici barkod | **PASS** |
| Yinelenen varyant kombinasyonu reddi (`uix_variant_active_fingerprint`) | **PASS** |
| Yinelenen işletme kapsamlı barkod reddi (`barcodes_business_id_barcode_key`) | **PASS** |
| Tam sayfa yenileme sonrası persistence | **PASS** |
| Elle stok miktarı alanı bulunmadığı | **PASS** |
| RLS altında `authenticated` owner yazmaları | **PASS** |

Maliyet sorgusu yok · service role kullanılmadı · `.env.local` okunmadı/yazılmadı ·
migration / RLS / RPC / seed / Supabase remote değişikliği yok.

Kullanılan DEV test verisi (silinmedi, olduğu gibi duruyor): `TEST TLC Studio` markası,
`TEST Keten Crop Bluz` ürünü (`TEST-KETEN-CROP`, Crop Toplar, ₺1.250,00, Aktif),
`TEST Beden` (S, M) ve `TEST Renk` (Siyah) seçenekleri, iki varyant, bir dahili
(`TLC2026000001`) ve bir harici (`8690000000012`) barkod. İlk denemede yanlışlıkla eklenen
`Sarıfatih` markası da kayıtta kalmıştır.

#### Şeffaflık notları

- **Marka ve ürün ilk denemede onaylanan test verisiyle oluşturulmadı.** İlk girişte farklı
  değerler yazıldı, sonra UI üzerinden düzeltildi ve final durum doğrulandı. Bu sonuç
  **"first-pass clean" değildir.**
- **KDV oranı doğrulanmış değildir.** Ürün satırındaki `%0` mevcut `products.tax_rate`
  varsayılanıdır; smoke sırasında hiçbir vergi değeri yazılmadı ve katalog ekranları vergi
  yazmaz. Bu değer Things Like Crop'ın gerçek KDV oranı olarak kabul edilmemelidir.
- **Gerçek cross-tenant testi DEFERRED.** Rastgele UUID denemesi yalnızca nesne kapsamı ve
  veri sızmaması kontrolüdür; gerçek test ikinci bir işletme ve o işletmeye ait bir kullanıcı
  gerektirir.
- **Bulunamayan ürün ekranı içerik olarak doğru, ancak HTTP 200 döner.** Next akış yaptığı
  için kabuk gönderildikten sonra `notFound()` durum kodunu değiştiremiyor; bu **gerçek bir
  404 PASS değildir.**

### Faz 3 manuel smoke (2026-09-09, DEV Supabase, owner oturumu)

Tedarikçiler + Mal Kabul + Stok Görünümü modülü tarayıcıdan sürüldü. Her adım hem DOM'dan
okunarak hem dev sunucu logundan doğrulandı. **TRY kapsamı için FULLY VERIFIED**; bu ifade
non-TRY veya rol testlerini kapsamaz.

| Alan | Sonuç |
|---|---|
| Tedarikçi listesi · oluşturma · yinelenen ad reddi · düzenleme · e-posta/not persistence | **PASS** |
| Taslak oluşturma (`rpc_create_goods_receipt`) | **PASS** |
| `receipt_number` sunucuda üretiliyor (`fn_next_sequence`), sıralı `GR-2026-000001` / `GR-2026-000002` | **PASS** |
| `business_id` / `status` / `receipt_number` client input değil | **PASS** |
| TRY belgede `exchange_rate = 1` | **PASS** |
| Satır ekleme / güncelleme | **PASS** |
| Yinelenen varyant yeni satır üretmiyor (`UNIQUE(goods_receipt_id, variant_id)`) | **PASS** |
| Taslak yenileme sonrası persistence | **PASS** |
| İşleme öncesi özet | **PASS** |
| Onay kutusu guard'ı | **PASS** |
| Boş taslak UI post guard'ı (kutu işaretlense de CTA kapalı) | **PASS** |
| İşleme (`rpc_post_goods_receipt`) | **PASS** |
| İşlenmiş belge salt-okunur | **PASS** |
| İşlenmiş belgede ikinci POST eylemi yok | **PASS** |
| İşlenmiş belgede geri alma / iptal CTA'sı yok | **PASS** |
| Taslak iptali ayrı davranış olarak | **PASS** |
| Pre-smoke baseline S=0 / M=0 doğrulandı | **PASS** |
| Mal kabul deltası S **+5** / M **+3** | **PASS** |
| SELLABLE · ON_HAND · RESERVED · AVAILABLE | **PASS** |
| Stok detayı · hareket geçmişi · belgeye link | **PASS** |
| Stok araması: ürün adı / SKU / barkod | **PASS** |
| Filtreler: kategori · marka · şube · stok durumu | **PASS** |
| Stok ekranında değiştirilebilir miktar alanı/eylemi yok | **PASS** |
| Stok ekranında maliyet sızıntısı yok | **PASS** |

#### Read-only SQL ile doğrulanan backend değerleri

Aşağıdakiler `supabase db query --linked` ile **yalnız okuma** olarak doğrulandı; DEV'e hiçbir
yazma yapılmadı.

| Doğrulama | Değer |
|---|---|
| `goods_receipt_items` S | qty 5 · unit_cost 400 · fx_rate_snapshot 1 · unit_cost_base 400 · total_cost_base 2000 |
| `goods_receipt_items` M | qty 3 · unit_cost 420 · fx_rate_snapshot 1 · unit_cost_base 420 · total_cost_base 1260 |
| Toplam base | **3.260 TRY** |
| `variant_cost_pools` | S: `on_hand_qty` 5 / `total_value_base` 2000 · M: 3 / 1260 |
| `supplier_account_entries` | `GR-2026-000001` → `entry_type='liability'`, `amount_base` 3260, currency TRY |
| `goods_receipts` durumları | `GR-2026-000001` posted · `GR-2026-000002` cancelled |

#### DEV test kayıtları (silinmedi)

Faz 2: `TEST TLC Studio`, `TEST Keten Crop Bluz`, `TEST Beden` / `TEST Renk` seçenekleri, iki
varyant, dahili + harici barkod, ve ilk denemede eklenen `Sarıfatih` markası.
Faz 3: `TEST Supplier Phase 3`, `GR-2026-000001` (TEST-FTR-001, posted),
`GR-2026-000002` (TEST-EMPTY-GUARD, cancelled).

İşlenmiş belge değişmez olduğu için bu kayıtlar **çöp değil, DEV audit fixture'ı** olarak
bırakılmıştır. Silme SQL'i veya cleanup script'i yazılmamıştır.

#### Faz 3 kapsam sınırları

- **Non-TRY / FX manuel smoke DEFERRED** — DEV'de kullanılabilir FX kaydı yok; kur uydurulmadı,
  `rpc_set_fx_rate` çağrılmadı, FX verisi seed edilmedi.
- **`sales_staff` manuel rol smoke DEFERRED** — ikinci hesap yok. Owner oturumuyla gözlenen
  davranış yalnız frontend gizlemesidir; cross-role security PASS olarak adlandırılmamıştır.
- **Gerçek cross-tenant manuel test DEFERRED** — ikinci işletme ve kullanıcı gerekiyor.

### Pilot dağıtım notu (2026-09-09)

BoutiqueOS **https://butikos.parlakmediatech.com.tr** adresinde yayında. Vercel deploy
başarılı, özel alan adı geçerli, Supabase Auth'un Site URL ve Redirect URL ayarları bu alan
adına göre güncellendi. Vercel'e yalnız `NEXT_PUBLIC_SUPABASE_URL` ve
`NEXT_PUBLIC_SUPABASE_ANON_KEY` tanımlandı; service-role anahtarı eklenmedi.

**Kritik kapsam notu:** bu dağıtım **DEV Supabase projesine bağlı bir pilot / canlı test
ortamıdır**. **Ayrı bir production Supabase projesi henüz kurulmamıştır.** Canlı adresten
yapılan her yazma DEV verisine gider ve DEV'deki `TEST *` fixture kayıtları (bkz. yukarıdaki
"DEV test kayıtları") bu adresten görünür. Gerçek production'a geçiş ayrı bir Supabase
projesi, o projeye migration apply, yeni bir owner kullanıcısı ve ayrı ortam değişkeni seti
gerektirir.

Dağıtım anında açık kalan doğrulamalar değişmedi:
**non-TRY FX manuel smoke DEFERRED** · **`sales_staff` manuel rol smoke DEFERRED** ·
**gerçek cross-tenant manuel smoke DEFERRED**.

### Faz 3 açık teknik borçlar

| # | Borç | Not |
|---|---|---|
| GAP-2 | `rpc_reverse_goods_receipt` NOT_IMPLEMENTED (ADR-10 / D-2) | İşlenmiş belgede geri alma UI'ı bilinçli olarak yok |
| GAP-3 | Birleşik stok view'ı yok | Varyant + `v_stock_by_bucket` + `v_stock_available` birleştirmesi uygulamada |
| GAP-4 | Post sırasında FX `fx_rates` ile DB seviyesinde doğrulanmıyor | UI günlük kurdan sapmayı uyarır ama engellemez |
| T-15 | Belge toplamları uygulamada aggregate ediliyor | `RECEIPT_LIST_LIMIT` ile sınırlı |
| T-16 | `getVariantStock()` şube başına ayrı sorgu atıyor | 1–2 şubede sorun değil |
| T-17 | `v_stock_available` yalnız `sellable` kovası için availability tanımlar | Diğer kovalarda rezerve/uygun tanımsız |
| T-18 | `lib/catalog/errors.ts` re-export shim | Davranış aynı, tek kaynak `lib/db-errors.ts` |


### Faz 2 açık teknik borçlar

| # | Borç | Not |
|---|---|---|
| T-1 | Birincil barkod değişimi atomik değil | `uix_barcode_primary` kısmi unique index; temizle + işaretle iki ayrı çağrı. Atomik RPC migration gerektirir |
| T-2 | Ürün listesi toplamları uygulamada hesaplanıyor | Varyant sayısı ve fiyat aralığı bellekte; liste 200 ürünle sınırlı |
| T-3 | `rpc_create_variant` `status` parametresi almıyor | Varyant her zaman `active` doğar |
| T-4 | Varyant seçenek kombinasyonu düzenlenemiyor | Güvenli yol yok; arşivle + yeniden oluştur |
| T-5 | ~~`products` / `product_variants` `updated_at` trigger'ı yok~~ — **DÜZELTME (2026-09-09): bu kayıt yanlıştı** | `trg_updated_at`, `20260908000001_core_schema.sql` sonundaki dinamik `DO` bloğunda `EXECUTE format('CREATE TRIGGER trg_updated_at …')` ile kuruluyor ve `businesses`, `branches`, `profiles`, `suppliers`, `products`, `product_variants`, `goods_receipts` tablolarını kapsıyor. İlk denetimde `^CREATE TRIGGER` grep'i dinamik bloğu görmediği için eksik raporlandı. Faz 2 server action'larının `updated_at`'i açıkça yazması **zararsız ama gereksiz** (trigger zaten `now()` ile üzerine yazıyor); bu aşamada refactor edilmiyor |
| T-6 | İstek başına birden çok Supabase istemcisi kuruluyor | `loadCatalogContext()` tekrar tekrar `createClient()` çağırıyor |
| T-7 | Token refresh + cache-header yolu doğrulanmadı | Faz 1'den devam; token süresi dolmadan tetiklenmiyor |
| T-8 | `w32time` başlangıç türü `Manual` | Saat kayarsa `JWT issued at future` geri döner |
| T-9 | `getUser()` üç yerde | `lib/tenant.ts:51`, `app/page.tsx:8`, `app/login/page.tsx:12` |
| T-10 | Marka silme yok | Yanlış eklenen marka UI'dan temizlenemiyor |
| T-11 | Bulunamayan ürün HTTP 200 döner | Streaming kaynaklı; içerik doğru |
| T-12 | DEV test verisi duruyor | `TEST *` kayıtları ve `Sarıfatih` markası; temizlik ayrıca planlanmalı |
| T-13 | Dev sunucusu bellek baskısında zombi bırakıyor | Port 3000 tutulu kalıp `Jest worker` / `EPIPE` ile 500 dönebiliyor; yeniden başlatmadan önce port kontrolü şart |
| T-14 | Gerçek cross-tenant testi DEFERRED | İkinci işletme + kullanıcı gerekiyor |

**Migration disiplini:** 001–04 remote'ta kayıtlı olduğu için artık yerinde düzenlenmez.
Her şema/RPC değişikliği yeni timestamp'li migration ile gider (`20260908000005_*.sql`).

## 16. Faz 8A — Mal kabul + iniş maliyeti motoru (2026-09-15)

### Envanter denetimi → karar
| Alan | CURRENT | REQUIRED | Uygulanan |
|---|---|---|---|
| Mal kabul | `goods_receipts/_items` (Faz 3), `rpc_create/post_goods_receipt`, POST birim alış maliyetini pool'a yazar, borç = fatura toplamı; `rpc_reverse_goods_receipt` `NOT_IMPLEMENTED` stub | ek masraf, dağıtım, iniş maliyeti, gözden geçirme, ters kayıt | `goods_receipt_charges` (tür, tutar+kur, maliyete dahil?, borç modu, ayrı tedarikçi), başlıkta `allocation_method`/`reviewed_*`/`review_hash`/`posted_*`, satırlarda `allocated_charge_base`/`landed_unit_cost_base`/`landed_total_cost_base`; `rpc_post_goods_receipt` **aynı imzayla** değiştirildi |
| Maliyet | `fn_post_to_cost_pool` giriş için değer ister | iniş maliyetli giriş | pool'a `landed_total`, deftere iniş birim maliyeti (`inventory_movement_costs`); sıfır maliyetli stok girişi imkânsız (masrafsız 0 TRY satır yine 0 maliyet — bilinçli, kullanıcı girdisi) |
| Borç | `supplier_account_entries` liability, reference `goods_receipt` | değerlemeden ayrı, tekrarsız | fatura tedarikçisi: fatura + `add_to_invoice` masraflar (tek kayıt, orijinal para birimi); `separate_supplier`: masraf başına kendi tedarikçisine (`goods_receipt_charge`); `no_liability`: hiç; ters kayıt aynı tutarları `credit` olarak (`goods_receipt_reversal`) |
| Yarış / tekrar | header FOR UPDATE, `INVALID_STATE` | çift POST, bayat taslak | ikinci POST `INVALID_STATE`; gözden geçirme parmak izi POST'ta yeniden hesaplanır (`STALE_DRAFT`); ters kayıt belge başına UNIQUE + `uix_movement_gr_reversal_item` |
| Roller | procurement yazar, manager+ maliyet görür | ters kayıt yetkisi | masraf/gözden geçirme/POST procurement; ters kayıt owner/manager; sales_staff hiçbir mal kabul verisini görmez |
| KDV | modellenmemiş | açık/yapılandırılabilir | modellenmedi; tutarlar belgedeki gibi girilir, UI bunu söyler |

### Mimari
`20260916090000_phase8a_landed_cost`: enum'lar `charge_kind` (freight/customs/insurance/handling/other), `charge_liability_mode` (add_to_invoice/separate_supplier/no_liability), `charge_allocation_method` (invoice_value_proportional/quantity_proportional/equal_per_line/manual). `goods_receipt_charges` (amount>0, currency+exchange_rate → `amount_base` generated, `include_in_landed`, `payee_supplier_id` yalnız separate modda — CHECK; trigger'lar business_id/created_by/posted-guard; RLS SELECT procurement, yazma procurement+aktif işletme). `goods_receipt_reversals` (receipt UNIQUE, reason ≥3, `value_removed_base`; istemci yazamaz, immutable). `fn_goods_receipt_allocation` (satır başına pay; manual → `NOT_IMPLEMENTED`; tutar yöntemi ve tüm satırlar 0 → `ALLOCATION_BASIS`) + `_fixed` (kalanı en büyük paya katar, toplam tam eşit) + `fn_goods_receipt_hash` (md5: başlık kur/para birimi/yöntem + satırlar + masraflar). `rpc_goods_receipt_review` (doğrular: durum, şube, tedarikçi, TRY kuru, boş belge, `CHARGE_CURRENCY`, masraf tedarikçisi aktif; damgalar; önizlemeyi döndürür), `rpc_post_goods_receipt` (NOT_REVIEWED/STALE_DRAFT; satır+pool+defter+borç tek transaction), `rpc_reverse_goods_receipt(uuid, text)` (posted only, ALREADY_REVERSED, REASON_REQUIRED, INSUFFICIENT_STOCK; hareketler `goods_receipt_reversal_item`, alacaklar `goods_receipt_reversal`). `20260916100000_phase8a_receipt_preview_rpc`: `rpc_goods_receipt_preview` (STABLE; aynı hesap, yazmaz; `review_current`).

UI: `/app/mal-kabul/[id]` taslak = başlık → satırlar (390'da kart, ≥640'ta tablo) → varyant ara/ekle → **Ek masraflar** (tür, açıklama, tutar, para birimi+kur, borç modu, ayrı tedarikçi, maliyete dahil) → **Dağıtım ve iniş maliyeti** (yöntem seçimi, DB önizlemesi: satır başına birim/masraf payı/iniş birim/iniş toplam; toplamlar; oluşacak tedarikçi borçları; "Gözden geçir" — belge değişince kırmızı "yeniden gözden geçirin") → İşleme özeti (onay kutusu + yalnız gözden geçirme güncelken açık POST). İşlenmiş görünüm: iniş kolonları, masraflar, `posted_*` toplamları, manager+ için ters kayıt paneli (neden + onay), ters kaydedilmiş belgede banner. Hata çevirileri `lib/db-errors.ts`.

### Testler
T64 (**77**): yetki envanteri; masraf ekleme/silme (procurement), yabancı tenant masrafı "parent not found"; tutar yöntemi dağıtımı (2500 fatura, 350 dahil masraf → A 140 / B 140 / C 70; iniş 114/228/570), bank fee maliyet dışı; gözden geçirmesiz POST `NOT_REVIEWED`; satır ve masraf düzenlemesinden sonra `STALE_DRAFT`; POST: başlık toplamları 2500/350/2850, satır iniş değerleri, pool'lar iniş MWA'sında, defter maliyetleri, borç: fatura tedarikçisi 2750 (2500+250) tek kayıt + gümrük tedarikçisi 100, `no_liability` hiç; önizleme `review_current`; GBP belge (kur 40) + adede orantılı 750/250 → iniş 650; eşit dağıtım 500/500; manual `NOT_IMPLEMENTED`; `CHARGE_CURRENCY`; 1000/3 kalanı tam toplanır; tüm satırlar 0 → `ALLOCATION_BASIS`, adet yöntemiyle 25; stock_staff POST ✓ / ters kayıt ✗, sales_staff hiç, çapraz tenant ✗; ters kayıt: alacaklar −2750/−100, pool 0/0, orijinal satırlar değişmedi, ikinci ters kayıt `ALREADY_REVERSED`, unique index 23505, tüketimden sonra `INSUFFICIENT_STOCK`. Toplam **808/0**; `receipt_double_post_run.ps1` PASS (A işledi, B `INVALID_STATE`, tek hareket / tek borç 440 / pool 4/440); satış yarışı ve sayım çift-post PASS; `test:auth` 62/0; lint_sql 0/0; lint/typecheck/build temiz; secret scan 0.

### Sentetik canlı smoke (fixture `ZZ E2E RECEIVING TEST`, alias owner, uzantısız Chrome, 390 px)
R1 tek satır (S ×10 @100, masrafsız): gözden geçirmeden POST (REST) `NOT_REVIEWED`; gözden geçir → POST → iniş 100/1000, borç 1000; ikinci POST `INVALID_STATE`; işlenmiş başlığa PATCH 0 satır, masraf INSERT `IMMUTABLE`. R2 üç satır (S×10@100, M×5@240, L×2@400) + masraflar: 0 ve −50 tutar reddedildi, ayrı tedarikçi seçilmeden reddedildi, nakliye 300 faturaya, gümrük 150 ZZ Kargo'ya, banka 30 borçsuz+maliyet dışı, GBP sigorta faturaya → gözden geçirmede `CHARGE_CURRENCY` (silindi); tutar dağıtımı 150/180/120 → iniş 115/276/460; gözden geçirildikten sonra L 2→3 → ekranda "yeniden gözden geçirin", POST kapalı, REST POST `STALE_DRAFT`; yeniden gözden geçir (3400 fatura, 450 masraf, 3850 iniş; borç ZZ Tekstil 3700 + ZZ Kargo 150) → POST → satırlarda 6 haneli değerler toplamı tam 450. R3 GBP belge kur 40 (S×3@£10, M×1@£30) + 400 TRY iç nakliye ZZ Kargo'ya: tutar yöntemi 200/200 → adede orantılı 300/100 → iniş 500/1300; manual seçimi "henüz uygulanmadı" (önizleme + gözden geçirme reddi); POST → borç London £60 (2400 TRY) + Kargo 400. R4 taslak iptal. R1 ters kayıt: kısa neden ile buton kapalı; "yanlış tedarikçi faturası" → banner, stoktan düşülen 1579,28 (10 × o anki MWA 157,93), alacak −1000; ikinci ters kayıt `ALREADY_REVERSED`. Çapraz tenant (gerçek TLC taslağı, salt okuma/red): UI 404, preview/review RPC `FORBIDDEN`, masraf INSERT "parent not found", masraf/mal kabul SELECT boş. Roller: sales_staff → `/app`'e yönlendirme, RPC'ler FORBIDDEN, ZZ pool/hareket maliyeti/masraf/ters kayıt/borç görünmez; stock_staff → belge + iniş kolonları + masraflar görünür, ters kayıt paneli yok, ters kayıt RPC FORBIDDEN, pool/hareket maliyeti görünmez. Pool/defter/borç doğrulaması SQL ile birebir. Responsive 390/768/1440: liste, taslak (masraf+önizleme), işlenmiş, ters kaydedilmiş — yatay taşma yok; 390'da satırlar kart. Tenant sonra archived + `cancelled` (geçmiş korunur).

### TLC
Before/after snapshot **birebir aynı** (max_updated 2026-09-09 10:10:30); 9 taslak dokunulmadı (0 masraf, 0 gözden geçirme, 0 ters kayıt, yöntem kolonu varsayılan). Gerçek fatura satırı içe aktarılmadı.

### Kapanış sertleştirmesi — maliyet görünürlüğü (2026-09-15, `20260916120000_phase8a_receiving_cost_visibility`)
**Bulunan sızıntı yolları (stock_staff):** (1) `goods_receipt_items` SELECT politikası `fn_is_procurement` → `unit_cost`, `total_cost_original`, `fx_rate_snapshot`, `unit_cost_base`, `total_cost_base`, `allocated_charge_base`, `landed_*` REST ile okunabiliyordu (canlı: `200 [{unit_cost:400, landed_unit_cost_base:452.94}…]`); (2) `goods_receipt_charges` SELECT procurement → tutarlar; (3) `goods_receipt_reversals` SELECT procurement → `value_removed_base`; (4) `goods_receipts.posted_invoice_total_original / posted_charges_base / posted_landed_total_base`; (5) `rpc_goods_receipt_preview` ve `rpc_goods_receipt_review` procurement rolüne iniş maliyeti döndürüyordu; (6) sunucu sayfası `getReceipt` bu kolonları herkes için seçip `receipt` prop'uyla RSC payload'una seriyordu, `/app/mal-kabul` listesi `unit_cost` toplamını gösteriyordu; (7) `upsertReceiptLineAction` stock_staff'tan maliyet kabul ediyordu. `variant_cost_pools`, `inventory_movement_costs`, `supplier_account_entries` zaten manager+ idi (sızıntı yok).

**Düzeltme (DB):** `unit_cost` NULL'a açıldı (stock_staff adet kaydeder, manager fiyatlar; fiyatsız satır `COST_REQUIRED`, asla 0). Kolon düzeyi yetki: `goods_receipt_items` (maliyet kolonları), `goods_receipts` (`posted_*`), `goods_receipt_reversals` (`value_removed_base`) `authenticated` rolü için SELECT dışı — politika, embed, `select=*` hiçbiri ulaşamaz; owner+manager `rpc_goods_receipt_financial(uuid)` ve `rpc_goods_receipt_list_totals(uuid[])` ile okur (SECURITY DEFINER, `fn_require_role owner|manager`). `goods_receipt_charges` politikaları manager+. Trigger'lar: `trg_cost_role_gri` (`unit_cost` yazan manager değilse `FORBIDDEN`), `trg_financial_role_gr` (`allocation_method`). `rpc_goods_receipt_upsert_line(receipt, variant, qty, cost=NULL)`: procurement adet, maliyet parametresi manager+, NULL mevcut fiyatı korur. Preview/review/POST manager+. Service role kullanılmadı.

**Düzeltme (uygulama):** `caps.canManageCost` (owner|manager); `getReceipt`/`listReceipts` maliyeti yalnız bu rol için ve yalnız RPC'den yükler (`cost_visible`, `missing_cost_lines`); stock_staff formunda maliyet alanı yok ve sunucu eylemi alanı hiç okumaz; editörde masraf/dağıtım/gözden geçirme/POST yerine "Mal kabul özeti" + taslak iptali; işlenmiş görünümde maliyet kolon/satırları yalnız `cost_visible`; ters kayıt banner'ında değer yalnız manager; liste "Tutar" kolonu manager+ ("n satır fiyat bekliyor" işareti, fiyatsızken ₺0,00 yerine "—").

**Testler:** T08 (stock_staff adet ✓ / maliyet RPC ✗ / doğrudan yazma ✗ / `unit_cost` SELECT 42501 / review-post ✗; manager `COST_REQUIRED` → fiyatlar → post; posted kolonlar ve `rpc_goods_receipt_financial` stock_staff'a 42501), T35aa rol ayrımı, T64a stock_staff masraf/dağıtım/preview ✗, T64d finansal RPC + liste toplamı, T64e manager doğrudan fiyatlı satır yazabilir ama `unit_cost` SELECT edemez (kolon yetkisi), T64f stock_staff posted toplam/iniş/liste toplamı ✗ ve operasyonel belge ✓, T64h ters kayıt olgusu ✓ değeri ✗, sales_staff ✗, çapraz tenant ✗. Toplam **848/0**; concurrency 3/3 PASS; auth 62/0; lint_sql 0/0.

**Canlı smoke (fixture `ZZ E2E COST VISIBILITY TEST`, alias sırayla stock_staff → manager → stock_staff):** stock_staff: liste "Tutar" kolonu yok, liste ve belge RSC payload'unda hiçbir maliyet anahtarı/₺ yok; taslak oluşturdu, arama listesinde ve satırlarda maliyet girdisi yok, S×5/M×2 kaydetti, adet güncelledi, ikinci taslağı iptal etti; REST `unit_cost` / `select=*` / `posted_*` / embed / `value_removed_base` → 42501, masraflar `[]`, pool/hareket maliyeti/borç `[]`, preview/review/post/financial/list_totals → 403 FORBIDDEN, `unit_cost` PATCH → "purchase cost is entered by owner or manager", `allocation_method` PATCH → FORBIDDEN, masraf INSERT → RLS; `rpc_goods_receipt_upsert_line` maliyetli → 403, maliyetsiz → 200. Manager: listede "2 satır fiyat bekliyor", satırlarda "fiyat girilmedi", POST kapalı, review RPC `COST_REQUIRED`; fiyatladı (adet korundu), 60 nakliye ekledi, önizleme 36/24 → iniş 106/212, gözden geçirdi, işledi (pool 6/636 + 2/424, borç 1060); RSC payload'unda maliyet mevcut (beklenen); `unit_cost` doğrudan SELECT manager için de 42501. stock_staff işlenmiş belgede: başlıklar Ürün/SKU/Adet, bilgi satırlarında maliyet yok, ₺ yok, masraf/ters kayıt paneli yok, RSC payload'unda maliyet yok; ters kayıt RPC 403. Responsive 390/768/1440 taşma yok. Fixture archived + cancelled; **TLC before/after birebir aynı**, 9 taslak dokunulmadı.

### Ertelenen (8A)
Elle dağıtım (`manual` + `manual_allocation_base` alanı hazır, RPC reddeder), tedarikçi ödeme kaydı, kısmi ters kayıt / tedarikçi iadesi (ters kayıt mal çıkmışsa reddeder), KDV modeli, gerçek TLC fatura eşleme, PO, OCR.

## 17. Faz 9A — POS temeli (2026-09-16)

### Envanter denetimi → karar
| Alan | CURRENT | REQUIRED | Uygulanan |
|---|---|---|---|
| Satış motoru | Rev 3 `fn_sale_core` (idempotent, pool kilitli, sunucu fiyatlı, indirim yetkili, hareket öncesi MWA ile COGS, bölünmüş ödeme + para üstü, kasa hareketleri) — **canlı hiç çalıştırılmamıştı** | terminalin ihtiyaçları | motor korundu; `sales.salesperson_id` (kasiyer ≠ satıcı, `own` görünürlüğü ikisini de kapsar), `stock_staff` satış tamamlayamaz, yabancı varyant pool kilidinden **önce** reddedilir (`INVALID_VARIANT`), açık kasa oturumu o kasada satan her üyeye görünür, `cash_registers.device_ref` |
| RPC yüzeyi | `rpc_complete_sale` (business/branch parametreli) | terminal için dar yüzey | `rpc_pos_complete_sale(session, items, payments, client_transaction_id, customer?, salesperson?, discount_reason?, note?, device?)` — işletme ve şube oturumdan çözülür, `p_business_id` kabul edilmez (PGRST202), `client_transaction_id` zorunlu (`CLIENT_TRANSACTION_REQUIRED`); `rpc_pos_members` (yalnız ad + satabilir mi) |
| UI | yok | telefon öncelikli terminal | `/app/pos`: kasa tanımlama + çekmece açma/kapama (manager+ form), kuyruklu tarayıcı girişi (Enter, tenant barkodu, bilinmeyen kod = uyarı, tekrar = +1, geri al), stoklu ürün arama, sepet (adet, yetkili fiyat düzenleme), müşteri + satıcı seçimi, bölünmüş ödeme + para üstü, tek atomik tamamlama, fiş `/app/pos/satis/[id]`. POS'ta maliyet/MWA/COGS **hiç yüklenmez** |

### Mimari
`20260916140000_phase9a_pos_foundation`: `sales.salesperson_id`, `pol_sales_select` (+ salesperson), `pol_rs_select` (açık oturum her üyeye), `fn_sale_core` (17 parametre; 16 parametreli eski imza ince sarmalayıcı olarak kalır), `rpc_pos_complete_sale`, `rpc_pos_members`, `fn_can_see_sale_id` (+ salesperson).

`20260916150000_phase9a_safeupdate_fix` — **canlı bulgu.** Supabase API oturumlarında `pg-safeupdate` etkindir ve ayar SECURITY DEFINER fonksiyonlara da taşınır; `fn_sale_core` ve `fn_return_core` geçici tablolarını `DELETE FROM _sale_lines;` ile temizliyordu → her canlı satış `21000 DELETE requires a WHERE clause`. Yerel harness'ta safeupdate yok, 911 assertion'lık gate bunu göremedi; satış Faz 3 smoke'unda hiç denenmemişti. Düzeltme: her iki fonksiyonun son tanımlarının **birebir kopyası** + o tek satırda `WHERE true` (önceki tanımlarla diff alındı: yalnız 1'er satır). `tools/lint_sql.py` 5c kuralı: bir fonksiyonun **son** tanımında WHERE'siz `DELETE`/`UPDATE` = ERROR (fix dosyası olmadan 2 hata, fix ile 0 — negatif test yapıldı). DEV'de `pg_proc` doğrulaması: 17 parametreli `fn_sale_core` ve `fn_return_core` `WHERE true` içeriyor, çıplak DELETE kalmadı.

### Testler
T66 (**63**): roller, oturum görünürlüğü, yan etkisiz doğrulama hataları, nakit/bölünmüş/son birim satışları, çift gönderim replay, sonraki mal kabul MWA'yı 260'a taşısa da COGS 200 (2×MWA 100) değişmez, indirim kaydı, kapalı oturum, çapraz şube stoğu, değişmezlik. Toplam **911/0**; `pos_last_unit_run.ps1`, `pos_double_submit_run.ps1`, `concurrency_run.ps1` PASS; `test:auth` 62/0; `lint_sql` 0/0; lint/typecheck/build temiz.

### Sentetik canlı smoke (fixture `ZZ E2E POS TEST`, alias `64cfef13…`, uzantısız Chrome, DEV'e bağlı canlı adres)
Fixture: 2 ürün / 5 varyant (elbise S/M/L 250 TRY, etek S/M 400 TRY), EAN13 barkodlar (biri baştaki sıfırlı), 2 müşteri, stok `rpc_post_inventory_adjustment` ile (A 5@100 → +4, B 2@120 → +3, C 1@90 → +1, D 0, E yalnız `damaged` 3).

**Fix öncesi** (09:58): kasa tanımlama, çekmece 200 TRY ile açma, tarayıcı kuyruğu (A,A,B,A,bilinmeyen → S=3/M=1, "tanınmadı" uyarısı, geri al, satır kaldır), ödeme aşaması ve para üstü hesabı UI'da doğru; **her tamamlama 21000**.

**Fix sonrası** (10:36→): 390 px UI ile S-000001 (A×2, nakit 600 → para üstü 100), S-000002 (B×1 kart tam), S-000003 (A×2+B×1 = 750; 350 nakit + 400 kart; kart fazlası UI'da bloklu), stokta olmayan D ve hasarlı-tek E aramada "stokta yok"/ekle kapalı, taranan D sunucuda `INSUFFICIENT_STOCK`; son birim A satıldı, tekrarı reddedildi; iki terminalin C'nin son birimi yarışı → tek satış + `INSUFFICIENT_STOCK`. 1440 px: S-000007 (nakit tam), **S-000010 fiyat düzenleme 250→200** (sepette −₺50; fişte "indirim −₺50,00 (liste ₺250,00)"; `discount_amount` 50, `unit_price_at_sale` 200, `list_price` 250). Aynı `client_transaction_id` ile çift gönderim → aynı `sale_id`, ikinci yanıt `replayed:true`, DB'de tek satış (S-000006); aynı kimlik farklı sepet → `IDEMPOTENCY_CONFLICT` (409/23505). Sunucu redleri (hepsi yan etkisiz): `PAYMENT_SHORT`, `PAYMENT_MISMATCH` (kart fazlası), `INVALID_PRICE` (liste üstü), `CLIENT_TRANSACTION_REQUIRED`, `EMPTY_CART`, `DUPLICATE_ITEM`, `PRICE_CHANGED` (istemci fiyatı bayat), `INVALID_ITEM` (adet 0), `FX_RATE_MISSING` (USD, kur yok), `INSUFFICIENT_STOCK` (hasarlı E), `INVALID_VARIANT` (gerçek TLC varyantı sepette), `INVALID_REGISTER_SESSION`, `PGRST202` (`p_business_id` verilemez), `INVALID_CUSTOMER`, `INVALID_SALESPERSON`. Tamamlanmış satışa REST: `sales`/`sale_items`/`sale_payments`/`inventory_movements`/`cash_movements` PATCH/DELETE 0 satır, doğrudan `sales` INSERT RLS 42501, satış değişmedi. Owner `sale_item_costs` okur (manager+).

**sales_staff** (max_discount 0): terminal var, kasa/çekmece formları yok, RSC payload'unda maliyet anahtarı yok, sepette fiyat girdisi yok; S-000011 (kart, satıcı = diğer üye) ve S-000012 (müşteri ZZ Ayşe + satıcı diğer üye + not; fişte kasiyer/satıcı/müşteri ayrı; müşteri `total_spent` 250 / `order_count` 1); sunucudan indirim → `DISCOUNT_NOT_AUTHORIZED`, kur override → `FX_OVERRIDE_NOT_AUTHORIZED`, `sale_item_costs`/`sale_costs`/`variant_cost_pools`/`inventory_movement_costs` boş, `rpc_void_sale` FORBIDDEN, kasa INSERT RLS, satış PATCH 0 satır, TLC satışları boş. **stock_staff**: `/app/pos` → `/app`, satış `FORBIDDEN: role stock_staff cannot complete sales`, `rpc_pos_members` `can_sell:false`.

**Kapanış**: 390 px formu, sayılan 2740 / beklenen 2750 (200 açılış + 2650 nakit − 100 para üstü) → `variance −10`, not kaydedildi, oturum `closed`; kapalı oturuma satış `REGISTER_CLOSED`, yeniden kapatma `INVALID_STATE`; RS-000002 açıldı ve tam sayımla kapandı. Responsive 390/768/1440 terminal + fiş: yatay taşma yok. DB mutabakatı: 12 satış / 15 adet = defterde 15 satış hareketi; havuzlar alınan − satılan (S 1@100, M 0, L 0); her satırda COGS o anki MWA (100/120/90); `sale_costs` = Σ satır. Tenant sonra ürünler arşiv + audit'li `cancelled` (geçmiş korunur).

### TLC
Before/after snapshot **birebir aynı** (0 satış, 0 kasa oturumu, 0 nakit hareketi, 0 müşteri; havuz 8 / 3.260; borç 3.260; mal kabul 9 draft / 1 posted / 5 cancelled; max_updated 2026-09-09 10:10:30). **Gerçek TLC satışı yapılmadı.**

### Kapanış sertleştirmesi — kasa oturumu yetkisi (2026-09-16, `20260916170000_phase9a_register_session_roles`)
**Karar:** çekmece açma/kapama V1'de **owner/manager**; sales_staff açık oturumda satar, oturum açamaz/kapatamaz; stock_staff hiçbiri. İleride tenant ayarıyla genişletilebilir (şimdi eklenmedi).

**Önce:** `rpc_open_register_session` ve `rpc_close_register_session` `fn_require_member` (şubeye pinli olmayan her aktif üye). UI: kasa *tanımlama* manager+ idi ama çekmece açma formu (`OpenSessionForm`) ve "Kasayı kapat" düğmesi ile `openSessionAction`/`closeSessionAction` **`canSell`** — yani sales_staff UI'dan da açıp kapatabiliyordu (yukarıdaki §17 canlı smoke'unda sales_staff için form görünmemesinin tek nedeni oturumun zaten açık olmasıydı; bu bölümün önceki sürümündeki "UI formu yalnız manager+" ifadesi yalnız kasa tanımlama için doğruydu). Denetim: oturum/sayım mutasyonu yalnız bu iki RPC; `register_sessions`/`register_session_currency_counts`/`cash_movements` üzerinde istemci INSERT/UPDATE/DELETE politikası yok; reopen/adjustment RPC'si yok; `cash_movements`'ı yalnız satış/iade/iptal çekirdekleri açık oturuma yazar.

**Sonra (DB):** her iki RPC son tanımının birebir kopyası + tek satır `fn_require_role(business, owner|manager)` (diff ile doğrulandı). `fn_require_role → fn_require_member` sırası korunduğu için askıya alınmış tenant hâlâ `BUSINESS_SUSPENDED` (T36o). Satış tamamlama (`rpc_pos_complete_sale`/`fn_sale_core`) **değişmedi**. Sonuç: kasiyer çekmeceyi hiç açmadığından 35e görünürlüğü gereği kapalı çekmeceyi ve `cash_movements`'ı görmez (T21d/T40w/x buna göre güncellendi: açık oturum 9A politikasıyla görünür, çekmece mutabakatı yöneticinin).

**Sonra (uygulama):** `openSessionAction`/`closeSessionAction` `canManageRegisters`; çekmece açma formu, "Başka bir kasa aç" ve "Kasayı kapat" yalnız manager+; sales_staff açık oturum yokken "Kasayı yönetici açar" metnini görür.

**Testler:** T22 (çekmeceyi yönetici açar/kapatır, sales_staff açma/kapama `FORBIDDEN`, oturum açık kalır), T67 (**24**): sales_staff/stock_staff/yabancı tenant açma `FORBIDDEN` ve hiçbir yazma yok; owner açar (açılış 100), aynı kasaya ikinci açılış `REGISTER_ALREADY_OPEN`; sales_staff açık oturumu görür ve satar (kasiyer u3, nakit yöneticinin çekmecesine), sales_staff/stock_staff/yabancı tenant kapatamaz ve stock_staff/yabancı satamaz, ret sonrası oturum açık + sayım boş; owner kapatır (beklenen 350 / sayılan 340 / fark −10, closed_by owner); kapalı oturuma satış `REGISTER_CLOSED`; manager açar/kapatır, ikinci kapatma `INVALID_STATE`; üç tabloda SELECT dışı politika 0; kasa/oturum RPC'si tam 2. Toplam **941/0**; üç yarış PASS; auth 62/0; lint_sql 0/0; lint/typecheck/build temiz; secret scan 0.

### Açık (9A)
- Satış görünürlüğü `own` kapsamında `sold_by`/`salesperson_id = auth.uid()` ile karar verilir; kullanıcı sonradan `stock_staff` olsa da kendi kestiği satışları okumaya devam eder (tasarım gereği, rol sızıntısı değil).
- Profil adı boş üye satıcı listesinde ve fişte "—" görünür (`profiles.full_name`); gerçek kullanıcılarda ad dolu.
- POS içinde iade/değişim/iptal UI'ı yok (`rpc_void_sale`, `rpc_process_return` motoru var), rezervasyon dönüştürme UI'ı yok, fiş yazdırma/e-fiş yok, çevrimdışı kuyruk yok, döviz ödeme için işletme kur kaydı UI'ı yok.
- `pg-safeupdate` yerel harness'ta yok; WHERE'siz DELETE/UPDATE artık yalnız linter ile yakalanır (Supabase-local modu Docker beklediği için hâlâ DEFERRED).

## 18. Faz 9B — İade / değişim temeli (2026-09-16)

### Envanter denetimi → karar
| Alan | CURRENT (Rev 3) | REQUIRED | Uygulanan (`20260916190000_phase9b_returns_exchange`) |
|---|---|---|---|
| İade belgesi | `returns` + `return_items` (tek INSERT ile tamamlanır, 003'teki immutability döngüsüyle donuk; istemci INSERT yetkisi vardı) | değişmez, düzeltmesi yeni belge | `authenticated` için INSERT/UPDATE/DELETE yetkisi kaldırıldı (yalnız RPC); `client_transaction_id` + `request_fingerprint` + `reason_code` kolonları |
| Çekirdek | `fn_return_core`: pencere, kategori `is_final_sale`, `OVER_RETURN` (sale_item FOR UPDATE), disposition (varsayılan quarantine; sellable/damaged manager+), havuza **orijinal `unit_cost_at_sale`** ile giriş, `refund_cash_out`; her üyeye açık | politika, ürün dışlaması, neden, idempotency, yetki | `fn_return_core_ext` (birebir kopya + 9B kuralları); eski imza sarmalayıcı → Rev 3 `rpc_process_return`/`rpc_process_exchange` aynı kuralları kullanır |
| Politika | `businesses.settings` düz anahtarlar (`money_refund_allowed`, `store_credit_allowed`, `exchange_window_days`) | tenant düzeyi, genişleyebilir | `fn_return_policy`: `settings.return_policy` {allow_exchange, allow_cash_refund, allow_store_credit, exchange_window_days, receipt_required, reason_required, downgrade_treatment}; eksik anahtarda eski düz anahtarlar (TLC satırına dokunulmadı), ek anahtarların belgeli varsayılanları (exchange true, receipt_required true, reason_required false, downgrade `block`) |
| Dışlama | yalnız kategori | ürün + kategori | `products.is_final_sale` (ürün) — ikisi de `FINAL_SALE` |
| Neden | serbest metin | yapısal, tenant-genişletilebilir | `return_reasons` (platform varsayılanı `business_id NULL`: beden_olmadi / renk_degisimi / kusurlu_urun / musteri_tercihi / yanlis_urun / diger; tenant satırları manager+ RLS); `reason_code` doğrulanır (`INVALID_REASON`), politika zorunlu kılabilir (`REASON_REQUIRED`); not serbest |
| COGS | havuz girişi tarihsel maliyetle; ayrı kayıt yok | açık ters kayıt | `return_item_costs` (satır başına `unit_cost_at_sale` × adet; manager+ SELECT, RPC yazar, donuk) |
| Değişim | `rpc_process_exchange`: return + replacement sale tek transaction, kredi yeni satışa; kredi > yeni toplam → `CREDIT_EXCEEDS_TOTAL` | politika tanımlı davranış | `rpc_pos_exchange`: `fn_sale_quote` ile yeni toplam önceden hesaplanır, kredi > toplam ise `downgrade_treatment`: `block` → `EXCHANGE_DOWNGRADE_BLOCKED`; `cash_refund` → uygulanan kredi = toplam, fark `refund_cash_out` (açık kasa + `allow_cash_refund` şart); `store_credit` → `NOT_IMPLEMENTED`; işlendikten sonra `sale.total = quote` doğrulanır (`INTEGRITY`) |
| Yetki | her aktif üye iade/değişim yapabiliyordu | açık | **owner/manager tamamlar**; sales_staff hazırlar (`rpc_return_eligibility`, `rpc_pos_find_sales`); stock_staff hiçbiri |
| Giriş noktaları | business/branch parametreli | oturumdan/satıştan türetilen | `rpc_pos_return(sale, items, type, ctx, reason?, note?, session?, method?)` (işletme+şube satıştan; `client_transaction_id` zorunlu; replay/`IDEMPOTENCY_CONFLICT`), `rpc_pos_exchange(session, sale, return_items, new_items, payments, ctx, reason?, note?, customer?, salesperson?, device?)` (işletme+şube oturumdan; satış aynı şubede olmalı — `BRANCH_MISMATCH`) |
| Hazırlık | yok | operatör ekranı | `rpc_return_eligibility(sale)`: satır başına `returnable_quantity` + durum (`ELIGIBLE` / `WINDOW_EXPIRED` / `EXCLUDED` product\|category / `NOTHING_LEFT` / `SALE_VOIDED`), politika + `days_left`, önceki iadeler, nedenler — maliyet yok; `rpc_pos_find_sales(business, mode, q)`: fiş no (tam), barkod (pencere+1 gün içindeki satışlar), müşteri (ad/telefon) — **`own` görünürlük kapsamını fiş düzeyinde bilinçli aşar** (tezgâhtaki müşteri fişi kimin kestiğine bakmaz), satan roller, tenant üyeliği; `rpc_return_document(return)` (RLS görünürlüğü) |

### Muhasebe davranışı (belgelenmiş)
Orijinal satış hiç değişmez. İade: `credit_value_base = Σ unit_price_at_sale × adet` (ciro tersi); `return_item_costs.line_cost_base = unit_cost_at_sale × adet` (COGS tersi, **tarihsel**); havuz `fn_post_to_cost_pool(+adet, unit_cost_at_sale)` ile aynı tutarda değer kazanır, defter `customer_return` hareketi `return_item`'a referans verir (→ iade belgesi → sale_item → orijinal satış); sonraki MWA = (mevcut değer + tarihsel maliyet) / adet. Para iadesi yalnız `refund_amount_base` + `refund_method`; nakit ise `refund_cash_out` (açık oturum şart), kart/diğer yalnız kayıt (ödeme sağlayıcısı iadesi yok). Değişimde kredi yeni satışın `credit_applied_base`'ine gider, `amount_due = total − kredi`; fark ödemesi normal satış ödemesi; kredi fazlası politikaya göre nakit iade ya da red. Mağaza kredisi V1'de yok.

### Testler
T68 (**98**): A politikası eski anahtarlardan (değişim-only, 3 gün, block), B politikası açık (nakit, 14 gün, neden zorunlu, cash_refund); uygunluk (ELIGIBLE 3 / EXCLUDED product / EXCLUDED category / WINDOW_EXPIRED days_left 0, maliyet anahtarı yok), arama (fiş/barkod/müşteri/kısa sorgu/maliyetsiz), stock_staff ve yabancı tenant FORBIDDEN/NOT_FOUND; yetki (sales_staff/stock_staff/yabancı tenant hiçbir şey yazamaz); yönetici redleri (REFUND_NOT_ALLOWED, STORE_CREDIT_NOT_ALLOWED, USE_EXCHANGE_RPC, CLIENT_TRANSACTION_REQUIRED, EXCHANGE_WINDOW_EXPIRED, FINAL_SALE ×2, EXCHANGE_DOWNGRADE_BLOCKED, INVALID_REASON, INVALID_ITEM, INVALID_VARIANT, INVALID_CUSTOMER, BRANCH_MISMATCH, OVER_RETURN, PAYMENT_SHORT — hepsi yan etkisiz); pahalıya değişim (kredi 250 → 400, fark 150 nakit, quarantine, belge/satır/defter/bağlantı); **tarihsel COGS**: MWA +5@200 ile yükseltildikten sonra iade 100'den girer, havuz +1 / +100, satış COGS kaydı değişmez; sellable/damaged koşulları; çift gönderim replay + farklı payload 409; son birim → OVER_RETURN, NOTHING_LEFT, VOID_BLOCKED; tenant nedeni ekleme/kullanma, yabancı tenant nedeni RLS, sales_staff ekleyemez; tenant B: neden zorunlu, yöntem zorunlu, açık oturum zorunlu (yabancı oturum dahil), kısmi nakit iade (10, `refund_cash_out` −10), replay, kartla ikinci kısmi (kayıt, nakit yok), over-return, **downgrade cash_refund** (kredi 25 → yeni 10, uygulanan 10, iade 15 nakit), kasa aritmetiği 50+30−10−15=55 ve kapanış, kapalı oturumda iade/değişim redleri; görünürlük (kasiyer kendi satışının iadelerini görür, COGS tersini görmez; stock_staff/yabancı hiç), immutability (returns/return_items/return_item_costs/replacement sale), privilege envanteri. Toplam **1040/0**. Concurrency: `return_last_unit_run.ps1` (A değiştirdi, B `OVER_RETURN`; tek iade/hareket/satış) ve `exchange_double_submit_run.ps1` (B `replayed:true`; tek iade) PASS; önceki beş yarış PASS. T24–T29 aktörü yöneticiye taşındı (T24z: sales_staff iade/değişim yapamaz).

### Sentetik canlı smoke (fixture'lar `ZZ E2E RETURNS TEST` — değişim-only/3 gün/block — ve `ZZ E2E RETURNS CASH TEST` — nakit iade/14 gün/neden zorunlu/cash_refund; alias `64cfef13…`; uzantısız Chrome; sonra ikisi de archived + audit'li `cancelled`)
A tam iade (1/1 değişim → NOTHING_LEFT) · B kısmi 1/3 (UI 390: fiş no araması otomatik açar, satır "Değişim için uygun · 3 adet iade edilebilir", varsayılan koşul karantina, neden, "Değişim", barkodla Ceket, özet 250/400/150, "Farkı nakit" → "Ödeme tam.", tamamla → R-000006 belgesi: orijinal/yeni satış bağlantıları, neden, "Yeni satışa aktarılan ₺250") · C ikinci kısmi (hasarlı; "+" iade edilebilir adette durur; önceki iadeler listelenir) · D üçüncü birimde 2 istendi → `OVER_RETURN` · E 4 günlük satış: UI "Değişim süresi dolmuş", değişim düğmesi kapalı; sunucu `EXCHANGE_WINDOW_EXPIRED` · F ürün ve kategori dışlaması: UI "Bu ürün değişim kapsamı dışında", sunucu `FINAL_SALE` · G/H/I hasarlı/karantina/satılabilir koşulları defterde doğru kovaya (S: quarantine+1, damaged+1, sellable+1) · J pahalıya değişim (B/C/I) · K ucuza değişim: UI "…fark iadesi yapılamıyor" uyarısı + tamamla kapalı; sunucu `EXCHANGE_DOWNGRADE_BLOCKED` · L (nakit tenant): neden seçilmeden tamamla kapalı ("iade nedeni zorunlu"), yöntem listesi nakit/kart/diğer, nakit iade 100 → belge "İade edilen (Nakit) ₺100", `refund_cash_out` −100; **fark nakit iadesi** (Çanta 100 → Şal 60: "fark ₺40 kasadan nakit iade edilir", iade 40 nakit, yeni satış 60/0 borç); sunucu: `REASON_REQUIRED`, kart iadesi kayıt (nakit hareketi yok), `STORE_CREDIT_NOT_ALLOWED`, `OVER_RETURN`, düz iade çift gönderim replay + farklı yöntem 409 · M kasa kapalı: sunucu `REGISTER_CLOSED`, UI "Açık kasa oturumu yok…" ve düğmeler kapalı · N sales_staff: arama/uygunluk/seçim çalışır, koşul listesi yalnız karantina, özet "Yönetici onayı gerekir", tamamla düğmesi yok; sunucu `rpc_pos_exchange`/`rpc_pos_return`/eski `rpc_process_exchange` FORBIDDEN; `return_item_costs` boş; neden ekleme RLS · O stock_staff: `/app/pos/iade` → `/app`; uygunluk/arama/iade/değişim FORBIDDEN · P: TLC satış kimliği `NOT_FOUND`, TLC varyantı sepette `INVALID_VARIANT`, başka satışın satırı `INVALID_ITEM`, `p_business_id` = TLC → FORBIDDEN, düz iadede TLC satışı `NOT_FOUND` · Q son iade edilebilir birim yarışı: tek 200 + `OVER_RETURN`, iki iade (ilk + kazanan) · R çift gönderim: aynı `return_id`, `replayed:true`, farklı payload 409, tek iade. RSC payload'larında (`/app/pos/iade`, belge) maliyet anahtarı yok. Responsive 390/768/1440 arama, ürünler, değişim sepeti, özet, belge: yatay taşma yok. DB mutabakatı (iki tenant): iade satırı = defter hareketi (12/13 birim; 5/6), her `return_item_costs` = defter maliyeti = havuz deltası (tarihsel 100 / 40), değişim bağlantılarında uyumsuzluk 0, over-return 0, havuz adedi = defter, nakit: ZZRET yalnız satış nakdi; ZZRCASH satış 500 / iade −240 (100 + 40 + 100).

### TLC
Before/after snapshot **birebir aynı**; TLC'de 0 iade, 0 tenant nedeni, `return_policy` anahtarı eklenmedi, `businesses` satırı değişmedi (updated_at 2026-09-09). Gerçek TLC iadesi/değişimi/satışı yapılmadı.

### Ertelenen (9B)
Mağaza kredisi defteri (`allow_store_credit` ve `downgrade_treatment='store_credit'` politika olarak var, RPC `NOT_IMPLEMENTED`), ödeme sağlayıcısı (kart) iadesi (yalnız kayıt), fişsiz iade (`receipt_required=false` UI'da kullanılmıyor; sunucu her zaman satış ister), farklı şube kasasında değişim (`BRANCH_MISMATCH`), iptal (void) UI'ı, komisyon, fiş yazdırma, e-ticaret, mali entegrasyon.

## 19. Faz 10A — Müşteri CRM + rezervasyon temeli (2026-09-16)

### Mevcut model denetimi → karar
| Alan | CURRENT (Rev 3) | REQUIRED | Uygulanan (`20260916210000_phase10a_customers_reservations`, `20260916220000_phase10a_customer_archive_role`) |
|---|---|---|---|
| Müşteri | tenant kapsamlı `customers`; `phone NOT NULL` + `UNIQUE(business_id, phone)`; whatsapp/instagram/email/birth_date/notes/is_active; satış RPC'lerinin tuttuğu `total_spent/order_count/last_purchase_at` önbellekleri; her üye okur/yazar (stock_staff dahil) | telefon/e-posta isteğe bağlı, normalize arama, kopya = uyarı, kaynak, PII rolleri | `phone` NULL olabilir, sert tekillik kaldırıldı; **üretilen kolonlar** `phone_normalized` (`fn_normalize_phone`: yalnız rakam, 5…→905…, 05…→905…, 0090…→90…), `email_normalized` (lower/trim), `instagram_normalized` (baştaki @ atılır, lower); `source` (`customer_sources`: platform varsayılanı walk_in/instagram/whatsapp/website/referral/other + tenant satırları, trigger doğrular); `created_by` damgası; `chk_customer_name`/`chk_customer_email`; RLS **owner/manager/sales_staff** (`fn_is_selling`), stock_staff hiç; DELETE yok; önbellek kolonlarına istemci UPDATE yok (kolon yetkisi); arşiv (is_active) yalnız manager+ (trigger, 20260916220000) |
| Kopya | telefon tekilliği (sessiz engel) | güçlü uyarı, sessiz birleştirme yok, yönetici onayıyla bilinçli kopya | `rpc_customer_duplicates(business, phone?, email?, instagram?, exclude?)` normalize eşleşmeleri döndürür; uygulama eşleşme varken kaydı reddeder, **manager+ "farklı kişi" onayıyla** kaydeder; DB kısıt koymaz (tenant içi), işletmeler arası tekillik yok |
| Arama | yok | ad/telefon/e-posta/Instagram, sınırlı | `rpc_customer_search(business, q, limit≤50)` — ILIKE ad, normalize telefon/e-posta/Instagram; <2 karakter boş; satan roller |
| Rezervasyon | `reservations` (active/converted/cancelled/expired, `expires_at` zorunlu, `converted_to_sale_id`, cancelled_*), `reservation_items`, yalnız RPC yazar; `rpc_create_reservation` (her üye, hold_name'li), `rpc_cancel_reservation`; düzenleme/expire RPC'si yok | tenant+şube, müşteri, referans, lifecycle, atomik oluşturma/düzenleme/iptal, süre | `fulfilled_at/fulfilled_by/updated_by`; `fn_guard_reservation` (aktif olmayan satır **dondurulur**; converted → sale zorunlu, aktif satıra sale yazılamaz), `fn_guard_reservation_items`; `rpc_pos_reservation_create(branch, customer, items, expires?, note?, source?)` (işletme şubeden, müşteri zorunlu+aktif, satan roller, varsayılan süre `settings.reservation_default_hours` yoksa 48 s, ≤90 gün), `rpc_reservation_update` (aktif+süresi dolmamış; eski∪yeni varyant kilidi; satırlar atomik değiştirilir), `rpc_reservation_cancel`, `rpc_reservations_expire` (temizlik); RLS satan roller; `converted` = FULFILLED (şema adı korundu — satış çekirdeği yeniden kopyalanmadı) |
| Müsaitlik | **zaten otoriter:** `available = SELLABLE defter − ACTIVE & süresi dolmamış rezerve` (`fn_reserved_qty`, `v_stock_available`); hold hareket yazmaz; satış çekirdeği rezervasyonu aynı transaction'da converted yapar; satış ve rezervasyon aynı `variant_cost_pools` satırlarını kilitler | tek hesap, hareket yok, damaged/quarantine rezerve edilemez | korundu; `fn_reservation_hold` yalnız sellable kovayı ölçer; POS araması zaten `available_quantity` |
| POS teslim | `fn_sale_core` `p_reservation_id` alır (aktif, süresi dolmamış, aynı şube, her rezerve satır ≥ adet, converted + link) ama `rpc_pos_complete_sale` parametre taşımıyordu | POS'ta rezervasyon seçimi → sepet → tek transaction | `rpc_pos_complete_sale(... , p_reservation_id)` (eski 9 parametreli imza DROP); UI `?rezervasyon=` ile satırları ve müşteriyi yükler, rezerve satır sepetten çıkarılamaz/azaltılamaz, satış tamamlanınca rezervasyon `converted` |

Kısmi teslim: **hepsi ya da hiçbiri** (sepet her rezerve satırı en az rezerve adette içermeli; fazla eklenebilir); farklı istenirse önce aktif rezervasyon düzenlenir.

### UI
`/app/musteriler` (son 30 + sunucu araması), `/app/musteriler/yeni` (ad, telefon, e-posta, Instagram, kaynak, not; yazarken kopya uyarısı + bağlantı; manager onay kutusu; `?geri=` ile rezervasyon akışına dönüş), `/app/musteriler/[id]` (kimlik/iletişim, düzenle, rezervasyon aç, satış sayısı/son satış, **yalnız manager+ ciro/COGS/brüt kâr** — `sale_costs` gerçek verisi, sales_staff'a hiç yüklenmez; rezervasyonlar; `sales`'tan türetilen satış geçmişi + iade bağlantıları). `/app/rezervasyonlar` (aktif/geçmiş), `/app/rezervasyonlar/yeni` (390: müşteri → ürün (barkod/arama, müsait adet) → onay (süre varsayılan 48 s, kanal, not) → rezerve), `/app/rezervasyonlar/[id]` (düzenle adet/süre/not, iptal nedeni, "Kasada teslim et", süresi geçen aktif satır uyarısı). POS: bekleyen rezervasyon listesi + "Teslim et", rezervasyon banner'ı. Nav: Müşteriler, Rezervasyonlar. Hata sözlüğü: `INSUFFICIENT_AVAILABLE_STOCK`, `RESERVATION_*`, `INVALID_EXPIRY`, `INVALID_SOURCE`, `chk_customer_*`.

### Testler
T69 (**83**): normalize/normalizasyon vakaları, isteğe bağlı telefon/e-posta, geçersiz kaynak/e-posta/ad, aynı normalize telefonla ikinci kayıt + kopya probe (telefon/e-posta/Instagram/exclude), arama (ad/telefon parçası/e-posta/Instagram/kısa/limit, maliyet anahtarı yok), sales_staff düzenler ama önbellek/arşiv/silme/kaynak ekleme yapamaz, manager kaynak ekler + arşivler/geri alır, stock_staff 0 müşteri + FORBIDDEN, yabancı tenant 0 + FORBIDDEN + RLS; rezervasyon: varsayılan 48 s, RV numarası, satır birleştirme, müsaitlik 3→1 / 1→0, **hareket ve havuz değişmez**; redler (INSUFFICIENT_AVAILABLE_STOCK ×2, INVALID_CUSTOMER ×2, INVALID_BRANCH, INVALID_VARIANT, VARIANT_NOT_SELLABLE, INVALID_EXPIRY ×2, EMPTY_RESERVATION, INVALID_QTY, doğrudan INSERT 42501, stock_staff FORBIDDEN, yabancı tenant NOT_FOUND/INVALID_BRANCH) hepsi yan etkisiz; POS başkasının holdunu alamaz (INSUFFICIENT_STOCK) ama serbest birimi satar; düzenleme (üstü reddedilir + atomik, aşağı ok + süre/not/updated_by, yabancı varyant); iptal (anında serbest, actor/time/reason, tekrar/düzenleme INVALID_STATE, hareket yok, donuk, silinemez); **süre dolumu temizliğe bağımlı değil** (aktif ama süresi geçen satır müsaitliği düşürmez; teslim `RESERVATION_NOT_ACTIVE`, düzenleme `RESERVATION_EXPIRED`; `rpc_reservations_expire` 1 → expired, idempotent 0); POS teslim: `RESERVATION_MISMATCH`, başka şube/yabancı `INVALID_RESERVATION`, tek transaction'da satış + converted + link + fulfilled_at/by + müşteri, defter 2 hareket, müşteri önbelleği 1/600; teslim edilen: iptal/düzenleme/ikinci teslim reddi, donuk, sahte sale linki `INTEGRITY` ×2; privilege envanteri. Toplam **1123/0**. Concurrency: `reservation_last_unit_run.ps1` (A holdu aldı, B `INSUFFICIENT_AVAILABLE_STOCK`; tek hold, hareket 0) ve `pos_vs_reservation_run.ps1` (POS satışı kazandı, hold reddedildi, on_hand 0) PASS; önceki 7 yarış PASS.

### Sentetik canlı smoke (fixture `ZZ E2E CUSTOMER RESERVATION TEST`, alias `64cfef13…`, uzantısız Chrome; sentetik kişiler `ZZ Ayşe/Elif/Ece/Deniz Test`)
A müşteri oluşturma (390): telefon `0555 010 52 12` → `905550105212`, `@zzayse5212` → `zzayse5212`, kaynak Instagram, created_by alias · B `+90 555 010 5212` ile ikinci kişi: "Benzer kayıt var … aynı telefon", kaydet kapalı; yönetici onay kutusu → kaydedildi (aynı normalize telefonla 3 satır, birleştirme yok); sunucu onaysız kaydı reddetti · C e-posta kopyası (`AYSE…@test.com` vs `Ayse…@Test.com`) uyarısı, kaydet kapalı · D arama ad / telefon / `@instagram` / e-posta ile · E rezervasyon (390, <1 dk): müşteri araması → barkod → "1 adet müsait" → onay (süre 48 s) → RV belgesi; M 1→0 müsait, **hareket yok** · F çoklu (S×2 + Çanta) · G tutulan ürün aramada "müsait değil"/ekle kapalı; sunucu `INSUFFICIENT_AVAILABLE_STOCK` · H iptal (neden, anında serbest, hareket yok) · I süresi geçen aktif satır: UI "Süresi geçti (bekliyor)" uyarısı, müsaitlik temizlik olmadan geri döndü, teslim/düzenleme reddi, `rpc_reservations_expire` → 1, geçmiş listesinde "Süresi doldu" · J düzenleme S 2→1 + not (updated_by) · K S×5 → `INSUFFICIENT_AVAILABLE_STOCK`, satırlar değişmedi · L son L birimi yarışı (available 1): tek 200 + `INSUFFICIENT_AVAILABLE_STOCK` · M POS satışı vs hold (Çanta son birim): satış kazandı, hold reddedildi, on_hand 0 · N POS `?rezervasyon=`: banner, rezerve satırlar sepette (azaltma/çıkarma engelli), müşteri dolu, kart ile tamamla · O rezervasyon `converted` + `converted_to_sale_id` + `fulfilled_at/by`, satışta müşteri, M 0/0/0, detayda "Teslim edildi · S-…" · P müşteri sayfası: satış geçmişi (satır özeti), rezervasyonlar, **owner ciro 600 / COGS 240 / brüt kâr 360** · Q TLC müşteri kimliği `INVALID_CUSTOMER`, TLC şubesi `INVALID_BRANCH`, TLC business ile arama/probe FORBIDDEN, TLC müşterileri `[]`, TLC'ye INSERT RLS · R TLC varyantı `INVALID_VARIANT`; sahte `converted_to_sale_id` PATCH 42501 · S stock_staff: `/app/musteriler` ve `/app/rezervasyonlar` → `/app`; müşteri/rezervasyon `[]`, arama/probe/oluşturma FORBIDDEN, INSERT RLS · T sales_staff: müşteri oluşturur, kopya uyarısında onay kutusu yok ve kayıt kapalı, sayfada finansal blok yok (RSC'de COGS/maliyet anahtarı yok), rezervasyon oluşturur/düzenler/iptal eder, önbellek PATCH 42501, arşiv → `FORBIDDEN: only owner or manager…` (trigger), maliyet tabloları `[]`, TLC müşterileri `[]` · U iptal edilen/teslim edilen: cancel/update `INVALID_STATE`, PATCH/DELETE 42501, ikinci teslim `RESERVATION_NOT_ACTIVE`. Responsive 390/768/1440 (müşteri listesi/oluşturma/detay, rezervasyon oluşturma/liste/detay, POS teslim): taşma yok. DB mutabakatı: 10 müşteri (hepsi created_by dolu, 6 farklı normalize telefon), rezervasyon 4 aktif/3 converted/15 cancelled/1 expired, converted'lerin hepsi bağlı ve müşteri eşleşiyor, hareketler yalnız `adjustment` + `sale` (hold kaynaklı 0), havuz = defter, `available = sellable − reserved` her satırda. Fixture: holdlar iptal, ürünler arşiv, audit'li `cancelled` (müşteri/rezervasyon geçmişi korundu).

### TLC
Bu oturum TLC'ye hiçbir yazma yapmadı (alias/admin hesaplarıyla TLC'de 0 ürün, 0 satış, 0 müşteri, 0 rezervasyon; `reservation_default_hours` anahtarı eklenmedi). **Ancak** 10A sırasında gerçek TLC owner hesabı (`3918a623…`) canlı adresten iki işlem yaptı: 15:03 kasa oturumu + 1 kalemlik 1.250 TRY satış (S-2026-000001), 15:37 "FATİH PARLAK" adlı 18 varyantlı ürün. Faz 10A before/after karşılaştırması bu iki insan işlemi dışında birebir aynıdır (customers 0, reservations 0, mal kabul 9/1/5, borç 3.260). Bu değişiklikler bu oturumdan bağımsızdır ve geri alınmadı. Ayrıntılı salt-okunur mutabakat ve yeni yetkili taban çizgisi: §13 (2026-09-17).

### Ertelenen (10A)
stock_staff için `v_stock_available` rezervasyonları göremediğinden `available = sellable` görünür (CRM'siz rol için bilinçli; stok sayfaları kovaya göre on_hand gösterir); rezervasyon düzenlemede UI'dan yeni satır ekleme (adet/süre/not düzenlenir; yeni ürün için yeni rezervasyon), kısmi teslim, bekleme listesi, otomatik expire job (cron; doğruluk buna bağlı değil), WhatsApp/Instagram otomasyonu, sadakat, komisyon, gerçek TLC müşteri içe aktarımı.
