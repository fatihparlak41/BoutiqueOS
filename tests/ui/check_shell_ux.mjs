// UX sprint pass 2 — static guards over the dashboard, the navigation shell and the
// archived-stock read semantics (plain Node, no framework).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");
let pass = 0, fail = 0;
const check = (name, cond, detail = "") => { if (cond) { pass++; console.log(`[PASS] ${name}`); } else { fail++; console.log(`[FAIL] ${name}${detail ? " - " + detail : ""}`); } };

// ---- dashboard
const home = read("app/app/page.tsx");
const blocks = read("components/dashboard/home.tsx");
const dq = read("lib/dashboard/queries.ts");
check("dashboard: one plum primary 'Satış yap', only for sellers", /d\.caps\.canSell \?[\s\S]{0,200}variant="accent"[\s\S]{0,120}Satış yap/.test(home) && (home.match(/variant="accent"/g) ?? []).length === 1);
check("dashboard: no stale module copy", !/henüz açılmadı|Kasa, satış, müşteriler|elle stok girişi yoktur/.test(home + blocks));
check("dashboard: quick actions are role-gated (catalog / count / crm / orders)", /caps\.canEditCatalog \?/.test(blocks) && /caps\.canCount \?/.test(blocks) && /caps\.canAccessCrm \?/.test(blocks) && /caps\.canViewOrders \?/.test(blocks));
check("dashboard: today's number only through the report RPC and only for sales roles", /caps\.canViewSales \? getOverview/.test(dq) && !/from\("sale_items"\)|sale_item_costs|variant_cost_pools/.test(dq));
check("dashboard: no KPI card grid", !/StatGrid/.test(home + blocks));
check("dashboard: open register warning after a long day, 'Kasaya git', never auto-closes", /LONG_OPEN_HOURS = 16/.test(dq) && dq.includes('title: "Kasa oturumu uzun süredir açık"') && dq.includes('action: "Kasaya git"') && !/rpc_close_register_session/.test(dq));
check("dashboard: timezone item is manager+ only and points to settings", /caps\.managerPlus && !timezone[\s\S]{0,200}Saat dilimi ayarlanmamış[\s\S]{0,160}\/app\/ayarlar\/raporlama/.test(dq));
check("dashboard: starter card derives from real data and disappears when done", /productCount > 0 && stockDone && saleCount > 0 \? null/.test(dq));
check("dashboard: bounded reads (limit/head count), no per-row loop", (dq.match(/\.limit\(\d\)/g) ?? []).length >= 4 && /head: true/.test(dq) && !/for \(const .* of .*\) \{\s*await/.test(dq));

// ---- navigation
const nav = read("components/shell/nav-items.ts");
const item = (href) => { const m = nav.match(new RegExp(`href: "${href.replace(/\//g, "\\/")}", roles: (\\w+)`)); return m ? m[1] : null; };
check("nav: five groups Genel / Satış / Ürünler / Raporlar / Yönetim", ["Genel", "Satış", "Ürünler", "Raporlar", "Yönetim"].every((g) => nav.includes(`label: "${g}"`)));
check("nav: Kasa, Rezervasyonlar, Online siparişler, Müşteriler, İade are selling-only", ["/app/pos", "/app/rezervasyonlar", "/app/online-siparisler", "/app/musteriler", "/app/pos/iade"].every((h) => item(h) === "SELLING"));
check("nav: Mal kabul, Satın alma, Tedarikçiler are procurement-only", ["/app/mal-kabul", "/app/satin-alma", "/app/tedarikciler"].every((h) => item(h) === "PROCUREMENT"));
check("nav: Online mağaza, Ekip manager+; Abonelik owner", item("/app/online-magaza") === "MANAGER" && item("/app/ayarlar/ekip") === "MANAGER" && item("/app/ayarlar/abonelik") === "OWNER");
const hrefs = [...nav.matchAll(/href: "([^"]+)"/g)].map((m) => m[1]);
check("nav: no duplicate route", new Set(hrefs).size === hrefs.length);
check("nav: platform console is not part of tenant navigation", !nav.includes("/platform"));
check("nav: role filter applied in the rail and the sheet", /navGroupsFor\(role\)/.test(read("components/shell/primary-nav.tsx")) && /role=\{active\.role\}/.test(read("app/app/layout.tsx")));
const bottom = read("components/shell/bottom-nav.tsx");
check("bottom nav: role-aware, max 4 doors + Menü, safe-area padding", /bottomNavFor\(role\)/.test(bottom) && /\.slice\(0, 4\)/.test(nav) && /env\(safe-area-inset-bottom\)/.test(bottom));
check("bottom nav: steps aside on POS / counting / intake / reservation form", ["\\/app\\/pos$", "stok\\/sayim", "katalog-ekle", "rezervasyonlar\\/yeni"].every((r) => bottom.includes(r)));
const mobile = read("components/shell/mobile-nav.tsx");
check("mobile menu: plate on top, 44px rows, account at the foot, closes on navigation, top trigger only where the bar hides", /plate/.test(mobile) && /dense/.test(mobile) && /onNavigate=\{\(\) => setOpen\(false\)\}/.test(mobile) && /topTrigger \?/.test(mobile));
const layout = read("app/app/layout.tsx");
check("shell: business name visible on desktop rail and mobile top bar", /BusinessPlate/.test(layout) && /active\.business_name/.test(layout));
check("shell: badges are one bounded read for order-handling roles only", /orderCaps\(role\)\.canView/.test(read("lib/shell/badges.ts")) && /listOnlineOrders\("new", null, 0, 1\)/.test(read("lib/shell/badges.ts")));

// ---- archived stock semantics
const sq = read("lib/stock/queries.ts");
check("stock list: archived rows stay while stock remains, hidden only at zero", /filters\.includeArchived \|\| row\.product_status !== "archived" \|\| row\.on_hand > 0/.test(sq));
check("stock summary: 'tükenen' counts active products only", /products!inner\(status\)[\s\S]{0,80}\.eq\("products\.status", "active"\)/.test(sq));
check("product page: valuation from the cost pool for manager+, archived notice", /productInventoryValue\(product\.id, branchId\)/.test(read("app/app/urunler/[id]/page.tsx")) && /archived-notice/.test(read("app/app/urunler/[id]/page.tsx")));
check("product page: valuation query returns null for non-managers (no leak)", /if \(!\(role === "owner" \|\| role === "manager"\) \|\| !branchId\) return null;/.test(sq));
check("stock rows: 'Arşivde' badge", /Arşivde/.test(read("components/stock/stock-rows.tsx")));
const sql = read("tests/005_verification_tests.sql");
check("SQL regression T63l: archive keeps ledger/pool/availability, POS refuses, restore sells", /T63l archived: status archived, variant still active, ledger untouched/.test(sql) && /VARIANT_NOT_SELLABLE/.test(sql) && /T63l restored product sells again/.test(sql));
check("no SQL migration was needed for the archived-stock fix", !/fn_intel_facts/.test(read("supabase/migrations/20260919210000_phase15b0_count_cost_bridge.sql")));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
