import "server-only";

import { createClient, type AuthError, type SupabaseClient } from "@supabase/supabase-js";
import { publicSupabaseEnv } from "@/lib/env";

/**
 * The ONE place in this codebase that may hold a privileged Supabase key.
 *
 * Rules this module exists to keep:
 *
 *  * `import "server-only"` on the first line. Importing this from a client component
 *    is a build error, not a runtime surprise.
 *  * The variable is NOT prefixed with NEXT_PUBLIC_, so Next never inlines it into a
 *    browser bundle.
 *  * The client it builds is never exported. Only the narrow operations below leave
 *    this file, so a privileged client cannot spread through the app as a
 *    general-purpose "admin supabase" import.
 *  * A privileged key bypasses RLS entirely. Every authorisation decision is therefore
 *    made in the database BEFORE anything here is called: rpc_create_invite proves the
 *    caller's membership and rank, rpc_invite_delivery_target resolves the address.
 *    This module only delivers mail to an address the database already approved.
 *
 * ONE environment variable, by design — never both:
 *
 *   SUPABASE_SECRET_KEY
 *
 * Put the project's *secret* API key in it. On a project that has migrated to the new
 * API keys that is the `sb_secret_...` value; on a project that still uses the legacy
 * pair it is the `service_role` JWT. supabase-js sends either identically, so the code
 * does not need to know which one it received and the deployment does not need two
 * names to keep in sync.
 *
 * Prefer `sb_secret_...` when the project offers it: it is revocable on its own, can be
 * rotated without invalidating anything else, is not a JWT carrying a permanent
 * `service_role` claim, and appears in the dashboard as a named, auditable key.
 */

export class MissingAdminKeyError extends Error {
  constructor() {
    super("SUPABASE_SECRET_KEY is not configured");
    this.name = "MissingAdminKeyError";
  }
}

/** Raised for a delivery failure the operator has to act on, with a Turkish sentence. */
export class DeliveryError extends Error {
  constructor(public readonly reason: DeliveryFailure, message: string) {
    super(message);
    this.name = "DeliveryError";
  }
}

export type DeliveryFailure = "otp_disabled" | "rate_limited" | "unknown";

/** True when invitation delivery can actually run. Lets the UI say so honestly. */
export function isAdminAuthConfigured(): boolean {
  const key = process.env.SUPABASE_SECRET_KEY;
  return typeof key === "string" && key.trim().length > 0;
}

function adminClient(): SupabaseClient {
  const key = process.env.SUPABASE_SECRET_KEY?.trim();
  if (!key) throw new MissingAdminKeyError();

  const { url } = publicSupabaseEnv();

  // No session persistence and no auto refresh: this client is used for one call inside
  // one request and must never write auth state anywhere.
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}

/**
 * Auth error codes, from Supabase's published list:
 *   email_exists / user_already_exists  422  the address already has an account
 *   otp_disabled                        501  magic links are switched off for the project
 *   over_email_send_rate_limit          429  too many emails to this address
 */
function isAlreadyRegistered(error: AuthError): boolean {
  const code = error.code ?? "";
  return code === "email_exists" || code === "user_already_exists" || error.status === 422;
}

function classify(error: AuthError): DeliveryError {
  const code = error.code ?? "";
  if (code === "otp_disabled" || error.status === 501) {
    return new DeliveryError(
      "otp_disabled",
      "Bu Supabase projesinde sihirli bağlantı (magic link) kapalı. Mevcut hesabı olan bir kullanıcı davet edilemiyor.",
    );
  }
  if (code === "over_email_send_rate_limit" || error.status === 429) {
    return new DeliveryError(
      "rate_limited",
      "Bu adrese kısa sürede çok fazla e-posta gönderildi. Bir süre sonra tekrar deneyin.",
    );
  }
  return new DeliveryError("unknown", "Davet e-postası gönderilemedi.");
}

export type DeliveryOutcome = "invited" | "magic_link" | "not_configured";

/**
 * Sends the single email a colleague receives.
 *
 * `destination` is the FINAL BoutiqueOS URL — /davet/<invite id> for an invitation,
 * /sifre-belirle for recovery. Supabase carries it into the template as
 * {{ .RedirectTo }}; /auth/confirm verifies the token and then sends the visitor there.
 *
 * Two Auth cases, and the design deliberately does not depend on knowing which applies:
 *
 *   A. the address has no account -> inviteUserByEmail creates it with no password and
 *      mails Supabase's invitation. Sign-ups stay closed; this is the only way an
 *      account comes into existence.
 *
 *   B. the address already has an account, because the person works for another
 *      BoutiqueOS tenant -> the invite is refused with email_exists / user_already_exists
 *      and a magic link is sent instead, with shouldCreateUser: false so no account can
 *      be created under any circumstance.
 *
 * Whether GoTrue re-sends an invitation to an invited-but-unconfirmed account or answers
 * 422 is not documented, and this function does not assume either: both branches end at
 * the same destination with one working link, so a resend is correct under both
 * behaviours. Only the template differs — Invite in case A, Magic Link in case B — which
 * is why both templates must be configured.
 *
 * `email` MUST come from rpc_invite_delivery_target, never from the client: otherwise
 * this is a mail relay pointed at any address an attacker chooses.
 */
export async function sendInviteEmail(email: string, destination: string): Promise<DeliveryOutcome> {
  if (!isAdminAuthConfigured()) return "not_configured";

  const admin = adminClient();
  const { error } = await admin.auth.admin.inviteUserByEmail(email, { redirectTo: destination });

  if (!error) return "invited";
  if (!isAlreadyRegistered(error)) throw classify(error);

  const { error: otpError } = await admin.auth.signInWithOtp({
    email,
    options: { shouldCreateUser: false, emailRedirectTo: destination },
  });
  if (otpError) throw classify(otpError);

  return "magic_link";
}
