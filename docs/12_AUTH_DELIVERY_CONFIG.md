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

**Site URL**

```
https://butikos.parlakmediatech.com.tr
```

**Redirect URLs** — minimum set, no global globstar:

```
https://butikos.parlakmediatech.com.tr/davet/*
https://butikos.parlakmediatech.com.tr/sifre-belirle
http://localhost:3000/davet/*
http://localhost:3000/sifre-belirle
```

`*` matches any run of non-separator characters, and the separators are `.` and `/`. A
UUID contains neither, so a single star covers `/davet/<uuid>` exactly; `**` is not
needed and would be wider than necessary.

`/auth/confirm` is deliberately NOT listed. Supabase never redirects there — the link in
the email points at it directly. The allow list only constrains `redirectTo` values.

---

## Authentication → Email Templates

Three templates, because the code uses three flows. Configuring only Invite and Reset
Password would leave the existing-user path sending an unmodified default link.

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

## Known operational limits

* Supabase's built-in SMTP is rate limited (`over_email_send_rate_limit`, HTTP 429). Fine
  for a five-person pilot; a real SaaS needs custom SMTP.
* If magic links are disabled for the project, the existing-user path fails with
  `otp_disabled` (HTTP 501). The UI surfaces that as its own message rather than a
  generic failure.
* Delivery outcome (`invited` vs `magic_link`) is never surfaced to the inviter, so an
  inviter cannot learn whether an address already has an account.
