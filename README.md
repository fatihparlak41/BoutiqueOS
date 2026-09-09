# BoutiqueOS

Multi-tenant boutique retail SaaS. Pilot: **Things Like Crop** (Lefkoşa).
Stack: Next.js / TypeScript / Tailwind / shadcn · Supabase (PostgreSQL, Auth, Storage, RLS) · Vercel.

**Gate geçmişi:** Architecture → Rev 3 Schema → Fresh-DB verification (149/149) → DEV Supabase apply → seed → smoke → **Frontend Faz 1 (doğrulandı)** → **Faz 2 Ürün kataloğu (doğrulandı)** → **Faz 3 Tedarikçiler + Mal Kabul + Stok (TRY kapsamı doğrulandı)**.

**Durum:** Backend gate kapandı (Plain 149/149, concurrency PASS, DEV Supabase'e uygulandı).
Frontend Faz 1 (Auth + tenant girişi) **doğrulandı** — bağımlılık + build zinciri ve manuel
login/tenant smoke'u DEV Supabase'e karşı geçti (2026-09-08).
Frontend Faz 2 (Ürün kataloğu — ürün / varyant / barkod) **doğrulandı** — manuel DEV smoke
2026-09-09'da geçti.
Frontend Faz 3 (Tedarikçiler + Mal Kabul + Stok Görünümü) **doğrulandı** — TRY manuel DEV
smoke'u 2026-09-09'da geçti; **non-TRY FX ve rol smoke'u DEFERRED**. Sıradaki modüller
(Kasa, Satış, Raporlar…) başlamadı.

## Yerleşim

```
docs/                          00–02 mimari · 09 ADR · 10 audit (Rev 3, statik) · 11 Rev 3 pre-flight
supabase/migrations/           20260908000001_core_schema.sql
                               20260908000002_fx_rates.sql
                               20260908000003_inventory_sales_schema.sql
                               20260908000004_posting_rpcs.sql
seeds/seed_things_like_crop.sql
tests/000_test_harness.sql     yalnız yerel Plain mod (auth şeması + roller mock)
tests/005_verification_tests.sql   143 assertion, T01–T34, tek transaction + ROLLBACK
tests/concurrency/             son-birim oversell yarışı (iki psql oturumu)
scripts/db_fresh.ps1           sıfır DB → harness → migrations → seed → testler
tools/lint_sql.py              statik SQL çapraz kontrol (python3, opsiyonel)
```

Eski `001_schema.sql … 004_rpc_posting.sql` **silinir**; `db_fresh.ps1` kısa-numara + timestamp karışımını reddeder.

## Fresh-DB doğrulama

```powershell
cd E:\BoutiqueOS\Butik
.\scripts\db_fresh.ps1 -Init            # cluster yoksa oluşturur; varsa/çalışıyorsa sadece başlatır
.\scripts\db_fresh.ps1                  # Plain: DROP/CREATE boutiqueos_test + harness + 4 migration + seed + 005
.\tests\concurrency\concurrency_run.ps1 # opsiyonel, Plain DB üzerinde; sonra db_fresh.ps1 tekrar
.\scripts\db_fresh.ps1 -Mode Supabase   # Docker + `supabase start` gerektirir; migration'ları CLI uygular, seed+005 psql ile
```

Çıktı: `PASS: n  FAIL: m  psql errors: k  exit: c`; tam log `tests\results\last_run.log`. Exit 1 = kırık.
İlk hata dosyayı durdurur (fixture hatası da bulgudur) — log'un **tamamı** geri gönderilir.

## Kurallar

- Ledger, cost pool, posted belge tablolarına client yazmaz; yalnız `SECURITY DEFINER` `rpc_*`.
- Maliyet kolonları (`*_cost*`, `total_value_base`, havuz, THI) manager+; SALES_STAFF görmez.
- Fiyat server-authoritative; `expected_list_price` uyuşmazsa `PRICE_CHANGED`.
- `.env` commit edilmez; service-role key frontend'e girmez.
- Migration'lar Studio'ya elle yapıştırılmaz.

## Frontend (Faz 1 — Auth + tenant girişi)

```
app/layout.tsx                 kök layout, tipografi
app/page.tsx                   / -> /app veya /login
app/login/                     giriş ekranı (e-posta + parola, kayıt yok)
app/app/                       korumalı kabuk (/app)
app/select-business/           birden fazla üyelik varsa işletme seçimi
app/no-access/                 aktif üyelik yoksa güvenli ekran
app/auth/actions.ts            signIn / signOut / selectBusiness server action'ları
lib/supabase/{client,server,middleware}.ts   tarayıcı / sunucu / oturum yenileme
lib/tenant.ts                  üyelik + işletme + şube + rol çözümlemesi (sunucu tarafı)
middleware.ts                  oturum yenileme + yönlendirme kuralları
components/ui/                 shadcn tarzı temel bileşenler
components/shell/              kenar menü, hesap menüsü
```

### Kurulum

```powershell
copy .env.local.example .env.local     # NEXT_PUBLIC_SUPABASE_URL + ANON_KEY doldur
npm install
npm run lint
npm run build
npm run typecheck
npm run dev                            # http://localhost:3000
```

### Güvenlik bakımı (bağımlılıklar)

Sabitlenmiş sürüm çizgisi (deterministik; `@latest` kullanılmaz):

| Paket | Sürüm |
|---|---|
| `next` | 15.5.25 |
| `eslint-config-next` | 15.5.25 |
| `react` / `react-dom` | 19.0.0 |
| `@supabase/supabase-js` | `^2.116.0` |
| `@supabase/ssr` | 0.12.6 |
| `postcss` (dev + `overrides`) | 8.5.23 |
| `tailwindcss` | 3.4.17 |

`postcss` Next'in altından geldiği için hem devDependency hem `overrides` ile **birebir 8.5.23**'e
sabitlenir (iki spec aynı); `@supabase/auth-js` doğrudan bağımlılık değildir, `@supabase/supabase-js` ≥ 2.116 ile
yamalı sürüme çözülür. `npm audit fix --force` **kullanılmaz** (Next major atlatır).
Next 16 geçişi ayrı bir karardır ve Faz 1 kapsamı dışındadır.

Doğrulama:

```powershell
npm install
npm ls @supabase/supabase-js @supabase/auth-js @supabase/ssr next postcss
npm audit --omit=dev
npm run lint
npm run build
npm run typecheck
```

**Faz 1 doğrulama sonuçları (2026-09-08, yerel makine — çıktılar görüldü):**

| Kontrol | Sonuç |
|---|---|
| `npm ls @supabase/supabase-js @supabase/auth-js @supabase/ssr next postcss` | **PASS** — `invalid` yok |
| `npm audit --omit=dev` | **PASS** — 0 vulnerabilities |
| `npm run lint` | **PASS** |
| `npm run build` | **PASS** |
| `npm run typecheck` | **PASS** |

Çözülen sürümler: `@supabase/ssr` 0.12.6 · `@supabase/supabase-js` 2.116.0 · `@supabase/auth-js` 2.116.0 ·
`postcss` 8.5.23 (Next'in nested kopyası dahil deduped).

**Bilinen teknik borç (bloke etmiyor):** `next lint` Next 15.5'te kullanımdan kaldırıldı ve Next 16'da
kalkacak. Geçiş ESLint 9 + flat config gerektirdiği için Faz 1 kapsamı dışında bırakıldı.

`.env.local` yalnız **anon** anahtarı içerir. Service-role anahtarı frontend'e hiçbir koşulda girmez.

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
| Token refresh + cache-header yolu | **KOŞULMADI** — yalnız access token süresi dolunca tetiklenir |

`@supabase/ssr` 0.12.6'nın güncel cookie sözleşmesi (`getAll()` / `setAll(cookiesToSet, headers)`)
`lib/supabase/{server,middleware}.ts` içinde uygulandı. Middleware sırası: request'e cookie yaz →
`NextResponse.next({ request })` ile yanıtı yeniden kur → yanıta cookie yaz → dönen cache header'larını
kopyala; bu cookie ve header'lar redirect yanıtlarına da taşınır.

### Faz 2 — Ürün kataloğu (Ürün / Varyant / Barkod)

```
app/app/urunler/              liste · arama · kategori/marka/durum filtresi
app/app/urunler/yeni/         1. adım: temel bilgiler + fiyat
app/app/urunler/[id]/         2–5. adım: seçenekler · varyantlar · fiyat · barkodlar
app/app/urunler/actions.ts    server action'lar (ürün, marka, seçenek, varyant, barkod)
lib/catalog/model.ts          tipler, durum etiketleri, yetki kuralları (istemci-güvenli)
lib/catalog/queries.ts        server-only okuma katmanı
lib/catalog/errors.ts         PostgreSQL hata kodu → Türkçe mesaj
lib/catalog/format.ts         para biçimleme / ayrıştırma, SKU önerisi
components/catalog/           ürün formu, seçenek yöneticisi, varyant tablosu, barkod paneli
```

Kullanılan mevcut sözleşme: `products`, `product_variants`, `variant_option_values`,
`product_options`, `option_values`, `barcodes`, `categories`, `brands` tabloları ve
`rpc_create_variant`, `rpc_assign_internal_barcode` fonksiyonları.
**Yeni migration, RPC, view, policy veya seed oluşturulmadı.**

Stok miktarı bu modülde tutulmaz ve elle girilmez; mal kabul / stok hareketleriyle gelir.
Maliyet kolonları hiçbir sorguda yer almaz.

#### Manuel smoke (2026-09-09, DEV Supabase, owner oturumu)

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
| Yinelenen varyant kombinasyonu reddi | **PASS** |
| Yinelenen (işletme kapsamlı) barkod reddi | **PASS** |
| Tam sayfa yenileme sonrası persistence | **PASS** |
| Elle stok miktarı alanı bulunmadığı | **PASS** |
| RLS altında `authenticated` owner yazmaları | **PASS** |

Maliyet sorgusu yok · service role kullanılmadı · migration / RLS / RPC / seed / backend
değişikliği yok.

#### Şeffaflık notları

- **Marka ve ürün ilk denemede onaylanan test verisiyle oluşturulmadı.** İlk girişte farklı
  değerler yazıldı, sonra UI üzerinden düzeltildi ve final durum doğrulandı. Bu sonuç
  **"first-pass clean" değildir.**
- **KDV oranı doğrulanmış değildir.** Ürün satırındaki `%0` mevcut veritabanı varsayılanıdır;
  smoke sırasında hiçbir vergi değeri yazılmadı. Bu değer Things Like Crop'ın gerçek KDV
  oranı olarak kabul edilmemelidir.
- **Gerçek cross-tenant testi DEFERRED.** Rastgele UUID denemesi yalnızca nesne kapsamı ve
  veri sızmaması kontrolüdür; gerçek test ikinci bir işletme ve kullanıcı gerektirir.
- **Bulunamayan ürün ekranı içerik olarak doğru, ancak HTTP 200 döner.** Next akış yaptığı
  için `notFound()` durum kodunu değiştiremiyor; bu **gerçek bir 404 PASS değildir.**

Açık teknik borçlar: `docs/10_AUDIT_REVIEW.md` → "Faz 2 açık teknik borçlar".

### Faz 3 — Tedarikçiler + Mal Kabul + Stok Görünümü

```
app/app/tedarikciler/         liste · arama · aktif/pasif filtre · satır içi düzenleme · yeni
app/app/mal-kabul/            belge listesi · durum/tedarikçi/tarih filtresi · yeni · [id] belge
app/app/stok/                 varyant bazlı stok · arama/filtre · [variantId] kova + hareket geçmişi
lib/receiving/                tipler · server-only okuma · para/tarih biçimleme
lib/stock/                    tipler · merkezî stok toplama (ON_HAND tek yerde hesaplanır)
lib/db-errors.ts              tek hata çevirici (katalog + mal kabul)
lib/app-context.ts            tenant + supabase bağlamı
components/receiving/         tedarikçi formu · belge oluşturma · taslak editörü · durum rozeti
components/ui/route-states.tsx  paylaşılan loading/error yüzeyleri
```

Kullanılan mevcut sözleşme: `rpc_create_goods_receipt`, `rpc_post_goods_receipt`,
`rpc_get_fx_rate`; `suppliers`, `goods_receipts`, `goods_receipt_items`, `branches`,
`inventory_movements` tabloları; `v_stock_by_bucket`, `v_stock_available` view'ları.
**Yeni migration, RPC, view, policy veya seed oluşturulmadı.**

Stok elle girilmez: `/app/stok` tamamen salt-okunurdur — miktar input'u, +/- stok, satır içi
düzenleme, envanter düzeltme, zayi ve durum değişimi yoktur. Stok yalnız işlenmiş mal kabul
belgelerinin değişmez defter kayıtlarından doğar. Maliyet (`variant_cost_pools`,
`inventory_movement_costs`) stok ekranlarında hiç sorgulanmaz.

`rpc_reverse_goods_receipt` NOT_IMPLEMENTED olduğu için işlenmiş belgede geri alma / iptal
düğmesi **yoktur**. Taslak iptali (draft → cancelled) ayrı ve daha dar bir davranıştır.

#### Manuel TRY smoke (2026-09-09, DEV Supabase, owner oturumu)

| Alan | Sonuç |
|---|---|
| Tedarikçi: liste · oluştur · yinelenen ad reddi · düzenle · e-posta/not persistence | **PASS** |
| Taslak oluşturma `rpc_create_goods_receipt` ile | **PASS** |
| `receipt_number` sunucuda üretiliyor, sıralı: `GR-2026-000001`, `GR-2026-000002` | **PASS** |
| Formda `business_id` / `status` / `receipt_number` alanı yok | **PASS** |
| TRY belgede `exchange_rate = 1` (alan disabled) | **PASS** |
| Satır ekleme / güncelleme · yinelenen varyant yeni satır açmıyor | **PASS** |
| Taslak yenileme sonrası persistence | **PASS** |
| İşleme öncesi özet (2 satır · 8 adet · ₺3.260,00 · kur 1) | **PASS** |
| Onay kutusu guard'ı | **PASS** |
| Boş taslak UI post guard'ı (kutu işaretlense de CTA kapalı) | **PASS** |
| İşleme `rpc_post_goods_receipt` ile | **PASS** |
| İşlenmiş belge salt-okunur · ikinci POST yok · geri alma/iptal CTA yok | **PASS** |
| Taslak iptali ayrı davranış olarak | **PASS** |
| Stok: baseline S=0 M=0 → delta **+5 / +3** | **PASS** |
| SELLABLE · ON_HAND · RESERVED · AVAILABLE | **PASS** |
| Stok detayı · hareket geçmişi · belgeye link | **PASS** |
| Arama: ürün adı / SKU / barkod (dahili + harici) | **PASS** |
| Filtreler: kategori · marka · şube · stok durumu | **PASS** |
| Stok ekranında değiştirilebilir alan/eylem yok | **PASS** |
| Stok ekranında maliyet sızıntısı yok | **PASS** |

**Read-only SQL ile doğrulanan backend değerleri** (UI sonucunu teyit için, yazma yapılmadı):

| Doğrulama | Değer |
|---|---|
| `goods_receipt_items` S | qty 5 · unit_cost 400 · fx 1 · unit_cost_base 400 · total_cost_base 2000 |
| `goods_receipt_items` M | qty 3 · unit_cost 420 · fx 1 · unit_cost_base 420 · total_cost_base 1260 |
| Toplam base | 3.260 TRY |
| `variant_cost_pools` | S: qty 5 / değer 2000 · M: qty 3 / değer 1260 |
| `supplier_account_entries` | `GR-2026-000001` → `liability` 3260 TRY (base) |

#### Kapsam sınırları

- **TRY kapsamı FULLY VERIFIED.** Bu ifade yalnız TRY için geçerlidir.
- **Non-TRY / FX manuel smoke DEFERRED** — DEV'de kullanılabilir FX kaydı yok; kur uydurulmadı,
  `rpc_set_fx_rate` çağrılmadı, FX verisi seed edilmedi.
- **Rol smoke kısmen DEFERRED** — ikinci bir `sales_staff` hesabı olmadığı için manuel rol testi
  yapılmadı. Owner oturumuyla gözlenen davranış yalnız frontend gizlemesidir ve cross-role
  security PASS sayılmaz; RLS sözleşmesi backend'de ayrıca doğrulanmıştır.
- **Gerçek cross-tenant manuel test DEFERRED** — ikinci işletme ve kullanıcı gerekiyor.

### Kurallar

- İşletme/şube/rol bilgisi yalnızca Supabase'ten (RLS altında) okunur; cookie yalnız *tercih* taşır ve her istekte yeniden doğrulanır.
- Modül sayfaları (Ürünler, Stok, Kasa…) henüz yok; menüde devre dışı yer tutucular olarak duruyor.
- Şema değişikliği artık yerinde düzenlemeyle değil, yeni timestamp'li migration ile yapılır (remote'ta 20260908000001–04 kayıtlı).
