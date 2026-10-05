// Public anon surface — static guard over the migrations (plain Node). The database side is
// proven by T79 in 005_verification_tests.sql; this catches a future migration that would
// quietly hand anon a table, view or sequence again, or expose a non-public function.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const dir = join(root, "supabase/migrations");
const strip = (s) => s.replace(/--.*$/gm, "");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`[PASS] ${name}`); }
  else { fail++; console.log(`[FAIL] ${name}${detail ? " - " + detail : ""}`); }
}

const HARDENING = "20261003150000_public_anon_privilege_hardening.sql";
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const hard = strip(readFileSync(join(dir, HARDENING), "utf8"));

check("hardening migration revokes anon table / view access by explicit names", /REVOKE ALL ON TABLE[\s\S]*public\.business_members[\s\S]*public\.saas_plans[\s\S]*public\.v_fx_rates_current[\s\S]*FROM anon;/.test(hard) && !/ALL TABLES IN SCHEMA/i.test(hard));
check("hardening migration revokes the identity sequence from anon and authenticated", /REVOKE ALL ON SEQUENCE public\.product_status_events_seq_seq FROM anon, authenticated;/.test(hard));
check("hardening migration revokes the two storage helpers from anon only", /REVOKE EXECUTE ON FUNCTION public\.fn_storage_business_id\(TEXT\), public\.fn_store_business_id\(TEXT\) FROM anon;/.test(hard));
check("hardening migration closes postgres default privileges for anon (tables, sequences, functions)",
  /ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon;/.test(hard)
  && /ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;/.test(hard)
  && /ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;/.test(hard));
check("hardening migration does not touch authenticated table grants", !/ON TABLE[\s\S]{0,4000}FROM anon, authenticated/.test(hard.split("REVOKE ALL ON SEQUENCE")[0]));

// the explicit anon application RPC allowlist: 10 after the hardening + rpc_shop_sitemap (Phase 14C Pass 6)
const PUBLIC_RPC_NAMES = ["rpc_shop_resolve", "rpc_shop_home", "rpc_shop_products", "rpc_shop_product", "rpc_shop_availability", "rpc_shop_resolve_host",
  "rpc_shop_create_order", "rpc_shop_order", "rpc_shop_cancel_order", "rpc_saas_plans", "rpc_shop_sitemap"];
const PUBLIC_RPC = { test: (n) => PUBLIC_RPC_NAMES.includes(n) };
const later = files.filter((f) => f >= HARDENING);
const offenders = [];
for (const f of later) {
  const s = strip(readFileSync(join(dir, f), "utf8"));
  for (const m of s.matchAll(/GRANT\s+([^;]+?)\s+TO\s+([^;]+);/gi)) {
    if (!/\banon\b/i.test(m[2])) continue;
    const what = m[1];
    if (!/^EXECUTE ON FUNCTION/i.test(what.trim())) { offenders.push(`${f}: ${what.slice(0, 80)}`); continue; }
    const names = [...what.matchAll(/(?:public\.)?([a-z_0-9]+)\s*\(/gi)].map((x) => x[1]);
    for (const n of names) if (!PUBLIC_RPC.test(n)) offenders.push(`${f}: EXECUTE ${n}`);
  }
  if (/ALTER DEFAULT PRIVILEGES[^;]*GRANT[^;]*\banon\b/i.test(s)) offenders.push(`${f}: default privileges re-grant anon`);
}
check(`from the hardening migration on, anon only ever receives EXECUTE on the ${PUBLIC_RPC_NAMES.length} allowlisted public RPCs`, offenders.length === 0, offenders.join(" | "));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
