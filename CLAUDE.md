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
| Faz 3+ (Stok, Kasa, Tedarikçi, Raporlar…) | **Başlamadı** — READY FOR PHASE 3 PLANNING |

Ayrıntılı denetim: `docs/10_AUDIT_REVIEW.md`. Mimari kararlar: `docs/09_DECISIONS.md`.

---

## Değiştirilmesi YASAK olanlar

1. **Uygulanmış migration'lar.** `supabase/migrations/20260908000001–04` remote'ta kayıtlı; yerinde
   düzenlenmez. Her şema/RPC değişikliği yeni timestamp'li dosyayla gider (`20260908000005_*.sql`).
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
`.\scripts\db_fresh.ps1 -Init`.

## Frontend gate'i (her bağımlılık/kod değişikliğinde)

```powershell
npm run lint
npm run build
npm run typecheck
```

Bağımlılık değiştiyse önce temiz kurulum: `node_modules` ve `package-lock.json` silinir, `npm install`,
ardından `npm ls @supabase/supabase-js @supabase/auth-js @supabase/ssr next postcss` ve `npm audit --omit=dev`.

---

## Sabit teknik kararlar

- Cookie API'si güncel `@supabase/ssr` sözleşmesi: `getAll()` / `setAll(cookiesToSet, headers)`.
  Middleware sırayla: request'e cookie yaz → `NextResponse.next({ request })` → yanıta cookie yaz →
  dönen cache header'larını yanıta kopyala. Yönlendirmelerde bu cookie'ler redirect yanıtına taşınır.
- Yetkilendirme `supabase.auth.getClaims()` ile. `getSession()` yetki kararı için **kullanılmaz**.
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
