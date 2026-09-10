import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/server";
import { safeRedirectPath, siteOrigin } from "@/lib/url";

/**
 * The single landing point for every Supabase auth email: invitation, magic link and
 * password recovery.
 *
 * Contract, matching Supabase's documented server-side verification pattern:
 *
 *   template link -> /auth/confirm?token_hash={{ .TokenHash }}&type=...&redirect_to={{ .RedirectTo }}
 *
 * {{ .RedirectTo }} is the value passed as `redirectTo` to the auth method, so the
 * per-invitation destination survives. {{ .SiteURL }} is static and would not.
 *
 * token_hash is used rather than PKCE because @supabase/auth-js 2.116 states that PKCE
 * is not supported for admin invitations — the browser that sends an invite is usually
 * not the one that opens it. verifyOtp needs no verifier, runs server-side and writes
 * the session cookies through @supabase/ssr. A `code` parameter is still accepted for
 * the flows that do start in the same browser.
 *
 * redirect_to comes back through an email and is therefore untrusted: it is re-checked
 * against this deployment's own origin and against an explicit path allowlist before it
 * is followed.
 */

// The union really is this: 'signup' | 'invite' | 'magiclink' | 'recovery' |
// 'email_change' | 'email' (@supabase/auth-js types.d.ts:745). It widens with
// `(string & {})`, so the runtime guard below is what actually constrains the value.
const EMAIL_OTP_TYPES = [
  "invite",
  "magiclink",
  "recovery",
  "signup",
  "email_change",
  "email",
] as const satisfies readonly EmailOtpType[];

function isEmailOtpType(value: string | null): value is (typeof EMAIL_OTP_TYPES)[number] {
  return value !== null && (EMAIL_OTP_TYPES as readonly string[]).includes(value);
}

export async function GET(request: NextRequest) {
  const params = request.nextUrl.searchParams;
  const origin = siteOrigin(request.nextUrl.origin);

  // `redirect_to` is the documented parameter name; `next` stays accepted as a
  // relative-only convenience for links this app builds itself.
  const destination = safeRedirectPath(
    params.get("redirect_to") ?? params.get("next"),
    origin,
    "/app",
  );

  const fail = (reason: string) =>
    NextResponse.redirect(new URL(`/sifre-sifirla?durum=${reason}`, origin));

  const supabase = await createClient();

  const tokenHash = params.get("token_hash");
  const type = params.get("type");

  if (tokenHash && isEmailOtpType(type)) {
    const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type });
    if (error) return fail("gecersiz");
    return NextResponse.redirect(new URL(destination, origin));
  }

  const code = params.get("code");
  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) return fail("gecersiz");
    return NextResponse.redirect(new URL(destination, origin));
  }

  // No usable credential in the link at all.
  return fail("gecersiz");
}
