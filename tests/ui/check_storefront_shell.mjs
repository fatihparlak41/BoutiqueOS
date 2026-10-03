// Phase 14C Pass 1 — static guards for the public storefront shell (plain Node, no framework).
//   1. no storefront file links into the operational app or shows the BoutiqueOS wordmark
//   2. header: categories never render inline in the bar; mobile menu, search, cart present
//   3. search goes to the public listing (?q=) only; no internal identifiers anywhere public
//   4. footer shows only configured store fields; no invented legal / shipping / returns pages
//   5. storefront-native 404s exist for a store page, an unknown path and an unknown store
//   6. Pass 1 changed no SQL and no 14A/14B read/write path
import { readFileSync, readdirSync, existsSync } from "node:fs";
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
  for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
    const rel = join(dir, entry.name);
    if (entry.isDirectory()) walk(rel, out);
    else if (/\.(tsx?|css)$/.test(entry.name)) out.push(rel);
  }
  return out;
}
const shopFiles = [...walk("app/shop"), ...walk("components/shop")];
const shopCode = shopFiles.map((f) => [f, stripComments(read(f))]);

// 1. no admin leakage
const appLinks = shopCode.filter(([, s]) => /href=\{?["'`]\/(app|login|platform|kayit)(["'`/?]|\b)/.test(s)).map(([f]) => f);
check("no storefront file links to /app, /login, /platform or /kayit", appLinks.length === 0, appLinks.join(", "));
const wordmark = shopCode.filter(([, s]) => /Wordmark|BoutiqueOS|Uygulamaya dön/.test(s)).map(([f]) => f);
check("no BoutiqueOS wordmark / 'Uygulamaya dön' in storefront files", wordmark.length === 0, wordmark.join(", "));
const adminUi = shopCode.filter(([, s]) => /@\/components\/(ui|app|brand)\//.test(s)).map(([f]) => f);
check("storefront does not import admin UI components", adminUi.length === 0, adminUi.join(", "));

// 2. header
const header = stripComments(read("components/shop/header.tsx"));
const navBlock = header.slice(header.indexOf('<nav className="shop-nav"'), header.indexOf("</nav>", header.indexOf('<nav className="shop-nav"')));
check("header: categories only inside the compact panel, never inline in the bar",
  /shop-cats-panel[\s\S]*store\.categories\.map/.test(navBlock) && (navBlock.match(/store\.categories\.map/g) ?? []).length === 1);
check("header: fixed short navigation (Yeni Gelenler, Tüm Ürünler, Kategoriler)", /Yeni Gelenler/.test(navBlock) && /Tüm Ürünler/.test(navBlock) && /Kategoriler/.test(navBlock));
check("header: mobile menu button, search button, cart button", /shop-menu-button/.test(header) && /shop-search-button/.test(header) && /<CartButton/.test(header));
check("header: no glass / blur", !/backdrop-filter/.test(read("app/shop/shop.css")));
const drawer = stripComments(read("components/shop/menu-drawer.tsx"));
check("menu drawer: dialog, Escape/focus handled by useOverlay, 48px links", /role="dialog"/.test(drawer) && /useOverlay\(/.test(drawer) && /\.shop-drawer-link \{[^}]*min-height: 48px/.test(read("app/shop/shop.css")));
check("menu drawer: contact links only when configured", /store\.instagram \?/.test(drawer) && /store\.whatsapp \?/.test(drawer));
check("touch targets: header icons are 44px", /\.shop-icon \{[^}]*min-width: 44px; height: 44px/.test(read("app/shop/shop.css")));

// 3. search
const search = stripComments(read("components/shop/search-sheet.tsx"));
check("search: submits to the public listing with ?q= only", /action=\{`\$\{base\}\/urunler`\}/.test(search) && /urunler\?\$\{new URLSearchParams\(\{ q: term \}\)\}/.test(search));
check("search: no direct RPC / table call in the sheet", !/\.rpc\(|\.from\(/.test(search));
const internals = shopCode.filter(([f, s]) => !f.endsWith(".css") && /\b(sku|barcode|cost|supplier|unit_cost)\b/i.test(s)).map(([f]) => f);
check("no SKU / barcode / cost / supplier identifiers in storefront code", internals.length === 0, internals.join(", "));
const sql = read("supabase/migrations/20260919140000_phase14a_storefront.sql");
const productsRpc = sql.slice(sql.indexOf("CREATE OR REPLACE FUNCTION rpc_shop_products"), sql.indexOf("GRANT  EXECUTE ON FUNCTION rpc_shop_products"));
check("public search matches only the product name / web title", /COALESCE\(p\.web_title, p\.name\) ILIKE/.test(productsRpc) && !/sku|barcode/i.test(productsRpc));

// 4. footer
const footer = stripComments(read("components/shop/footer.tsx"));
check("footer: only configured store fields", /store\.instagram \?/.test(footer) && /store\.contact_email \?/.test(footer) && /store\.pickup_branch \?/.test(footer));
check("footer: no invented legal / shipping / returns pages", !/(gizlilik|kvkk|iade|kargo|teslimat-kosul|mesafeli|kullanim-kosul)/i.test(footer));

// 5. 404s
check("store page 404 exists with 'Bu sayfa bulunamadı.' + Mağazaya dön + Ürünleri keşfet",
  existsSync(join(root, "app/shop/[slug]/not-found.tsx")) && /Bu sayfa bulunamadı\./.test(read("app/shop/[slug]/not-found.tsx")) && /Mağazaya dön/.test(read("app/shop/[slug]/not-found.tsx")) && /Ürünleri keşfet/.test(read("app/shop/[slug]/not-found.tsx")));
check("unknown store 404 exists, neutral, noindex", existsSync(join(root, "app/shop/not-found.tsx")) && /Bu sayfa bulunamadı\./.test(read("app/shop/not-found.tsx")) && /index: false/.test(read("app/shop/not-found.tsx")));
check("unknown path inside a store resolves to the store 404 (catch-all)", existsSync(join(root, "app/shop/[slug]/[...rest]/page.tsx")) && /notFound\(\)/.test(read("app/shop/[slug]/[...rest]/page.tsx")));
check("every /shop route carries the storefront stylesheet", /import "@\/app\/shop\/shop\.css"/.test(read("app/shop/layout.tsx")));
check("a link styled as a button keeps its ink (cart CTA was black on black)", /\.shop a\.shop-btn \{ color: #fff; \}/.test(read("app/shop/shop.css")));

// 6. scope
check("Pass 1 adds no migration (latest is the product status patch)", readdirSync(join(root, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort().at(-1) === "20261003100000_product_status_audit.sql");
const queries = read("lib/shop/queries.ts");
check("14A/14B read path unchanged: same rpc_shop_* set in queries", ["rpc_shop_resolve", "rpc_shop_home", "rpc_shop_products", "rpc_shop_product", "rpc_shop_availability", "rpc_shop_order"].every((r) => queries.includes(`"${r}"`)));
check("14B write path unchanged: checkout still calls rpc_shop_create_order with store_pickup", /rpc_shop_create_order[\s\S]*p_fulfillment: "store_pickup"/.test(read("components/shop/checkout-view.tsx")));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
