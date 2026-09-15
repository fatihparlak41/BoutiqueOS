# Supabase support note — fresh-JWT rejection (PGRST303) and intermittent 525

Prepared 2026-09-14, updated the same day. **Not sent yet.** Paste into a Supabase support
ticket as-is. Nothing below claims an upstream fix; it reports what we measured and what we
worked around on our side.

---

**Project ref:** `fpmcnovurkpjwhosrkms`
**Caller environment:** Vercel Production (Next.js 15.5 server actions / server components,
`@supabase/ssr` 0.12.6, `@supabase/auth-js` 2.116.0, `@supabase/postgrest-js` via
`@supabase/supabase-js` 2.116.0)
**Auth version:** GoTrue `v2.196.0` (from `GET /auth/v1/health`)
**PostgREST version:** not discoverable from the client (`GET /rest/v1/` OpenAPI answers 401
with the anon key on this project); please read it from your side.
**Request ids:** not captured by the client library; the timestamps below should locate the
requests in your logs.

## Issue 1 — PostgREST rejects a token Auth has just issued: PGRST303 "JWT issued at future"

**Flow:** password recovery → `POST /auth/v1/verify` (token_hash, type=recovery) → session →
`PUT /auth/v1/user` (password update, 200) → server-side redirect → first PostgREST read
with the current token (`GET /rest/v1/business_members?...`).

**Observed:** PostgREST answers `PGRST303` / `JWT issued at future`. Reproduced twice:

- 2026-09-14 **09:29:43 UTC** — `PUT /user` 200 at 09:29:43.83; the immediately following
  `business_members` read failed with "JWT issued at future" (our error digest 711079145).
- 2026-09-14 **10:37:15 UTC** (second live run, after deploying a 1.2 s single retry on that
  read) — recovery verified 10:37:05, `PUT /user` 200 at 10:37:15.72; the following
  `business_members` read failed again with `PGRST303` / "JWT issued at future", i.e. the
  skew outlasted the 1.2 s retry.

The token itself is valid (same session reads succeed seconds later; `GET /auth/v1/user`
succeeds throughout). It looks like the `iat` on a freshly minted token is ahead of the
PostgREST verifier's clock by more than one second at times.

**Our workaround (deployed):** the first tenant read retries once after 1.2 s; if PGRST303
persists, the visitor is parked on a page that polls a read-only probe at 0/1/2/4/8 s
(~15 s) and continues once the token is accepted. No service role, no relaxed validation.

**Ask:** please check clock alignment / `iat` tolerance between the Auth issuer and the
PostgREST verifier for this project, and whether a leeway is configurable on your side.

## Issue 2 — intermittent HTTP 525 on `POST /auth/v1/recover`

**Observed:** `AuthRetryableFetchError`, status **525**, empty body (non-JSON), returned to
the Vercel function. Other calls from the same runtime in the same minutes succeed.

- 2026-09-14 ~**08:55:30 UTC** — same symptom, before server-side logging existed
- 2026-09-14 ~**10:20:50 UTC** — logged: `name=AuthRetryableFetchError status=525 code=null`

For these attempts the request **never appears in Supabase Auth logs**;
`auth.users.recovery_sent_at` is not updated and no `auth.one_time_tokens` row is created.
A successful attempt at 09:27:03 UTC and at 10:33:28 UTC from the same code path shows
`POST /recover 200`.

**Our workaround (deployed):** exactly one retry after ~1.7 s, only on 525, only for this
endpoint.

**Ask:** please inspect edge ↔ origin TLS handshake failures for this project in the two
windows above (±2 minutes).

## Addendum — 2026-09-14 ~13:35–13:40 UTC

Right after a magic-link session was established (`POST /auth/v1/verify`), the first
requests to `/app` and `/app/urunler` returned 500 twice within a few minutes, then the same
session returned 200 for every page. One `POST /auth/v1/verify` round trip exceeded 30 s in
the same window. Consistent with the fresh-token / Auth latency pattern above; not reproduced
afterwards.

Route review (2026-09-15, no code change): the failing routes were `/app`, `/app/urunler`
and `/app/stok` (chain `/app/stok → 307 /login → 307 /app → 500`). All three render under
`app/app/layout.tsx` → `requireTenant()` → `loadMemberships()`, which already carries the
single "JWT issued at future" retry and the `/auth/session-ready` hand-off, so none of them
bypasses that path. The responses were plain 500s without a Next error digest, which points
at the request failing before the RSC render (session refresh / Auth upstream) rather than at
the tenant read. No speculative retry expansion was made.

