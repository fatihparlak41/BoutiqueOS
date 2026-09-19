# Auth Delivery Configuration — Phase 4

Dashboard configuration that lives outside the repository but that the code depends on.
Kept here so a rollout is reproducible and a drifted setting is discoverable.

---

## Redirect contract

```
auth method redirectTo   =  the FINAL BoutiqueOS destination
    new user invite      →  https://butikos.parlakmediatech.com.tr/davet/<invite_id>
    existing user link   →  https://butikos.parlakmediatech.com.tr/davet/<invite_id>
    password recovery    →  https://butikos.parlakmediatech.com.tr/sifre-belirle

email template           →  /auth/confirm?token_hash=…&type=…&redirect_to={{ .RedirectTo }}

/auth/confirm            →  verifyOtp(token_hash, type)
                            writes the session cookies (@supabase/ssr)
                            validates redirect_to (strict same-origin + path allowlist)
                            redirects there
```

`{{ .SiteURL }}` is static, so it can only carry the origin of our own endpoint. The
per-invitation destination has to ride on `{{ .RedirectTo }}`, which Supabase documents
as "the redirect URL passed when signUp, signInWithOtp … or inviteUserByEmail is called".
Putting the destination in `{{ .SiteURL }}` would lose the invitation id.

`token_hash` rather than PKCE: `@supabase/auth-js` 2.116 states that PKCE is not
supported for `inviteUserByEmail`, because the browser that sends an invitation is
usually not the one that opens it.

Validation lives in `lib/redirect.ts` and is covered by `npm run test:redirect`.

---

## Authentication → URL Configuration

**Site URL** — verified on the dashboard 2026-09-19

```
https://butikos.parlakmediatech.com.tr
```

**Redirect URLs** — minimum set, no global globstar. Verified on the dashboard
2026-09-19 for the production origin: the wildcard entry was removed and the four explicit
production lines below are what is configured. The localhost lines are the local-development
equivalents and were not part of that check:

```
https://butikos.parlakmediatech.com.tr/davet/*
https://butikos.parlakmediatech.com.tr/sifre-belirle
https://butikos.parlakmediatech.com.tr/basvuru
https://butikos.parlakmediatech.com.tr/app
http://localhost:3000/davet/*
http://localhost:3000/sifre-belirle
http://localhost:3000/basvuru
http://localhost:3000/app
```

`/app` is listed because `lib/redirect.ts` allows it as an auth destination (the
fallback when a link carries no usable `redirect_to`); every entry mirrors one prefix of
`AUTH_DESTINATION_PREFIXES`, nothing wider.

`/basvuru` (Phase 13A) is where the signup confirmation lands: `registerAction` passes
`emailRedirectTo = <origin>/basvuru`. Without this entry Supabase falls back to the Site
URL and the confirmed registrant reaches `/` instead of the application form (the app
still routes them there on the next `/app` visit — `requireTenant` sends a confirmed
account with an unsent draft to `/basvuru` — so a missing entry degrades, it does not
break).

`*` matches any run of non-separator characters, and the separators are `.` and `/`. A
UUID contains neither, so a single star covers `/davet/<uuid>` exactly; `**` is not
needed and would be wider than necessary.

`/auth/confirm` is deliberately NOT listed. Supabase never redirects there — the link in
the email points at it directly. The allow list only constrains `redirectTo` values.

---

## Authentication → Email Templates

Four templates, because the code uses four flows (Phase 13A added public signup).
Configuring only Invite and Reset Password would leave the other paths sending an
unmodified default link.

### Invite User

Used when the address has no Auth account: `auth.admin.inviteUserByEmail`.

```html
<h2>BoutiqueOS ekibine davet edildiniz</h2>
<p>Hesabınızı oluşturmak ve ekibe katılmak için:</p>
<p>
  <a href="{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=invite&redirect_to={{ .RedirectTo }}">
    Daveti kabul et
  </a>
</p>
<p>Bu bağlantı sınırlı bir süre için geçerlidir. Süresi dolarsa yeni bir davet bağlantısı isteyebilirsiniz.</p>
```

The closing sentence deliberately does not name a duration. Two independent expiries are
in play — `business_invites.expires_at` (ours, 7 days by default) and the Supabase Auth
link lifetime (a separate dashboard setting) — and the link stops working when the
*shorter* one lapses. Printing "24 hours" would state one of them as if it were both.

### Magic Link

Used when the address already has a confirmed account, i.e. the person works for another
BoutiqueOS tenant: `signInWithOtp({ shouldCreateUser: false })`.

```html
<h2>BoutiqueOS oturum bağlantınız</h2>
<p>Devam etmek için:</p>
<p>
  <a href="{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=magiclink&redirect_to={{ .RedirectTo }}">
    Oturum aç
  </a>
</p>
<p>Bu bağlantıyı siz istemediyseniz bu e-postayı yok sayabilirsiniz.</p>
```

### Confirm signup (Phase 13A — verified live 2026-09-19)

Used by public registration: `supabase.auth.signUp` from `/kayit`. The default template
links to `{{ .ConfirmationURL }}`, which is Supabase's own `/auth/v1/verify` endpoint;
that endpoint completes the PKCE flow only in the browser that started the signup and
sends the visitor to the Site URL. The contract below keeps every email on the same
server-side `token_hash` path as the other three and lands on `/basvuru`.

Subject: `BoutiqueOS hesabınızı doğrulayın`

