// TLC pilot integrity patch — static guards for audited product status (plain Node, no framework).
//   1. no app code writes products.status through the table; both write paths call rpc_product_set_status
//   2. archive / restore keep the confirmation dialog with the agreed wording
//   3. the edit form never offers "Taslak" to a product that already left draft
//   4. the migration keeps its three pillars: guard trigger, append-only events, owner/manager RPC
import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");
const stripComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`[PASS] ${name}`); }
  else { fail++; console.log(`[FAIL] ${name}${detail ? " - " + detail : ""}`); }
}

function walk(dir, out = []) {
  for (const entry of readdirSync(join(root, dir))) {
    const rel = join(dir, entry);
    if (statSync(join(root, rel)).isDirectory()) walk(rel, out);
    else if (/\.(ts|tsx)$/.test(entry)) out.push(rel);
  }
  return out;
}

// 1. write paths
const sources = [...walk("app"), ...walk("components"), ...walk("lib")];
const directStatusWrites = sources.filter((f) => {
  const code = stripComments(read(f));
  return /from\("products"\)\s*\.update\(\{[^}]*\bstatus\b/.test(code);
});
check("no table UPDATE of products.status anywhere in app/components/lib", directStatusWrites.length === 0, directStatusWrites.join(", "));

const actions = stripComments(read("app/app/urunler/actions.ts"));
const statusAction = actions.slice(actions.indexOf("export async function setProductStatusAction"));
check("archive / restore action calls rpc_product_set_status", /supabase\.rpc\("rpc_product_set_status"/.test(statusAction.slice(0, 1200)));
check("the old table-writing archiveProductAction is gone", !/archiveProductAction/.test(actions));
const updateAction = actions.slice(actions.indexOf("export async function updateProductAction"), actions.indexOf("// ---", actions.indexOf("export async function updateProductAction")));
check("edit form: status goes through the RPC before the field update", /rpc\("rpc_product_set_status"[\s\S]*from\("products"\)\s*\.update/.test(updateAction));

// 2. dialogs
for (const file of ["components/catalog/product-list.tsx", "components/catalog/product-hero.tsx"]) {
  const src = read(file);
  check(`${file}: archive asks "Bu ürünü arşivlemek istiyor musun?"`, src.includes("Bu ürünü arşivlemek istiyor musun?"));
  check(`${file}: restore confirms with "Ürünü satışa aç"`, src.includes('"Ürünü satışa aç" : "Arşivle"'));
  check(`${file}: through ConfirmDialog and setProductStatusAction`, src.includes("<ConfirmDialog") && src.includes("setProductStatusAction("));
}

// 3. edit form
const form = read("components/catalog/product-form.tsx");
check("edit form offers draft only to new or draft products", form.includes('value !== "draft" || !product || product.status === "draft"'));

// 4. migration
const mig = read("supabase/migrations/20261003100000_product_status_audit.sql");
check("migration: guard trigger on products.status", /CREATE TRIGGER trg_products_status_guard BEFORE UPDATE OF status ON products/.test(mig));
check("migration: events are append-only (no client writes, frozen trigger)", /REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON product_status_events FROM anon, authenticated/.test(mig) && /trg_product_status_events_frozen BEFORE UPDATE OR DELETE/.test(mig));
check("migration: RPC is owner/manager and authenticated-only", /fn_require_role\(v_biz, ARRAY\['owner','manager'\]/.test(mig) && /GRANT\s+EXECUTE ON FUNCTION rpc_product_set_status\(UUID, product_status, TEXT\) TO authenticated/.test(mig));
check("migration: no back-filled events", !/INSERT INTO product_status_events[\s\S]*SELECT/.test(mig));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
