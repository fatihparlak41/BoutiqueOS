# BoutiqueOS — Claude Code çalışma kuralları

Multi-tenant butik perakende SaaS. Pilot: **Things Like Crop** (Lefkoşa, tek şube).
Stack: Next.js 15.5.25 (App Router) · TypeScript · Tailwind 3.4 · shadcn tarzı bileşenler ·
Supabase (PostgreSQL + Auth + RLS) · Vercel (henüz deploy yok).

Yanıt dili: **Türkçe**. Kod, dosya adları ve kod içi yorumlar İngilizce.

---

## Mevcut durum

| Alan | Durum |
|---|---|
| Rev 3 migration'ları (`20260908000001`–`04`) | DEV Supabase'e uygulandı, remote'ta kayıtlı |
| Plain fresh-DB doğrulaması | PASS 149/149 |
| Concurrency (son birim oversell) | PASS |
| Supabase-local (`-Mode Supabase`) | DEFERRED — Docker kurulu değil |
| TLC seed + owner üyeliği | DEV'de uygulandı |
| Frontend Faz 1 — bağımlılık + build | **VERIFIED** (2026-09-08) — ls/audit/lint/build/typecheck PASS |
| Frontend Faz 1 — auth + tenant girişi | **VERIFIED** (2026-09-08) — manuel smoke DEV'e karşı PASS |
| Token refresh + cache-header yolu | **KOŞULMADI** — token süresi dolmadan tetiklenmiyor |
| Frontend Faz 2 — ürün kataloğu (ürün / varyant / barkod) | **VERIFIED** (2026-09-09) — manuel DEV smoke PASS |
| Frontend Faz 3 — tedarikçiler + mal kabul + stok | **VERIFIED** (2026-09-09) — TRY manuel DEV smoke PASS |
| Faz 3 — non-TRY FX manuel smoke | **DEFERRED** — DEV'de kullanılabilir FX kaydı yok |
| Faz 3 — sales_staff rol smoke | **VERIFIED** (2026-09-14) — gerçek sales_staff / stock_staff oturumuyla canlı sayfa + RLS/RPC smoke PASS (bkz. Faz 4) |
| Pilot dağıtım (Vercel) | **DEPLOYED** (2026-09-09) — https://butikos.parlakmediatech.com.tr · **DEV Supabase'e bağlı pilot/canlı test ortamı** |
| Production Supabase projesi | **KURULMADI** — canlı adresten yapılan her işlem DEV verisine yazılır |
| Gerçek cross-tenant smoke | **VERIFIED** (2026-09-14) — iki fixture tenant + gerçek ikinci kullanıcı; TLC verisi hiçbir sorguda görünmedi |
| Faz 3.5 — tenant/platform sertleştirme (`phase35a–g`) | **APPLIED** — DEV'de kayıtlı |
| Faz 4 — Ekip & Kimlik (`phase4a–d`, davet / magic link / parola kurtarma / ekip dizini / audit) | **DEPLOYED TO DEV** (2026-09-14) — Case A/B/C e-posta E2E PASS, sales_staff + stock_staff yetki smoke PASS, fixture'lar `cancelled` |
| Faz 4 — bilinen upstream olay | Supabase `POST /auth/v1/recover` aralıklı **525** ve taze JWT'de PostgREST **PGRST303** "JWT issued at future" — uygulama tarafında tek 525 retry + `/auth/session-ready` bekleme odası; **upstream'de düzeltilmiş değil**, `docs/13` support notu gönderilmedi |
| Faz 5A/5B — tasarım sistemi + auth deneyimi | **DEPLOYED** (2026-09-14) — token katmanı, shell, auth shell |
| Faz 6A — moda ürün ana verisi (`20260914130000_phase6a_product_master`) | **DEPLOYED TO DEV** (2026-09-14) — style_code, seçenek türü/renk metadata, matris RPC, barkod çözümleme, görsel rolleri + özel bucket + storage RLS; fresh-DB 576/0, canlı API/RPC/Storage smoke PASS (fixture C cancelled); **UI tıklama smoke'u ve 390/768/1440 görsel QA tarayıcı otomasyonu düştüğü için yapılmadı** |
| Faz 6B+ (gerçek fatura satırı içe aktarma, landed cost, PO, POS) | **Başlamadı** — 6A incelemesi bekliyor |

