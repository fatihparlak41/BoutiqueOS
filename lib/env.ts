/**
 * Public Supabase credentials. Anon key only — the service-role key must never be
 * imported by the frontend. Values come from the environment, never hardcoded.
 */
export function publicSupabaseEnv() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !anonKey) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY. Copy .env.local.example to .env.local and fill both values.",
    );
  }
  return { url, anonKey };
}
