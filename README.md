# BoutiqueOS

Multi-tenant boutique retail SaaS. Pilot: **Things Like Crop** (Lefkoşa).
Stack: Next.js / TypeScript / Tailwind / shadcn · Supabase (PostgreSQL, Auth, Storage, RLS) · Vercel.

**Mevcut gate:** Architecture → Rev 3 Schema (yazıldı) → **Fresh-DB verification (şimdi burada)** → DEV Supabase apply → seed → smoke → *sonra* frontend.
Frontend (`app/`) bu gate geçilmeden başlamaz. `supabase db push` gate geçilmeden **çalıştırılmaz**.

**Durum:** `AWAITING FRESH-DB VERIFICATION` — bkz. `docs/10_AUDIT_REVIEW.md`.

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
