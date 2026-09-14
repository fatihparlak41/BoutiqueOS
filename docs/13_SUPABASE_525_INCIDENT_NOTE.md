# Supabase support note — intermittent 525 on POST /auth/v1/recover

Prepared 2026-09-14. **Not sent yet.** Paste into a Supabase support ticket as-is.

---

**Project ref:** `fpmcnovurkpjwhosrkms`
**Caller environment:** Vercel Production (Next.js 15.5 server action, `@supabase/ssr` 0.12.6 / `@supabase/auth-js` 2.116.0)
**Endpoint:** `POST https://fpmcnovurkpjwhosrkms.supabase.co/auth/v1/recover`

**Observed:** intermittent `AuthRetryableFetchError` with HTTP status **525** returned to
the client (non-JSON body, so auth-js classifies it as retryable). Other calls from the same
runtime in the same minutes (GET /auth/v1/user, PostgREST reads) succeed.

**Known occurrences (UTC):**
- 2026-09-14 ~08:55:30 — same symptom, before we had server-side logging of the failure
- 2026-09-14 ~10:20:50 — logged: `name=AuthRetryableFetchError status=525 code=null message=<empty>`

A successful call at 2026-09-14 09:27:03 UTC from the same code path shows `POST /recover 200`
in Auth logs, so the request shape is fine.

**Symptom on your side:** for the failing attempts the request **never appears in Supabase
Auth logs**; `auth.users.recovery_sent_at` is not updated and no `auth.one_time_tokens` row
is created. 525 is an edge ↔ origin SSL/TLS handshake failure, which matches "never reached
GoTrue".

**Ask:** please inspect edge/origin TLS handshake failures for this project around the two
windows above (±2 minutes) and tell us whether this is a known transient on the Auth origin
or something specific to this project's routing.

**Mitigation on our side (deployed 2026-09-14):** exactly one retry after ~1.7 s, only when
the first attempt returns 525, only for this endpoint; all other statuses are final.
