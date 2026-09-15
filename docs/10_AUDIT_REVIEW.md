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
| Sayım stub'ları | `inventory_counts/_lines` (Rev 3, 0 satır, RPC/UI yok, istemci yazabilir) | yaşam döngüsü draft/counting/review/posted/cancelled | yeni `stock_counts/_lines/_scans` (RPC-only); stub'lar dokunulmadan superseded |
| Roller | procurement = owner/manager/stock_staff; adjustment RPC manager+ | POST yetkisi | sayma/inceleme procurement; POST + iptal owner/manager; sales_staff hiç görmez |

### Mimari
`20260915150000_phase7a_stock_count_engine`: `stock_count_status/type` enum'ları; `stock_counts` (şube, tür full/cycle, not, created/reviewed/posted/cancelled_by/at, `review_ledger_watermark`), `stock_count_lines` (variant × bucket tekil; `expected_quantity` inceleme snapshot'ı, `counted_quantity` NULL = çözümsüz, `zero_confirmed`, `posted_delta`, `movement_id`), `stock_count_scans` (append-only olay günlüğü: kind scan/undo/set/zero_confirm, delta, `client_transaction_id` tekil → replay no-op, `device_id`, `client_at`, server `created_at` — çevrimdışıya hazır alanlar). RPC'ler: `rpc_stock_count_create` (procurement, `SC-YYYY-000001`), `_scan` (±n), `_set_quantity` (tam miktar; 0 = açık sıfır onayı), `_review` (FULL: defterde olup taranmayan her variant×bucket için çözümsüz satır; herkes için expected snapshot; tekrar çağrı = yeniden hesap), `_reopen`, `_cancel` (manager+), `_post` (manager+). `fn_guard_stock_count(_line)` trigger'ları posted/cancelled belgeleri herkese karşı dondurur. RLS: SELECT procurement; INSERT/UPDATE/DELETE grant'i yok.

### POST (tek transaction)
rol → işletme aktif → şube → durum = review (posted → `ALREADY_POSTED`) → çözümsüz satır yok (`UNRESOLVED_LINES`) → pool kilidi → her satır için `fn_bucket_qty` yeniden okunur, snapshot'tan farklıysa `STALE_COUNT` ("Stok sayım sırasında değişti. Farkları yeniden hesaplayın.") → fark ≠ 0 satırlara `fn_post_to_cost_pool` + `fn_ledger_post` → satırlara `posted_delta/movement_id` → header posted. Çift gönderim: header kilidinde bekleyen ikinci çağrı `ALREADY_POSTED` alır; ayrıca unique index ikinci hareketi imkânsız kılar.

### Testler
T63 (**87**): yetki envanteri, tarama/tekrar/replay/undo/negatif red, aynı varyant iki durumda iki satır, yabancı varyant red, draft/counting/review/cancelled'da sıfır hareket-maliyet-borç-mal kabul, FULL inceleme çözümsüz satır, `UNRESOLVED_LINES`, açık sıfır onayı, `COST_REQUIRED` (boş pool) bloklar ve hiçbir şey yazmaz, araya giren hareket → `STALE_COUNT` → yeniden inceleme, atomik post (5 hareket; MWA doğrulaması: eksik 4/400, fazla 2/140, net sıfır 3/150, sıfır onay 0/0), `ALREADY_POSTED`, posted/cancelled immutability (maintenance dahil), unique index, cycle sayım yalnız kendi satırları, iptal kaydı, pasif şube red, çapraz tenant (okuma/yazma/şube/varyant/business_id/hareket sahteciliği) red, stock_staff POST red, sales_staff hiç. Toplam **731/0**; concurrency `count_double_post_run.ps1` PASS (A işledi, B `ALREADY_POSTED`, tek hareket), satış yarışı PASS; `test:auth` 25/108/27/30/62; lint/typecheck/build temiz; secret scan 0.

### Sentetik canlı smoke (fixture `ZZ E2E STOCK COUNT TEST`, alias owner, uzantısız Chrome, 390 px, gerçek klavye/tarayıcı girişi)
Açılış stoğu adjustment RPC ile: A 5@400, B 3@420, C 2@350, D sellable 2 / damaged 1 @380, E 1@350, F stoksuz. Sayım: A 4 ardışık okutma (queue) → 4, 5. okutma aynı satır → 5, geri al → 4; bilinmeyen barkod uyarı + hiçbir şey oluşmadı + alan temizlendi; C ×2, D sellable ×1; durum → Hasarlı, D ×2 (ayrı satır); F ×1; arama (barkodsuz) ile B +1 / −1; incelemeye geç → E (defterde 1, taranmadı) **çözümsüz**, "Sayımı işle" kapalı; sayıma dön, B ×3; inceleme: filtreler (farklar/eksik/fazla/sayılmamış/0 onay); E için "0 adet olarak doğrula" → cnt 0; POST → `COST_REQUIRED` (F, pool boş) — hiçbir şey yazılmadı; F maliyeti adjustment ile çözüldü → POST → `STALE_COUNT` → "Farkları yeniden hesapla" → POST: 7 satır, 4 hareket, −3 eksik, +1 fazla. Sonuç: A 4, B 3, C 2, D sellable 1 / damaged 2, E 0, F 1; pool A 4/1600, D 3/1140, C 2/700, E 0/0, F 1/350; tedarikçi kaydı/mal kabul yok. API: çift POST `ALREADY_POSTED`, posted satır update/delete/insert grant yok, TLC sayımı görünmez/oluşturulamaz, TLC varyantı sayılamaz, iptal edilen sayımlar korunuyor. Responsive 390/768/1440: liste, sayma, inceleme, sonuç — yatay taşma yok. Tenant sonra archived + audited RPC ile `cancelled`.

### TLC
Before/after snapshot (ürün/varyant/barkod/görsel/hareket/pool/borç/mal kabul/sayım) **birebir aynı**; TLC'de 0 sayım. Gerçek TLC sayımı yapılmadı.

### Ertelenen
Çevrimdışı senkron (alanlar hazır), çoklu sayaç (aynı sayımda cihaz bazlı ayrım `device_id` ile kayıtlı, UI yok), sayım sırasında beklenen miktarı gösterme (bilinçli gizli), sayım PDF/rapor, Rev 3 `inventory_counts` stub'larının kaldırılması, `COST_REQUIRED` fazlası için sayım içinden maliyet girişi (şimdilik ayrı adjustment).

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
