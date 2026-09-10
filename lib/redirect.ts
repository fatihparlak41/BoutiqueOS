/**
 * Redirect validation for auth email links.
 *
 * Pure and dependency-free on purpose: no "server-only", no Next imports, no I/O. That
 * is what lets tests/redirect/check_redirect.ts run it directly under Node and assert
 * the open-redirect cases without a browser or a database.
 *
 * The contract these functions defend:
 *
 *   redirectTo handed to a Supabase auth method  = the FINAL BoutiqueOS destination
 *   the email template forwards it as redirect_to={{ .RedirectTo }}
 *   /auth/confirm verifies the token, then sends the visitor to that destination
 *
 * Because the value makes a round trip through an email, it comes back attacker-shaped
 * and must be re-validated. Only a destination on this deployment's own origin is ever
 * followed; anything else falls back.
 */

/** Paths an auth email may legitimately land on. Everything else falls back. */
const ALLOWED_PREFIXES = ["/davet/", "/sifre-belirle", "/app"] as const;

/**
 * Control characters, written as escapes rather than as literal bytes. A literal one in
 * the source makes git treat the whole file as binary, which hides the diff from review,
 * and tooling that splits on Unicode line boundaries mangles the line.
 */
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;

function isAllowedPath(path: string): boolean {
  return ALLOWED_PREFIXES.some((p) => path === p || path.startsWith(p));
}

/**
 * Narrows an untrusted `next`-style value to a path on this site.
 *
 * Rejected: absolute URLs, protocol-relative "//evil.test" (a browser treats it as
 * absolute), backslash variants that some parsers fold to "/", control characters
 * (header injection), and anything with a scheme such as "javascript:".
 */
export function safeNextPath(next: string | null | undefined, fallback = "/app"): string {
  if (typeof next !== "string") return fallback;
  const value = next.trim();

  if (value === "") return fallback;
  if (!value.startsWith("/")) return fallback;
  if (value.startsWith("//")) return fallback;
  if (value.includes("\\")) return fallback;
  if (CONTROL_CHARS.test(value)) return fallback;
  if (/^\/[a-z][a-z0-9+.-]*:/i.test(value)) return fallback;

  return value;
}

/**
 * Turns the redirect_to value that came back from an email into a path, but only when
 * it points at this deployment.
 *
 * Accepts an absolute URL whose origin equals `origin` exactly (scheme, host and port),
 * or a relative path. Everything else — a different host, a different scheme, a
 * userinfo trick like https://site@evil.test — falls back.
 */
export function safeRedirectPath(
  redirectTo: string | null | undefined,
  origin: string,
  fallback = "/app",
): string {
  if (typeof redirectTo !== "string") return fallback;
  const value = redirectTo.trim();
  if (value === "") return fallback;
  if (CONTROL_CHARS.test(value)) return fallback;

  // Relative form: the same rules as any other next value.
  if (value.startsWith("/")) {
    const path = safeNextPath(value, fallback);
    return isAllowedPath(path) ? path : fallback;
  }

  let parsed: URL;
  let base: URL;
  try {
    parsed = new URL(value);
    base = new URL(origin);
  } catch {
    return fallback;
  }

  // Strict same-origin. URL.origin normalises the default port, and a userinfo
  // component never survives into it, so "https://good.test@evil.test" compares as
  // evil.test and is refused.
  if (parsed.origin !== base.origin) return fallback;
  if (parsed.username !== "" || parsed.password !== "") return fallback;

  const path = `${parsed.pathname}${parsed.search}`;
  return isAllowedPath(path) ? path : fallback;
}

/** The exact paths an auth email is allowed to target. Exported for the tests. */
export const AUTH_DESTINATION_PREFIXES = ALLOWED_PREFIXES;
