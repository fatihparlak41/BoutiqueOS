# BoutiqueOS — REV 3 PRE-FLIGHT REPORT

**Tarih:** 2026-09-08
**Kapsam:** 00/01/02/09/10 dokümanları, 000–005 SQL, seed, pilot-analiz.html
**Ortam notu:** Bu ortamda PostgreSQL yok ve ağ erişimi kapalı (psql/initdb yok, pglast kurulamadı). Aşağıdaki bulgular **statik okuma** ile üretildi. Hiçbir SQL çalıştırılmadı. Rev 3 yazıldıktan sonra da durum en fazla **READY FOR DEV APPLY / REQUIRES EXECUTION VERIFICATION** olabilir.

**Önemli:** Yüklenen dosyalar kendilerini "Rev 3" olarak etiketliyor ve 10_AUDIT_REVIEW birçok defekti "fixed/PASS" ilan ediyor. Bu doğru değil. Aşağıda bunları SQL'in gerçek içeriğine göre yeniden değerlendirdim; audit dokümanının kendisi de revize edilmelidir.

---

## A. Doğru uygulanmış mimari kararlar

Bunlar korunacak; yeniden yazılmayacak:

| Karar | Nerede | Durum |
|---|---|---|
| Ledger tabanlı stok, `inventory_movements` INSERT-only, bucket=sellable/quarantine/damaged | 002 | ✓ |
| IN_TRANSIT bucket değil; `transfer_held_inventory` + `carried_total_value_base` | 002 | ✓ |
| `variant_cost_pools` = business+branch+variant, `on_hand_qty`+`total_value_base` otoriter, CHECK'ler (qty≥0, val≥0, qty=0→val=0), `last_cost_base` yok | 002 | ✓ (Defect #9 kapalı) |
| Havuz koşul-nötr (SELLABLE+QUARANTINE+DAMAGED) yorumu | 002 comment + return RPC | ✓ (Defect #10 kapalı) |
| `fn_post_to_cost_pool`: negatif → RAISE, pre-movement MWA döner, tam tükenmede exact kalan değer, FOR UPDATE, composite sonuç | 002 | ✓ (Defect #2/#3 kapalı; bkz. E-3 küçük ek) |
| Maliyet ayrımı: `sale_item_costs` / `sale_costs` ayrı tablo, manager+ RLS; `sale_items`/`sales`'te maliyet yok | 002 | ✓ (kısmen — bkz. D) |
| Idempotency: `UNIQUE(business_id, client_transaction_id)` + payload hash + IDEMPOTENCY_CONFLICT | 002 | ✓ (bkz. F-3 yarış) |
| Server-authoritative `list_price`/`tax_rate` + PRICE_CHANGED | 002 | ✓ (kısmen — bkz. F-1) |
| Yardımcı fonksiyonlar (fn_is_member vb.) 002'nin başında, policy'lerden önce | 002 | ✓ (Defect #1 kapalı) |
| `sale_payments` currency/exchange_rate/amount_base kolonları | 002 | ✓ tablo (RPC tarafı hatalı, bkz. H-1) |
| `fx_rates` versiyonlu, INSERT-only, partial unique current index, `rpc_set_fx_rate` doğru sıra (lock→old false→insert→superseded_by), client INSERT policy yok | 003 | ✓ (Defect #20/#21 kapalı) |
| `goods_receipt_items.unit_cost_base` GENERATED değil, RPC tarafından set edilir | 001 | ✓ (Defect #24 kapalı) |
| `supplier_account_entries.amount_original` + currency + exchange_rate + amount_base | 001 | ✓ (Defect #22 tablo tarafı kapalı) |
| SECURITY DEFINER: search_path, auth.uid(), REVOKE PUBLIC, GRANT authenticated, `p_sold_by` kaldırıldı | 002/003/004 | ✓ (Defect #26 kapalı; #27 kısmen — bkz. D-6) |
| `returns`/`return_items`/`cash_movements` doğrudan client yazma policy'leri kaldırıldı | 002 | ✓ (Defect #28/#29 kapalı) |
| Register: `uix_one_open_session_per_register` partial unique | 002 | ✓ |
| Transfer: partial receipt yok (ADR-06), exact carried value | 002/004 | ✓ tasarım (RPC kırık, bkz. G) |
| GR reversal: açıkça NOT IMPLEMENTED stub (ADR-10) | 004 | ✓ (Defect #32 "deferred" olarak kapalı) |
| Seed: `default_tax_rate`, `default_reservation_hours`, `markup_multiplier`, accounting rolü yok | seed | ✓ (Defect #33 kapalı) |
| Composite FK: goods_receipts→branch, gri→variant, inventory_movements→branch/variant, sale_items→variant, vcp→branch/variant; trigger ile business_id doldurma | 001/002 | ✓ (kısmi — bkz. D-1) |

---

## B. Rev 2 SQL'de kalan çelişkiler (handoff kurallarına göre)

Handoff defect listesine göre gerçek durum:

| # | Defect | Gerçek durum |
|---|---|---|
| 4 | Client fiyat/tax güveni | **KISMEN**: list_price/tax_rate sunucudan; ama `unit_price` (gerçek satış fiyatı) tamamen client'tan alınıyor, hiçbir indirim yetkisi kontrolü yok. Sales_staff `unit_price: 0` gönderebilir. |
| 5 | Rezervasyon-adjusted AVAILABLE + lock | **KISMEN**: AVAILABLE hesabı var; ama rezervasyon dönüştürme (conversion) hiç yok — rezerve son birim satılamaz. Lock SQL'i derlenmiyor (C-1). |
| 6 | Idempotency fingerprint | ✓ ama hash sadece items+payments; branch/customer/discount/session dışarıda. Eşzamanlı aynı-key yarışında unique_violation fırlar (orijinal Sale dönmez). |
| 7 | Multi-currency payment INSERT | **AÇIK**: currency/rate yazılıyor **fakat** `exchange_rate` client'tan geliyor, fx_rates'e karşı doğrulanmıyor ve eksikse `COALESCE(...,1)` → "1 GBP = 1 TRY" sessizce oluşuyor. Handoff'un açık yasağı ihlal. |
| 8 | Maliyet sızıntısı | **AÇIK**: sales/sale_items temiz; ama `inventory_movements.unit_cost_snapshot`, `return_items.unit_cost_at_sale`, `goods_receipt_items.unit_cost/unit_cost_base`, `transfer_held_inventory.carried_total_value_base` tüm üyelere (SALES_STAFF dahil) SELECT açık. |
| 11 | 3 gün exchange window | ✓ (RPC'de var) — ama `COALESCE(...,3)` fallback; final-sale (bikini) kontrolü **yok**. |
| 12 | Over-return locking | **AÇIK**: sale_item FOR UPDATE var ama kontrol `qty > sale_item.quantity` — önceki iadeler toplanmıyor; ikinci iade ile over-return mümkün. |
| 13 | Return client güveni | ✓ variant sale_item'dan; refund_amount hesaplanmıyor (0 yazılıyor), `return_number` üretilmiyor (NOT NULL → INSERT patlar). |
| 14 | Disposition | ✓ quarantine + havuz kredisi; ama 'resellable' condition default'u anlamsız; state-change RPC yok. |
| 15 | "No money refund" semantiği | **AÇIK**: setting adı hâlâ `allow_cash_refund`; `store_credit` return_type serbest (doğrulanmamış). |
| 16 | Transfer ship AVAILABLE | **AÇIK**: sadece cost pool kontrolü (pool quarantine+damaged içerir) → quarantine stok "sellable" olarak sevk edilebilir, sellable bucket negatife düşer. Rezervasyon dikkate alınmıyor. |
| 17 | Transfer receive | Tasarım doğru; ama RPC yanlış kolon/status adları ile derlenmez; `received_at` set edilmiyor (held row temizlenmiyor). |
| 23 | Allocation ambiguous amount | **AÇIK**: `supplier_payment_allocations.amount` tek kolon, goods_receipt'e bağlı; liability/payment/base/fx ayrımı yok. RPC yok. |
| 25 | Composite FK yetersiz | **KISMEN**: bkz. D-1 liste. |
| 27 | Actor spoofing | **KISMEN**: `p_discount_authorized_by` client'tan alınıp `sales.discount_authorized_by`'a yazılıyor. |
| 30 | Register multi-currency | **KISMEN**: counts tablosu var; opening sadece TRY (`opening_cash` tek sayı), FX opening daima 0; close'da rate client'tan. |
| 31 | Register OPEN/CLOSE RPC | ✓ var; ama herhangi bir üye herhangi bir register'ı açıp kapatabilir; branch/şube kontrolü yok; açık session'da satış zorunluluğu yok. |

**Handoff'ta istenip SQL'de hiç olmayan RPC'ler:**
- `rpc_void_sale` (full void kuralları)
- `rpc_post_inventory_adjustment` (reason + cost source: CURRENT_MWA / LAST_PURCHASE_COST_CONFIRMED / MANUAL_COST)
- `rpc_change_stock_condition` (SELLABLE↔QUARANTINE↔DAMAGED, değer değişmez)
- `rpc_write_off` (DAMAGED → çıkış, değer düşer)
- Rezervasyon create/cancel/convert (şu an `reservations` FOR ALL member policy ile client serbestçe status/expires_at değiştiriyor)
- `rpc_record_supplier_payment` + allocation
- `rpc_post_supplier_return` (pilot kullanmıyor → stub/deferred kabul edilebilir; ama `supplier_returns` FOR ALL manager policy ile ledger'sız doğrudan yazım açık)
- Duplicate variant kombinasyon engeli (DB seviyesinde yok)

---

## C. Migration sırası / derleme tehlikeleri

1. **002 `rpc_process_sale` — derlenmez.** Lock bloğu `JOIN LATERAL (INSERT INTO ... RETURNING 1)` kullanıyor. PostgreSQL'de data-modifying statement yalnızca `WITH` içinde olabilir; FROM alt-sorgusunda INSERT **syntax error**. `CREATE FUNCTION` aşamasında migration durur. → Rev 3: önce ON CONFLICT DO NOTHING upsert, sonra `SELECT ... ORDER BY variant_id FOR UPDATE`.
2. **000 harness — `authenticated` rolü yok.** 002/003/004 `GRANT ... TO authenticated` içeriyor; vanilla Postgres'te rol yoksa migration patlar. Harness'a `CREATE ROLE anon/authenticated/service_role NOLOGIN` eklenmeli. Ayrıca RLS testleri için `SET ROLE authenticated` gerekli.
3. **004 — audit'in listelediği ~20 kolon/enum hatası** aynen duruyor: `movement_type`→`reason`, `unit_cost_base/total_cost_base/notes` yok, `quantity_received`/`unit_cost_original`/`total_cost_original` UPDATE (GENERATED), `v_receipt.currency`, `'invoice'` (enum: purchase), `'goods_receipt'`/`'return'` (enum: purchase_receipt / return_from_customer), transfer status `'pending'/'in_transit'` (enum: draft/shipped), `transfer_id`/`quantity_sent`/`shipped_by` THI kolonları, THI `from_branch_id/to_branch_id` NOT NULL eksik, `stock_transfer_lines.quantity_shipped/unit_cost_at_ship/carried_total_value_base` yok, `returns.sale_id/status/processed_at`, `return_items.disposition/unit_cost_at_return/quantity_returned`, `return_number` üretilmiyor.
4. **fn_lock_confirmed_goods_receipt** her UPDATE'i engelliyor → confirmed fişte `payment_status` asla `paid` olamaz. Trigger, "muhasebe alanları hariç" olacak şekilde daraltılmalı.
5. `t_cost_pool_result` unconstrained NUMERIC (02_DOMAIN: NUMERIC(12,4)) — çalışır ama tutarsız. NUMERIC politikası ile birlikte netleştirilecek.
6. Supabase'de `uuid-ossp` `extensions` şemasına kurulur; `SET search_path = pg_catalog, public` içinde çağrılan `uuid_generate_v4()` çözümlenmez (kolon default'ları DDL anında qualify edildiği için tablo default'ları güvende; ama fonksiyon gövdesinde doğrudan çağrı olursa kırılır). → Rev 3: `gen_random_uuid()` (pg_catalog, PG13+).
7. `fn_next_sequence` authenticated'a GRANT edilmiş ve membership kontrolü yok → Tenant A, Tenant B'nin sayaçlarını tüketebilir. Client'a GRANT kaldırılacak (sadece SD RPC'ler çağırır).
8. 005 tamamen yapısal; hiçbir davranış testi yok; D-04 testi superuser ile direkt INSERT yapıyor (RPC'yi test etmiyor). Test 2–34'ün büyük kısmı yazılmamış.

---

## D. Security / RLS tehlikeleri

1. **Composite FK eksik (Defect #25):**
   - `products.category_id / brand_id / supplier_id` (001'de "DEFERRED" yorumu ile açık bırakılmış — handoff izin vermiyor)
   - `option_values` business_id yok → `variant_option_values.option_value_id` cross-tenant olabilir
   - `barcodes (business_id, variant_id)`; business_id client'tan
   - `reservations` branch/customer, `reservation_items.variant_id` (business_id yok)
   - `sales` branch / customer / register_session; `returns` branch / original_sale / customer; `return_items` variant/sale_item
   - `stock_transfers` from/to branch; `stock_transfer_lines.variant_id`; `transfer_held_inventory` transfer/branch/variant
   - `cash_registers.branch_id`, `register_sessions` register/branch, `cash_movements.register_session_id`
   - `supplier_account_entries.supplier_id`, `supplier_payments.supplier_id`, `goods_receipts.supplier_id`, `supplier_returns`, `inventory_counts`, `business_members.branch_id`
2. **Maliyet sızıntısı (Defect #8 açık):** `inventory_movements.unit_cost_snapshot`, `return_items.unit_cost_at_sale`, `goods_receipt_items.unit_cost/_base`, `transfer_held_inventory.carried_total_value_base` → SALES_STAFF SELECT edebiliyor. 10_AUDIT bunları "manager+" diye yazmış; kod öyle değil. Rev 3: ledger'dan cost kolonunu ayrı `inventory_movement_costs` (manager+) tablosuna taşı; `return_items`'tan cost'u kaldır (zaten `sale_item_costs`'tan türetilebilir); `goods_receipt_items` SELECT'i manager+ yap (bkz. J-3); THI SELECT manager+.
3. **`goods_receipts` UPDATE / `goods_receipt_items` INSERT herhangi bir üyeye açık** → sales_staff draft fiş oluşturup maliyet girebilir/görebilir.
4. **`reservations` / `reservation_items` FOR ALL member** → herhangi bir üye status='converted' yazabilir, expires_at uzatabilir, hiç `converted_to_sale_id` olmadan. Anonim rezervasyon için `CHECK (customer_id IS NOT NULL OR customer_name IS NOT NULL)` yok.
5. **`supplier_returns` FOR ALL manager+** → ledger/havuz olmadan doğrudan "iade" yazımı.
6. **`p_discount_authorized_by`** client'tan; **`p_occurred_at`** sınırsız (geçmişe tarihli satış exchange window'u manipüle edebilir).
7. **Posted document immutability trigger'ları yok:** sales, sale_items, sale_*_costs, sale_payments, returns, return_items, inventory_movements, supplier_account_entries, thi, fx_rates için UPDATE/DELETE'i **her rolde** (service_role dahil) reddeden trigger yok; sadece RLS policy yokluğuna dayanılıyor. Test #32 için defense-in-depth gerekli.
8. `fn_set_variant_business_id` / `fn_set_gri_business_id` / `fn_set_sale_item_business_id` sadece BEFORE INSERT; `product_id` UPDATE ile desync mümkün → BEFORE INSERT OR UPDATE.
9. `product_variants UNIQUE(sku)` **global** → Tenant B, Tenant A'nın SKU'sunu kullanamaz (sızıntı + çakışma). `UNIQUE(business_id, sku)` olmalı.
10. Audit dokümanı ile kod uyuşmazlıkları: `businesses` UPDATE policy yok (audit "owner ALLOWED"), `branches` FOR ALL owner (audit "INSERT DENIED / UPDATE manager+").
11. `payment_method='mixed'` detay satırında engellenmiyor.

---

## E. Stok / maliyet tehlikeleri

1. `fn_post_to_cost_pool`: **inflow + `p_unit_cost_base IS NULL` + boş havuz → sessizce 0 maliyet.** Handoff: "never silently use zero cost". Inflow'da NULL cost → RAISE.
2. Inflow için `unit_cost_used` pre-average döner; 02_DOMAIN "receipts için p_unit_cost_base" diyor. RPC'ler zaten kendi cost'unu biliyor, ama semantik netleşmeli (öneri: inflow'da `unit_cost_used = p_unit_cost_base`).
3. `goods_receipt_items.unit_cost NUMERIC(12,2)` — orijinal para birimi maliyeti 2 ondalık; handoff "internal acquisition cost higher precision". Tutarlı NUMERIC politikası yok (12,2 / 12,4 / 14,4 / unconstrained karışık). Rev 3 politikası önerisi: müşteri fiyatı `NUMERIC(12,2)`; birim maliyet/MWA `NUMERIC(14,6)`; havuz/ledger toplam değer `NUMERIC(18,6)`; FX `NUMERIC(14,6)`.
4. `movement_reason` enum'unda handoff aileleri eksik: `sale_void`, genel `state_change` (quarantine→sellable / quarantine→damaged), `write_off` var (`damage_write_off`), `supplier_return` var (`return_to_supplier`). `damage_from_return` "kullanılmayan" diye işaretli — kaldırılmalı (enum değer silmek zor; Rev 3 fresh DB olduğu için temiz tanım).
5. Adjustment/state-change/write-off RPC'leri yok (B'de listelendi). Manager "stok var ama sistem 0 diyor" senaryosu bugün çözülemez.
6. `inventory_counts` posting RPC yok; sayım farkı havuza nasıl işlenecek belirsiz. V1'de "count = draft belge, posting = adjustment RPC" olarak bağlanmalı.
7. Rezervasyon `expires_at` süresi dolduğunda `status` hâlâ 'active' kalır; AVAILABLE hesabı `expires_at > now()` ile doğru (✓), ama raporlar `status` filtreliyorsa yanılır — view'larda tutarlı predicate gerekli.

---

## F. POS / idempotency / concurrency tehlikeleri

1. **`unit_price` client-controlled, indirim yetkisi kontrolü yok.** Handoff: "Manual authorized discount is a separate concept" + "discount authorization" atomicity listesinde. Pilot cevabı "sales-staff discount authority pending". → Karar gerekli (bkz. J-4).
2. **Rezervasyon dönüştürme yok.** `rpc_process_sale` `p_reservation_id` almıyor; rezerve edilmiş son birim müşteriye satılamaz. Konversiyonda rezervasyon FOR UPDATE + kendi miktarı AVAILABLE'a geri eklenmeli + status='converted' + `converted_to_sale_id`.
3. **Idempotency yarışı:** iki eşzamanlı aynı-key istek → ikisi de SELECT'te satır bulmaz → ikinci UNIQUE ihlali ile hata alır (orijinal Sale dönmez). Çözüm: `pg_advisory_xact_lock(hashtext(business_id||client_transaction_id))` ile giriş, veya unique_violation yakalayıp yeniden oku.
4. Hash kapsamı dar (branch, customer, discount alanları, session, occurred_at dışarıda) → "materially different payload" tanımı eksik.
5. Validasyon eksikleri: `p_branch_id` business'a ait mi; `p_register_session_id` business/branch'e ait ve OPEN mi; `p_customer_id` business'a ait mi; `p_items` boş mu; aynı variant iki satırda mı (lock sırası bozulur).
6. **Ödeme mutabakatı yok:** `SUM(sale_payments.amount_base)` ile `sales.total` karşılaştırılmıyor (test #13). Fazla/eksik ödeme, para üstü (change) semantiği tanımsız.
7. FX: `exchange_rate` client'tan; fx_rates'ten günün kurunu çekip default olarak kullanma, override için yetki kontrolü, FX snapshot'ı `fx_rate_id` ile bağlama (02_DOMAIN'de var, SQL'de yok) — hepsi eksik.
8. Lock sırası: cost pool'lar variant_id ile kilitleniyor (✓ niyet) ama derlenmeyen SQL ile. Return/transfer RPC'leri de aynı sırayı kullanıyor (✓). Rezervasyon satırları ve sale_item satırları için de sabit sıra tanımlanmalı.
9. Eşzamanlılık testi: 005 tek oturumlu; iki cashier senaryosu için `\! psql &` / iki bağlantı gerekir. Rev 3'te: (a) psql ile iki paralel session betiği (`tests/concurrency_run.sh`), (b) tek oturumda deterministik "lock alınmış mı" kontrolü (`pg_locks` üzerinden) — ikisi de dokümante edilecek.
10. `rpc_void_sale` yok (kurallar: not voided, no completed return, authorized, reason, session OPEN, Sale silinmez, ters ledger + havuz + cash movement).

---

## G. Return / transfer tehlikeleri

**Return**
1. Final-sale (Bikini/Mayo) kontrolü yok (BR-09 uygulanmamış) → test #18 başarısız olur.
2. Over-return: önceki `return_items` toplamı hesaba katılmıyor (Defect #12/#15 açık).
3. `store_credit` serbest; store credit pilot onaysız → reddedilmeli.
4. `return_number` üretilmiyor → INSERT patlar. `refund_amount` hesaplanmıyor.
5. Exchange akışı tanımsız: `exchange_sale_id` boş; değişimde yeni ürün satışı `rpc_process_sale` ile mi yapılacak, fiyat farkı nasıl kapanacak? Şu an "return + ayrı sale" iki belge; fark tahsilatı/ödemesi için kural yok. Karar gerekli (bkz. J-1).
6. `p_branch_id` zorunlu ve sale.branch_id ile eşit olmalı — tek şube için sorun değil, notlanmalı.
7. Disposition: kod her zaman quarantine; ADR-07 "V2'de manuel disposition" diyor; handoff "authorized inspection may directly choose SELLABLE/DAMAGED" diyor (bkz. J-1).

**Transfer**
8. Ship: `p_items` client'tan geliyor, `stock_transfer_lines` ile karşılaştırılmıyor → header'daki satırlar ile sevk edilen farklı olabilir. Satırlar draft'tan okunmalı, client miktar göndermemeli.
9. Ship: AVAILABLE (sellable − active reservations) kontrolü yok; cost pool quarantine/damaged içerdiği için sellable negatife düşebilir.
10. Receive: THI `received_at` set edilmiyor → "held" satır kalıcı; `idx_thi_variant WHERE received_at IS NULL` anlamsız; held-stock raporu yanlış.
11. Receive: `carried_total_value_base / quantity` bölümü ile `fn_post_to_cost_pool(p_unit_cost_base)` çağrısı → `qty × unit_cost` yeniden çarpımı rounding drift üretir (ADR-05'in tam da engellemek istediği şey). Rev 3: `fn_post_to_cost_pool`'a `p_total_value_base` parametresi (inflow için exact toplam) eklenmeli.
12. Transfer status enum 'cancelled' var ama draft→cancelled dışında shipped iptali tanımsız; V1'de shipped iptali yok diye notlanmalı.

---

## H. Supplier / FX / multi-currency tehlikeleri

1. **`rpc_process_sale` FX:** eksik rate → 1 (Defect #7 açık); TRY için 1 zorlanıyor ama GBP için 1 engellenmiyor; fx_rates doğrulaması yok; `fx_rate_id` bağlantısı yok.
2. **Supplier allocation (Defect #23 açık):** `supplier_payment_allocations` → Rev 3'te `liability_entry_id` (supplier_account_entries) + `liability_currency_amount_applied`, `payment_currency_amount_applied`, `base_amount_applied`, `settlement_fx_rate`, `settlement_basis` ('liability_rate'/'payment_rate'/'manual') ile yeniden tasarlanacak; `rpc_record_supplier_payment` + `rpc_allocate_supplier_payment` yazılacak; `supplier_payments` INSERT policy yok (✓) ama RPC de yok → şu an ödeme kaydedilemiyor.
3. GR confirm: `supplier_id` NULL olabilir → liability INSERT patlar; TRY invoice için `exchange_rate=1` CHECK'i goods_receipts'te yok; foreign invoice için `exchange_rate` draft'ta client tarafından yazılıyor (transaction-specific rate handoff'ta kabul; ama manager onayı confirm'de olduğu için OK — confirm anında rate>0 ve TRY→1 doğrulanmalı).
4. `supplier_account_entries.amount_original NUMERIC(12,2)` ve `amount_base` GENERATED — GENERATED kabul (rate satırda snapshot). `v_supplier_balance` sadece base bakiye; para birimi bazlı açık bakiye view'ı yok.
5. `rpc_set_fx_rate`: mevcut satır yoksa lock alınamaz → iki eşzamanlı ilk giriş unique_violation ile birinin hata alması (veri bozulmaz, UX hatası). Advisory lock ile düzeltilebilir. `rate_date` gelecek tarih sınırı yok.
6. `register_session_currency_counts.exchange_rate` client'tan; günün kuru fx_rates'ten alınmalı.
7. `cash_movements`: sale'de yalnızca cash yazılıyor (✓ drawer semantiği); refund/void cash_out akışı yok.

---

## I. Rev 3 dosya değişiklik planı

**Sıra (fresh DB):** `000_test_harness.sql` (yalnız test) → `001_schema.sql` → `002_schema_cont.sql` → `003_schema_pilot.sql` → `004_rpc_posting.sql` → `seed_things_like_crop.sql` → `005_verification_tests.sql` (+ `tests/concurrency_run.sh`)

### 000_test_harness.sql (yeniden)
- `CREATE ROLE anon/authenticated/service_role NOLOGIN` (Supabase eşdeğeri), `GRANT USAGE ON SCHEMA public TO authenticated`, default table grants
- `test_set_user()` + `SET ROLE authenticated` helper'ları; `test_as(user)` sarmalayıcı
- `auth.uid()` mock korunur

### 001_schema.sql (revize)
- `gen_random_uuid()`; `UNIQUE(business_id, sku)`; `movement_reason` yeniden tanım (sale_void, state_change; ölü değerler yok)
- `option_values.business_id` (trigger) + `UNIQUE(business_id, id)`; `products` → category/brand/supplier composite FK; `barcodes` composite FK + trigger; `barcode_type` enum (INTERNAL/SUPPLIER)
- **Duplicate variant engeli:** `product_variants.option_fingerprint TEXT` (trigger ile `variant_option_values`'tan sıralı `option_id:value_id` dizisi) + `UNIQUE (product_id, option_fingerprint) WHERE status='active'`
- `goods_receipts`: `CHECK (invoice_currency<>'TRY' OR exchange_rate=1)`, `supplier_id NOT NULL`; `goods_receipt_items.unit_cost NUMERIC(14,6)`, `fx_rate_snapshot` (confirm'de kopyalanır)
- `supplier_payment_allocations` yeniden tasarım (H-2); `supplier_payments.business_id` composite FK
- NUMERIC politikası bloğu (yorum + tipler)
- Trigger'lar BEFORE INSERT OR UPDATE

### 002_schema_cont.sql (revize)
- `rpc_process_sale` yeniden yazım: lock SQL düzeltmesi; branch/session/customer validasyonu; `p_reservation_id`; advisory-lock idempotency + genişletilmiş fingerprint; FX: fx_rates'ten default, override yetkisi, `fx_rate_id`, eksik rate → RAISE; ödeme mutabakatı; `p_discount_authorized_by` kaldırılır; indirim yetkisi (J-4 kararına göre); `p_occurred_at` sınırı
- `rpc_void_sale`, `rpc_post_inventory_adjustment`, `rpc_change_stock_condition`, `rpc_write_off`, `rpc_create_reservation` / `rpc_cancel_reservation`, `rpc_open_register_session` (per-currency opening JSONB) / `rpc_close_register_session` (fx_rates'ten kur; branch/rol kontrolü)
- `fn_post_to_cost_pool`: inflow NULL cost → RAISE; `p_total_value_base` exact-inflow parametresi; `unit_cost_used` semantiği netleştirilir
- Maliyet ayrımı: `inventory_movement_costs` (manager+); `return_items` cost kolonu kaldırılır; THI / gri SELECT manager+
- Reservation: CHECK (customer_id OR customer_name); client write policy'leri kaldırılır (RPC-only), sadece note gibi zararsız alanlar için UPDATE
- Composite FK'ler (D-1 listesi); immutability trigger'ları (D-7); `fn_lock_confirmed_goods_receipt` daraltma; `fn_next_sequence` client GRANT kaldır
- `businesses` owner UPDATE (settings) policy; `goods_receipts`/`gri` yazma policy'leri J-3 kararına göre
- `fn_set_updated_at` vb. korunur

### 003_schema_pilot.sql (küçük revize)
- `rpc_set_fx_rate` advisory lock; `rate_date <= CURRENT_DATE + 1` sınırı; `fn_get_fx_rate(business, currency, date)` helper (SD, internal)
- `sale_payments.fx_rate_id` FK (003'te ALTER yerine 002'de kolon, 003'te FK) — sıra netleştirilir

### 004_rpc_posting.sql (yeniden yazım)
- Tüm kolon/enum adları düzeltilir; `rpc_confirm_goods_receipt` (fx snapshot, TRY=1, supplier zorunlu, `unit_cost_base = unit_cost × rate`, ledger + cost tablo)
- `rpc_process_return` (final-sale, SUM(prior returns) lock altında, `return_number`, refund policy `money_refund_allowed=false`, store_credit reddi, disposition J-1'e göre, exchange bağlantısı J-1'e göre)
- `rpc_ship_transfer` (satırlar draft'tan, AVAILABLE kontrolü, THI from/to branch) / `rpc_receive_transfer` (received_at, exact value inflow)
- `rpc_reverse_goods_receipt` stub korunur; `rpc_record_supplier_payment` + `rpc_allocate_supplier_payment`; `rpc_post_supplier_return` (pilot kullanmıyor → **stub** önerim, bkz. J-5)

### seed_things_like_crop.sql (küçük revize)
- `allow_cash_refund` → `money_refund_allowed: false`, `return_policy: {exchange_window_days: 3}`; `exchange_window_days` COALESCE fallback RPC'den kaldırılır (setting yoksa RAISE)
- Örnek ürün "Çiçek Desenli Korse" **seed'e eklenmez** (stok girişi GR akışıyla test edilecek; seed master data ile sınırlı)

### 005_verification_tests.sql (yeniden yazım)
- Handoff test 1–34'ün tamamı; her test `[PASS]/[FAIL]` NOTICE; RLS testleri `SET ROLE authenticated` + `test_set_user`; hata beklenen testler `BEGIN ... EXCEPTION WHEN ... THEN PASS`
- Concurrency (#8, #16): `tests/concurrency_run.sh` (iki psql oturumu, `pg_sleep` senkronizasyonu) + tek-oturum `pg_locks` doğrulaması; README'de neden iki yöntem olduğu açıklanır
- 10_AUDIT_REVIEW.md gerçek koda göre yeniden yazılır (Rev 3 çıktısı olarak)

---

## J. Handoff ile onaylı dokümanlar arasındaki çelişkiler — KARAR GEREKİYOR

Bunları sessizce seçmiyorum. Her biri için onayını istiyorum.

**J-1 · İade disposition + exchange mekaniği**
- Handoff: default QUARANTINE, **yetkili inspection doğrudan SELLABLE/DAMAGED seçebilir**.
- ADR-07: **her iade quarantine**, disposition V2'de ayrı RPC.
- Ayrıca exchange'de yeni ürünün verilmesi ve fiyat farkı akışı hiçbir dokümanda tanımlı değil.
- Seçenekler: (a) ADR-07 aynen: her zaman quarantine + `rpc_change_stock_condition` ile manager sonradan taşır; (b) handoff: `p_requested_disposition` manager+ için kabul, staff için quarantine'e zorlanır. Exchange: (i) return + ayrı `rpc_process_sale`, fark ödemesi normal payment olarak; (ii) tek atomik `rpc_process_exchange`.
- **Önerim:** (b) + (i). Ama onay bekliyorum.

**J-2 · Return/refund semantiği ve `sale_status`**
- Handoff: money refund YOK; store credit deferred. Enum'da `refund`, `store_credit`, `refunded`, `partially_refunded` var.
- Seçenek: enum'ları koru ama RPC'de policy ile reddet (tenant-configurable) — handoff "return policy configurable" ile uyumlu. `sale_status` `refunded/partially_refunded` türetilmiş bilgi; status'te tutulmasın (view ile).
- **Önerim:** enum korunur, policy `money_refund_allowed=false` / `store_credit_allowed=false`; sale_status yalnız completed/voided.

**J-3 · STOCK_STAFF ve alış maliyeti**
- 01_REQUIREMENTS BR-02: stock_staff "goods receipt entry (draft)" yapar → maliyet girer/görür.
- Pilot: "Alış fiyatı sadece işletme sahibi/yöneticiler görsün".
- Seçenekler: (a) stock_staff draft GR'de miktar girer, maliyet kolonlarını göremez/giremez (kolon-seviye ayrım: `goods_receipt_items` + `goods_receipt_item_costs`); (b) GR tamamen manager+; stock_staff sadece etiket/sayım.
- **Önerim:** (b) V1 (pilotta 2 kullanıcı var, ikisi de owner/manager). Onay bekliyorum.

**J-4 · SALES_STAFF indirim yetkisi (pilot cevabı "pending")**
- Handoff "discount authorization" atomicity'de zorunlu; pilot kararı yok.
- Bir default seçmeden yazamam. Seçenekler: (a) sales_staff için `unit_price` = list_price zorunlu (indirim 0); manager+ `max_discount_pct`'e kadar; (b) `business_members.max_discount_pct` ne ise o (pilot 0 bırakır → fiilen (a)).
- **Önerim:** (b) — kod değişmeden pilot kararı uygulanır; seed'de 0.

**J-5 · Supplier return RPC**
- Handoff costing kurallarını tanımlıyor; pilot "kullanmıyoruz".
- Seçenek: (a) tam RPC yaz; (b) tablo + policy kapat + NOT IMPLEMENTED stub (GR reversal gibi).
- **Önerim:** (b), Rev 3 kapsamını daraltır.

**J-6 · Doküman/kod tutarsızlıkları (karar değil, bilgi):** 10_AUDIT_REVIEW "PASS" verdikleri yanlış; 02_DOMAIN `fx_rate_id` SQL'de yok; 00_OVERVIEW "Schema frozen (conditionally)" ifadesi geri çekilmeli; pilot-analiz.html'deki `markup_multiplier`, `default_reservation_hours: 24`, `accounting` önerileri zaten ADR'lerle reddedilmiş (stale). Bunları Rev 3 çıktısında güncelleyeceğim.

**Açık pilot soruları (dokunulmayacak):** consignment, rezervasyon depozito, store credit, kurye, "other" ödeme, accounting rolü, yazıcı modeli, kasa toleransı, FX kaynağı — hiçbiri implement edilmeyecek; seed/enum'da varsayım yok.

---

## DURUM

**READY TO WRITE REV 3 — J-1…J-5 kararları onaylandıktan sonra.**

Mimari çekirdek (ledger, koşul-nötr MWA havuzu, THI, maliyet ayrımı, versiyonlu FX, composite FK deseni, SD standardı) ile handoff arasında **bloke edici çelişki yok**. Bulunan çelişkiler (J-1…J-5) kapsam/politika kararları; SQL yazımını bloke ediyor ama mimariyi değil.

Onay geldiğinde üreteceklerim: 000/001/002/003/004/seed/005 + `tests/concurrency_run.sh` + revize 10_AUDIT_REVIEW.md. Yerelde PostgreSQL olmadığı için teslim durumu **READY FOR DEV APPLY / REQUIRES EXECUTION VERIFICATION** olacak; "READY" demeyeceğim.
