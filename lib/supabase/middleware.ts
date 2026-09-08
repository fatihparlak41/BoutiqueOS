import { NextResponse, type NextRequest } from "next/server";
import { createServerClient, type CookieMethodsServer } from "@supabase/ssr";
import { publicSupabaseEnv } from "@/lib/env";

const PROTECTED_PREFIXES = ["/app", "/select-business", "/no-access"];

/**
 * Refreshes the Supabase session on every request and enforces the two routing rules:
 * unauthenticated -> /login, authenticated on /login -> /app (tenant entry).
 */
export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });

  /**
   * Cache headers handed over by @supabase/ssr on the first cookie write
   * (Cache-Control: private, no-store ...). Kept aside because the response we finally
   * return may be a redirect built after that write, and a cached Set-Cookie would serve
   * one user's session token to another.
   */
  const authHeaders: Record<string, string> = {};

  const { url, anonKey } = publicSupabaseEnv();

  // Typed against the library contract rather than inferred: createServerClient is
  // overloaded (the first overload still takes the deprecated get/set/remove methods),
  // so an inline object literal is not reliably contextually typed.
  const cookieMethods: CookieMethodsServer = {
    getAll() {
      return request.cookies.getAll();
    },
    setAll(cookiesToSet, headers) {
      // 1. make the refreshed cookies visible to whatever renders this request
      cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
      // 2. rebuild the response so it carries the updated request
      response = NextResponse.next({ request });
      // 3. write the cookies to the response
      cookiesToSet.forEach(({ name, value, options }) => {
        response.cookies.set(name, value, options);
      });
      // 4. copy the cache headers returned alongside the cookies
      Object.entries(headers).forEach(([key, value]) => {
        authHeaders[key] = value;
        response.headers.set(key, value);
      });
    },
  };

  const supabase = createServerClient(url, anonKey, { cookies: cookieMethods });

  // getClaims() verifies the JWT — locally against the project's signing keys, or at the
  // Auth server when the project signs symmetrically. getSession() is never used to make
  // an authorization decision.
  const { data } = await supabase.auth.getClaims();
  const claims = data?.claims ?? null;

  const { pathname } = request.nextUrl;
  const isProtected = PROTECTED_PREFIXES.some((p) => pathname === p || pathname.startsWith(`${p}/`));

  if (!claims && isProtected) {
    return redirectWithSession(request, "/login", response, authHeaders);
  }

  if (claims && pathname === "/login") {
    return redirectWithSession(request, "/app", response, authHeaders);
  }

  return response;
}

/**
 * Builds a redirect that carries the refreshed auth cookies and their cache headers.
 * A bare NextResponse.redirect() would drop a token refresh that happened during this
 * request and log the user out on the next one.
 */
function redirectWithSession(
  request: NextRequest,
  pathname: string,
  current: NextResponse,
  authHeaders: Record<string, string>,
) {
  const redirectUrl = request.nextUrl.clone();
  redirectUrl.pathname = pathname;
  redirectUrl.search = "";

  const redirectResponse = NextResponse.redirect(redirectUrl);
  current.cookies.getAll().forEach((cookie) => redirectResponse.cookies.set(cookie));
  Object.entries(authHeaders).forEach(([key, value]) => redirectResponse.headers.set(key, value));

  return redirectResponse;
}