Ayrıntılı denetim: `docs/10_AUDIT_REVIEW.md`. Mimari kararlar: `docs/09_DECISIONS.md`.
Auth e-posta/dashboard sözleşmesi: `docs/12_AUTH_DELIVERY_CONFIG.md`. Supabase olay notu: `docs/13_SUPABASE_525_INCIDENT_NOTE.md`.

---

## Değiştirilmesi YASAK olanlar

1. **Uygulanmış migration'lar.** `supabase/migrations/20260908000001` … `20260914130000` remote'ta kayıtlı; yerinde
   düzenlenmez. Her şema/RPC değişikliği yeni timestamp'li dosyayla gider.
2. **RLS politikaları ve SECURITY DEFINER fonksiyonları.** Frontend'i kolaylaştırmak için gevşetilmez.
   Frontend/backend uyumsuzluğu bulursan **dur ve raporla**, RLS'i baypas eden bir yol yazma.
3. **Service-role anahtarı.** Frontend'e, `.env.local`'e, repoya asla girmez. Yalnız `NEXT_PUBLIC_SUPABASE_URL`
   ve `NEXT_PUBLIC_SUPABASE_ANON_KEY` kullanılır.
4. **Maliyet görünürlüğü.** Maliyet kolonları (`*_cost*`, `total_value_base`, cost pool, THI) manager+
   içindir; `sales_staff`'a sızdıran sorgu/görünüm yazılmaz.
5. **`supabase db push` / production'a yazan komutlar.** Yeni migration yazıldığında önce yerel
   fresh-DB gate'i geçer; push kararını kullanıcı verir.

## İzin istemeden yapma

