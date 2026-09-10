import "server-only";

import { safeNextPath, safeRedirectPath } from "@/lib/redirect";

export { safeNextPath, safeRedirectPath };

/**
 * Canonical origin of this deployment. NEXT_PUBLIC_SITE_URL is authoritative when set;
 * otherwise the caller passes the request origin, which Vercel validates against the
 * project's domains.
 */
export function siteOrigin(requestOrigin?: string): string {
  const configured = process.env.NEXT_PUBLIC_SITE_URL?.trim();
  const raw = configured && configured.length > 0 ? configured : requestOrigin;

  if (!raw) {
    throw new Error(
      "Missing NEXT_PUBLIC_SITE_URL and no request origin. Auth links cannot be built without a canonical origin.",
    );
  }
  return raw.replace(/\/+$/, "");
}

/**
 * The absolute URL handed to a Supabase auth method as `redirectTo`.
 *
 * This is the FINAL destination inside BoutiqueOS — /davet/<invite id> or
 * /sifre-belirle — not an intermediate callback. The email template carries it through
 * as {{ .RedirectTo }} and /auth/confirm sends the visitor there after verifying the
 * token. Routing it through the callback here instead would force the destination into
 * the static {{ .SiteURL }} and lose the invitation id, which is per-invite and dynamic.
 */
export function authDestinationUrl(path: string, requestOrigin?: string): string {
  return new URL(safeNextPath(path), siteOrigin(requestOrigin)).toString();
}
