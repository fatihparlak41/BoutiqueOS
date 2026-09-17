/**
 * Diagnostic trace of server-side Supabase traffic. Off unless BOUTIQUEOS_TRACE_SUPABASE=1
 * (never set on Vercel): every fetch to the project's REST / Auth / Storage endpoints is
 * logged as one JSON line — timestamp, duration, method, path and query — so a navigation
 * can be audited for call count, sequencing and N+1 patterns. No headers, no bodies, no
 * tokens are logged.
 */
export async function register() {
  if (process.env.BOUTIQUEOS_TRACE_SUPABASE !== "1" || process.env.NEXT_RUNTIME !== "nodejs") return;
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base) return;
  const original = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (!url.startsWith(base)) return original(input, init);
    const started = Date.now();
    try {
      return await original(input, init);
    } finally {
      const u = new URL(url);
      process.stderr.write(`SBTRACE ${JSON.stringify({ t: started, ms: Date.now() - started, m: (init?.method ?? "GET").toUpperCase(), p: u.pathname, q: u.search.slice(0, 300) })}\n`);
    }
  };
}
