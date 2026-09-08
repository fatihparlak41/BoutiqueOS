# BoutiqueOS

Multi-tenant boutique retail SaaS. Pilot: **Things Like Crop** (Lefkoşa).
Stack: Next.js / TypeScript / Tailwind / shadcn · Supabase (PostgreSQL, Auth, Storage, RLS) · Vercel.

**Mevcut gate:** Architecture → **Rev 3 Schema** → Fresh-DB verification → DEV Supabase apply → seed → smoke → *sonra* frontend.
Frontend (`app/`) bu gate geçilmeden başlamaz.

## Yerleşim

```
docs/                      00–02 mimari, 09 ADR, 10 audit, 11 Rev 3 pre-flight
supabase/migrations/       001_schema … 004_rpc_posting   (Supabase CLI bunu okur)
seeds/                     seed_things_like_crop.sql
tests/                     000_test_harness.sql (yalnız yerel), 005_verification_tests.sql
scripts/db_fresh.ps1       sıfır DB → migrations → seed → testler
bootstrap.ps1              ilk kurulum (bir kez)
```

## İlk kurulum (Windows, PowerShell)

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd E:\BoutiqueOS\Butik
.\bootstrap.ps1 -Root "E:\BoutiqueOS\Butik"     # klasörler, git, scoop: git/postgresql/supabase
copy .env.example .env
.\scripts\db_fresh.ps1 -Init                     # yerel cluster (.pgdata, port 5433)
```

## Fresh-DB doğrulama (her SQL revizyonunda)

```powershell
.\scripts\db_fresh.ps1                 # Plain PostgreSQL + 000 harness (auth.uid() mock)
.\scripts\db_fresh.ps1 -Mode Supabase  # Docker'daki supabase local stack (gerçek auth şeması)
```

Çıktı: `PASS: n  FAIL/ERROR: m`, ayrıntı `tests\results\last_run.log`. Exit code 1 = bir şey kırık.
İki mod da geçmeden "READY FOR DEV APPLY" denmez.

Supabase local için ayrıca (bir kez): `supabase init` (zaten `supabase/` varsa atla) ve `supabase start` (Docker Desktop gerekir).

## Dokümanlar okunma sırası

1. `docs/00_PROJECT_OVERVIEW.md`
2. `docs/09_DECISIONS.md` (ADR-01…13)
3. `docs/11_REV3_PREFLIGHT_REPORT.md` — **güncel durum**; bölüm J'deki kararlar Rev 3 SQL'i bloke ediyor
4. `docs/10_AUDIT_REVIEW.md` — Rev 3 ile yeniden yazılacak (mevcut hali koda göre hatalı)

## Kurallar (kısa)

- Migration'lar elle Supabase Studio'ya yapıştırılmaz; `supabase db push` / CI ile gider.
- `.env` commit edilmez. Service-role key frontend'e girmez.
- Ledger, cost pool, posted belge tablolarına client yazmaz; yalnız SECURITY DEFINER RPC.
