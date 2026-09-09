# BoutiqueOS — Rev 3 Schema & Security Audit

**Sürüm:** Rev 3 · 2026-09-08
**Kapsam:** `supabase/migrations/20260908000001..04`, `seeds/seed_things_like_crop.sql`, `tests/000_test_harness.sql`, `tests/005_verification_tests.sql`, `tests/concurrency/*`
**Durum:** **BACKEND GATE KAPANDI** · DEV Supabase'e uygulandı · **Frontend Faz 1 DOĞRULANDI**
(2026-09-08) · **Frontend Faz 2 ÜRÜN KATALOĞU DOĞRULANDI** (manuel DEV smoke, 2026-09-09) ·
Sıradaki modüller başlamadı

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
| Faz 3+ (Stok, Kasa, Tedarikçi, Raporlar…) | **READY FOR PHASE 3 PLANNING** — kodlama başlamadı |
| Deploy (Vercel) | yapılmadı |

Supabase-local ertelendiği için gerçek `auth.uid()` yolu DEV üzerindeki remote smoke ile doğrulandı;
Docker kurulduğunda `.\scripts\db_fresh.ps1 -Mode Supabase` ikinci bir doğrulama katmanı olarak koşulabilir.

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