- `npm audit fix --force`
- Next 16'ya yükseltme
- Bağımlılık sürümü değiştirme (sabitler `package.json`'da bilinçli seçildi)
- `git push`, branch silme, geçmiş yeniden yazma
- Yeni modül/sayfa açma (faz sırası kullanıcıda)

---

## Doğrulama gate'i (her SQL değişikliğinde)

```powershell
.\scripts\db_fresh.ps1              # sıfır DB: harness -> migrations -> seed -> 005 (149 assertion)
.\tests\concurrency\concurrency_run.ps1
.\scripts\db_fresh.ps1              # concurrency commit ettiği için tekrar tazele
```

Beklenen: `PASS: n  FAIL: 0  psql errors: 0  exit: 0`. Log: `tests\results\last_run.log`.
Statik ön kontrol (hızlı): `python tools\lint_sql.py .` → INSERT kolonları, enum literalleri,
fonksiyon imzaları, `RAISE` placeholder/argüman sayısı.

Yerel PostgreSQL: port 5433, `.pgdata`, DB `boutiqueos_test`. Cluster kapalıysa
`.\scripts\db_fresh.ps1 -Init`. Harness `auth` ve `storage` (buckets/objects/foldername) şemalarını shim'ler;
storage RLS politikaları yerelde de test edilir. Beklenen sayım: **576**.

## Frontend gate'i (her bağımlılık/kod değişikliğinde)

```powershell
npm run lint
npm run build
npm run typecheck
npm run test:auth     # redirect + reset + jwt-skew + recovery + session-ready (plain Node, framework yok)
```

Bağımlılık değiştiyse önce temiz kurulum: `node_modules` ve `package-lock.json` silinir, `npm install`,
ardından `npm ls @supabase/supabase-js @supabase/auth-js @supabase/ssr next postcss` ve `npm audit --omit=dev`.

---

## Sabit teknik kararlar

- Cookie API'si güncel `@supabase/ssr` sözleşmesi: `getAll()` / `setAll(cookiesToSet, headers)`.
  Middleware sırayla: request'e cookie yaz → `NextResponse.next({ request })` → yanıta cookie yaz →
  dönen cache header'larını yanıta kopyala. Yönlendirmelerde bu cookie'ler redirect yanıtına taşınır.
- Yetkilendirme `supabase.auth.getClaims()` ile. `getSession()` yetki kararı için **kullanılmaz**.
- Parola kurtarma oturumu: GoTrue her e-posta linkine (`invite`/`magiclink`/`recovery`) `amr=otp` yazar; `/sifre-belirle`
  ve `setPasswordAction` yalnız `lib/auth/recovery-session.ts` gate'iyle (otp + bekleyen `recovery_sent_at` + oturum sonra doğmuş)
  açılır. Parola girişi reddedilir. Not: magic link de `recovery_sent_at` yazar; magic-link oturumu da gate'i geçer (aynı posta kutusu kanıtı).
- Taze JWT: `loadMemberships` PGRST303 / "JWT issued at future" alırsa **fırlatmaz**, `/auth/session-ready?next=…` (allowlist: `/app`, `/select-business`)
  bekleme odasına yönlendirir; oda salt-okuma probe'u 0/1/2/4/8 s çizelgesiyle yoklar. Başka hiçbir hata yeniden denenmez.
- `/sifre-sifirla` sonucu operatöre `[auth] password reset delivery failed|recovered …` server logu olarak gider; ziyaretçi her durumda aynı generic metni görür; yalnız HTTP 525 bir kez yeniden denenir.
- Ürün ana verisi (Faz 6A): `sku` DB'de zorunlu kalır (POS/mal kabul/stok ona dayanır), UI ön ek + değer kodlarından türetir. `style_code` tekil **değildir** (uyarı). Seçenekler işletme geneli; `kind` yalnız UX ipucu. `color_hex` görünüm içindir, kimlik değildir. Matris `rpc_generate_variants` ile tek transaction (idempotent). Görseller özel `product-images` bucket'ında `business/<id>/products/<pid>/<uuid>.<ext>`; okuma yalnız imzalı URL (60 dk), yazma manager+; storage RLS `fn_storage_business_id` ile yol segmentini okur. Ürün/varyant **silinmez**, arşivlenir (history FK'ları RESTRICT).
- Tenant çözümlemesi yalnız sunucuda (`lib/tenant.ts`): `business_members` (aktif) → `businesses` →
  `branches`. 0 üyelik → `/no-access`, 1 → otomatik, çok → `/select-business`. Cookie yalnız *tercih*
  taşır ve her istekte PostgreSQL'e karşı yeniden doğrulanır.
- Tip güvenliği: `any` eklenmez. Kütüphane tipleri yetmiyorsa `lib/supabase/cookies.ts`'teki gibi
  yapısal tip tanımlanır.
- `next lint` deprecated (Next 16'da kalkacak) — bilinçli teknik borç, şimdilik değiştirilmiyor.
- UI yönü: sıcak nötr palet, ince çizgiler (gölge değil), küçük radius, yoğun ve profesyonel.
  Gradient, renkli SaaS kartları, sahte analitik yok. Arayüz metinleri Türkçe.

---

## Çalışma tarzı

- Önce oku, sonra yaz: ilgili dosyaları ve `docs/` altındaki kararları incelemeden değişiklik yapma.
- Küçük ve doğrulanabilir adımlar; her adımdan sonra ilgili gate'i çalıştır.
- Koşmadığın komut için "PASS" yazma. Çalıştıramadıysan açıkça söyle.
- Hata bulduğunda kök nedeni açıkla; belirtiyi bastırma (örn. tip hatasını `any` ile susturma).
- Bir karar mimariyi etkiliyorsa (şema, RLS, faz sırası) uygulamadan önce sor.