```html
<h2>BoutiqueOS hesabınızı doğrulayın</h2>
<p>Başvurunuzu tamamlamak için e-posta adresinizi doğrulayın:</p>
<p>
  <a href="{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=email&redirect_to={{ .RedirectTo }}">
    Adresimi doğrula
  </a>
</p>
<p>Bu kaydı siz yapmadıysanız bu e-postayı yok sayabilirsiniz; hiçbir hesap açılmaz.</p>
```

The dashboard template uses `type=email`, the value Supabase documents for a signup
confirmation verified through `token_hash`; `/auth/confirm` accepts both `email` and
`signup` (same `verifyOtp` call), so either spelling satisfies the contract. Auth → Sign
In / Providers → Email: **Confirm email ON** (`mailer_autoconfirm=false`) and **Allow new
users to sign up ON** (`disable_signup=false`), both verified live.

**Real signup e-mail E2E — PASS (2026-09-19, DEV project, custom SMTP).** A disposable
synthetic address (`fatihparlak1+zz13a@gmail.com`) went through the live `/kayit` form
(4 steps, 390 px), the confirmation mail arrived through the configured custom SMTP
sender, the person clicked the real link (no admin-API confirmation, no token shared),
`/auth/confirm` verified it server-side, wrote the session and redirected to `/basvuru`
with the signup draft restored (ZZ E2E MAIL TEST · TR / TRY · Starter); the application
was submitted and `/basvuru-bekliyor` rendered "İnceleniyor". Read-only proof afterwards:
`email_confirmed_at` set, exactly one `pending` application with plan `starter`, no
business / membership / branch / subscription row, TLC snapshot identical. Neither the
invite nor the recovery template was touched.

### Reset Password

```html
<h2>Parolanızı sıfırlayın</h2>
<p>Yeni parolanızı belirlemek için:</p>
<p>
  <a href="{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=recovery&redirect_to={{ .RedirectTo }}">
    Yeni parola belirle
  </a>
</p>
<p>Bu isteği siz yapmadıysanız hiçbir şey yapmanız gerekmez; parolanız değişmez.</p>
```

`type` values are the real union from `@supabase/auth-js` `types.d.ts`:
`'signup' | 'invite' | 'magiclink' | 'recovery' | 'email_change' | 'email'`. Because the
union widens with `(string & {})`, `/auth/confirm` also guards the value at runtime.

---

## Environment variables

| Name | Where | Notes |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | local + Vercel | public |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | local + Vercel | public |
| `NEXT_PUBLIC_SITE_URL` | local `http://localhost:3000`, Vercel `https://butikos.parlakmediatech.com.tr` | canonical origin for auth links |
| `SUPABASE_SECRET_KEY` | local `.env.local` + Vercel (Production + Preview) | **server only**, never `NEXT_PUBLIC_` |

`SUPABASE_SECRET_KEY` takes the project's secret API key: `sb_secret_…` on a project that
has migrated to the new API keys, otherwise the legacy `service_role` JWT. supabase-js
sends either identically, so one variable name covers both and there is never a second
name to keep in sync. Prefer `sb_secret_…` where available: it is revocable on its own,
rotatable without invalidating anything else, and is not a JWT carrying a permanent
`service_role` claim.

Read by exactly one module, `lib/supabase/admin.ts`, whose first line is
`import "server-only"`. It exports no client — only `isAdminAuthConfigured()` and
`sendInviteEmail()`.

---

## Recovery session gate

`/sifre-belirle` and `setPasswordAction` accept only a session the gate in
`lib/auth/recovery-session.ts` recognises as password recovery. Facts the gate is built on,
verified 2026-09-14 against `auth.mfa_amr_claims` and supabase/auth `internal/api/verify.go`:

* Every emailed link — invite, magic link, recovery — is verified through `/verify` and
  GoTrue records `amr: [{ method: "otp" }]` for all of them. There is **no** `recovery`
  AMR method for email recovery; the claim alone cannot separate recovery from a magic link.
* `users.recovery_sent_at` is set when the recovery email is sent and cleared by GoTrue
  when the password is updated; GET /user exposes it.
* `amr[].timestamp` is the session's birth and survives token refreshes; `iat` does not.

Gate = `otp` session **and** pending `recovery_sent_at` **and** session born after it. A
password login is refused; after the password is set the same session stops qualifying.
Accepted edge: GoTrue writes `recovery_sent_at` for magic links as well (same token fields), so
a magic-link session passes the gate too until the next password update — same mailbox
proof; a password login never passes. Covered by `npm run test:recovery`.

A token minted by Auth can be a second ahead of PostgREST's clock ("JWT issued at
future", seen live right after a password update). The tenant bootstrap retries that one
read once after ~1.2 s (`lib/auth/jwt-skew.ts`, `npm run test:jwt-skew`); nothing else is
retried.

---

## Known operational limits

* The project sends through a **custom SMTP** sender (Authentication → SMTP Settings);
  verified unchanged on the dashboard 2026-09-19 (no credentials are recorded here).
  Supabase's built-in SMTP would be rate limited (`over_email_send_rate_limit`, HTTP 429)
  and restricted to team addresses, which is why it is not used.
* If magic links are disabled for the project, the existing-user path fails with
  `otp_disabled` (HTTP 501). The UI surfaces that as its own message rather than a
  generic failure.
* Delivery outcome (`invited` vs `magic_link`) is never surfaced to the inviter, so an
  inviter cannot learn whether an address already has an account.
* `/sifre-sifirla` always answers with the same generic sentence; `resetPasswordForEmail`
  never throws, so a delivery failure (transport error, gateway rejection, Auth error) is
  visible **only** as a server log line `[auth] password reset delivery failed` with
  `name / status / code / message` — no address, no URL. If Supabase Auth Logs show no
  `POST /recover` for a request, look there (Vercel → Functions logs).
