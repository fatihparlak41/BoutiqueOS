// Phase 6B synthetic checks through the public API as the safe E2E alias user (owner of the
// disposable tenant). Nothing here touches TLC: every write targets the ZZ tenant and the
// cross-tenant probes are expected to be refused. Temporary file, deleted after the run.
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const env = Object.fromEntries(readFileSync(".env.local", "utf8").split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => { const i = l.indexOf("="); return [l.slice(0, i), l.slice(i + 1).trim().replace(/^"|"$/g, "")]; }));
const url = env.NEXT_PUBLIC_SUPABASE_URL;
const admin = createClient(url, env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const ALIAS = "64cfef13-8e7b-4fe8-afdb-9c671ad7e3fd";
const ZZ = "7c14afe4-233b-4923-9df5-c2d09ed7ad91";
const TLC = "b0000000-0000-4000-8000-000000000001";

const { data: u } = await admin.auth.admin.getUserById(ALIAS);
const { data: link } = await admin.auth.admin.generateLink({ type: "magiclink", email: u.user.email });
const db = createClient(url, env.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const { error: vErr } = await db.auth.verifyOtp({ token_hash: link.properties.hashed_token, type: "magiclink" });
if (vErr) { console.error("alias session failed:", vErr.message); process.exit(1); }

const results = [];
const check = (name, ok, detail = "") => { results.push([ok ? "PASS" : "FAIL", name, detail]); };

const { data: prods } = await db.from("products").select("id, name, sku_prefix").eq("business_id", ZZ);
const byName = Object.fromEntries((prods ?? []).map((p) => [p.name, p]));
const belt = byName["ZZ Test Belt"], satin = byName["ZZ Test Satin Dress"], bikini = byName["ZZ Test Bikini"];
check("alias sees the six synthetic products only", (prods ?? []).length === 6 && (prods ?? []).every((p) => p.name.startsWith("ZZ Test")), String(prods?.length));

// B) Product E's primary barcode attached to Product F through the RPC → refused, nothing written
const { data: beltVarsBefore } = await db.from("product_variants").select("id").eq("product_id", belt.id);
const { error: dupErr } = await db.rpc("rpc_onboard_variants", { p_product_id: belt.id, p_combos: [{ sku: "ZZ-TEST-BELT-DUP", option_value_ids: [], barcodes: ["2009000000123"] }] });
const { data: beltVarsAfter } = await db.from("product_variants").select("id").eq("product_id", belt.id);
check("B) duplicate barcode on Product F refused by the database", !!dupErr && dupErr.code === "23505", dupErr?.code ?? "no error");
check("B) refused call left no new variant behind", beltVarsBefore.length === beltVarsAfter.length, `${beltVarsBefore.length}→${beltVarsAfter.length}`);

// E) both barcodes resolve to the same variant
const r1 = await db.rpc("rpc_resolve_barcode", { p_business_id: ZZ, p_code: "2009000000123" });
const r2 = await db.rpc("rpc_resolve_barcode", { p_business_id: ZZ, p_code: "ZZ-BKN-SUPPLIER-77" });
const v1 = r1.data?.[0]?.variant_id, v2 = r2.data?.[0]?.variant_id;
check("E) primary and supplier barcodes resolve to the same variant", !!v1 && v1 === v2 && r1.data[0].product_id === bikini.id, `${v1?.slice(0, 8)} / ${v2?.slice(0, 8)}`);
const { data: bcs } = await db.from("barcodes").select("barcode, is_primary, barcode_type, symbology").eq("variant_id", v1).order("is_primary", { ascending: false });
check("E) exactly one primary + one alternate on the variant", bcs?.length === 2 && bcs[0].is_primary && !bcs[1].is_primary, JSON.stringify(bcs));

// 6) idempotency: rerun Product A's full matrix (incl. Zeytin) through the RPC → 0 created
const { data: opts } = await db.from("option_values").select("id, value, product_option_id").eq("business_id", ZZ);
const val = (v) => opts.find((o) => o.value === v)?.id;
const colours = ["Siyah", "Bordo", "Zeytin"].map(val), sizes = ["S", "M", "L"].map(val);
if (colours.every(Boolean)) {
  const combos = colours.flatMap((c) => sizes.map((s) => ({ sku: `ZZ-SAT-001-RERUN-${c.slice(0, 4)}-${s.slice(0, 4)}`, option_value_ids: [c, s], barcodes: [] })));
  const { data: rerun, error: rerunErr } = await db.rpc("rpc_onboard_variants", { p_product_id: satin.id, p_combos: combos });
  const created = (rerun ?? []).filter((r) => r.created).length;
  const { data: satinVars } = await db.from("product_variants").select("sku, status").eq("product_id", satin.id);
  check("6) rerun of the full matrix creates 0 duplicates (only Bordo/L is new because it was disabled at intake)", !rerunErr && created === 1 && (rerun ?? []).length === 9, `created=${created} err=${rerunErr?.message ?? ""}`);
  // undo the one the rerun legitimately created so the fixture stays as designed
  const extra = (rerun ?? []).find((r) => r.created);
  if (extra) await db.from("product_variants").update({ status: "archived" }).eq("id", extra.variant_id);
  const { data: rerun2 } = await db.rpc("rpc_onboard_variants", { p_product_id: satin.id, p_combos: combos.filter((c) => !(c.option_value_ids[0] === val("Bordo") && c.option_value_ids[1] === val("L"))) });
  check("6) second rerun creates nothing", (rerun2 ?? []).every((r) => !r.created), `${(rerun2 ?? []).length} rows`);
  check("6) Satin active variants = 8 (5 original + 3 Zeytin)", satinVars.filter((v) => v.status === "active").length === 8 + (extra ? 1 : 0), String(satinVars.filter((v) => v.status === "active").length));
} else {
  check("6) Zeytin exists (UI variant-add ran first)", false, "Zeytin value missing");
}

// 7) cross-tenant image isolation: sign / upload / list under TLC's prefix must be refused
const tlcPath = `business/${TLC}/products/${crypto.randomUUID()}/x.png`;
const up = await db.storage.from("product-images").upload(tlcPath, new Uint8Array([137, 80, 78, 71]), { contentType: "image/png" });
check("7) upload under TLC prefix refused", !!up.error, up.error?.message ?? "uploaded (BAD)");
const { data: tlcImgs } = await admin.from("product_images").select("storage_path").eq("business_id", TLC).limit(1);
const signed = await db.storage.from("product-images").createSignedUrl(tlcImgs[0].storage_path, 60);
check("7) signing TLC's image refused", !!signed.error, signed.error?.message ?? "signed (BAD)");
const list = await db.storage.from("product-images").list(`business/${TLC}/products`);
check("7) listing TLC's folder yields nothing", !list.error ? (list.data ?? []).length === 0 : true, `${(list.data ?? []).length} entries`);
const { data: tlcRows } = await db.from("product_images").select("id").eq("business_id", TLC);
check("7) TLC image rows invisible", (tlcRows ?? []).length === 0, String(tlcRows?.length));
const { data: tlcProducts } = await db.from("products").select("id").eq("business_id", TLC);
check("TLC products invisible to the ZZ owner", (tlcProducts ?? []).length === 0, String(tlcProducts?.length));
const attach = await db.from("product_images").insert({ product_id: belt.id, role: "product_gallery", storage_path: tlcImgs[0].storage_path });
check("7) attaching TLC's object path to a ZZ product refused", !!attach.error, attach.error?.message ?? "inserted (BAD)");

// zero stock through the API view as well
const { data: pools } = await db.from("variant_cost_pools").select("id").eq("business_id", ZZ);
const { data: moves } = await db.from("inventory_movements").select("id").eq("business_id", ZZ);
check("9) no cost pools / movements for the synthetic tenant", (pools ?? []).length === 0 && (moves ?? []).length === 0, `${pools?.length}/${moves?.length}`);

for (const [s, n, d] of results) console.log(`${s}  ${n}${d ? "  — " + d : ""}`);
console.log(`\n${results.filter((r) => r[0] === "PASS").length}/${results.length} PASS`);
