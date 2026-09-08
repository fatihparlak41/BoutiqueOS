import { cookies } from "next/headers";
import { createServerClient, type CookieMethodsServer } from "@supabase/ssr";
import { publicSupabaseEnv } from "@/lib/env";

/**
 * Server client for Server Components, Route Handlers and Server Actions.
 * Reads and writes the auth cookies so sessions persist and refresh across requests.
 */
export async function createClient() {
  const cookieStore = await cookies();
  const { url, anonKey } = publicSupabaseEnv();

  // Typed against the library contract rather than inferred: createServerClient is
  // overloaded (the first overload still takes the deprecated get/set/remove methods),
  // so an inline object literal is not reliably contextually typed.
  const cookieMethods: CookieMethodsServer = {
    getAll() {
      return cookieStore.getAll();
    },
    /**
     * setAll also receives the no-store cache headers that must accompany a cookie
     * write. They are not taken here: a Server Component has no response to set headers
     * on. The middleware runs on every matched request and applies them there.
     */
    setAll(cookiesToSet) {
      try {
        cookiesToSet.forEach(({ name, value, options }) => {
          cookieStore.set(name, value, options);
        });
      } catch {
        // Server Components cannot set cookies. Middleware refreshes the session on
        // every request, so ignoring this here is safe.
      }
    },
  };

  return createServerClient(url, anonKey, { cookies: cookieMethods });
}
