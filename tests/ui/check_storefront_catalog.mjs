// Phase 14C Pass 2 — static guards for the public catalogue (plain Node, no framework).
//   1. the filter RPC: one new migration, STABLE, server-side matching, bounded, anon-only grant
//   2. URL state: public value names (no UUIDs), shareable params, clean canonical, noindex when parameterised
//   3. cards: photography first, no internal fields, hover only with a real second image, swatches capped
//   4. filters: sheet (not a sidebar), 44px+ controls, Kategori / Beden / Renk / Stok, Temizle + apply
//   5. search / empty states / load more: the agreed wording, bounded steps
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`[PASS] ${name}`); }
  else { fail++; console.log(`[FAIL] ${name}${detail ? " - " + detail : ""}`); }
}

// 1. migration / RPC
const migs = readdirSync(join(root, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort();
check("exactly one Pass 2 migration after the product status patch", migs.slice(migs.indexOf("20261003100000_product_status_audit.sql") + 1).join() === "20261003140000_phase14c_shop_filters.sql", migs.slice(-2).join());
const mig = read("supabase/migrations/20261003140000_phase14c_shop_filters.sql");
const rpc = mig.slice(mig.indexOf("CREATE OR REPLACE FUNCTION rpc_shop_products"));
check("rpc_shop_products: colour / size / in-stock parameters with defaults", /p_color TEXT\[\] DEFAULT NULL, p_size TEXT\[\] DEFAULT NULL, p_in_stock BOOLEAN DEFAULT false/.test(rpc));
check("rpc_shop_products is STABLE and writes nothing (no temp table, no DML)", /LANGUAGE plpgsql STABLE SECURITY DEFINER/.test(rpc) && !/CREATE TEMP|INSERT INTO|UPDATE |DELETE FROM/.test(strip(rpc.slice(0, rpc.indexOf("END $$")))));
check("page size bounded at 96", /LEAST\(GREATEST\(COALESCE\(p_limit, 24\), 1\), 96\)/.test(rpc));
check("matching is per variant over active web variants only", /pv\.status = 'active' AND pv\.web_enabled[\s\S]*ov\.value = ANY \(p_colors\)[\s\S]*ov\.value = ANY \(p_sizes\)[\s\S]*fn_shop_available/.test(mig));
check("scope stays: published + active + tenant + name/web-title search", /p\.business_id = s\.business_id AND p\.web_published AND p\.status = 'active'/.test(rpc) && /COALESCE\(p\.web_title, p\.name\) ILIKE/.test(rpc) && !/sku|barcode/i.test(strip(rpc)));
check("grants: anon + authenticated execute the 9-arg RPC; helpers private",
  /GRANT  EXECUTE ON FUNCTION rpc_shop_products\(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT\[\], TEXT\[\], BOOLEAN\) TO anon, authenticated/.test(mig)
  && /REVOKE EXECUTE ON FUNCTION fn_shop_product_matches\([^)]*\) FROM PUBLIC, anon, authenticated/.test(mig)
  && /REVOKE EXECUTE ON FUNCTION fn_shop_filter_values\(TEXT\[\]\) FROM PUBLIC, anon, authenticated/.test(mig));
check("no enum / hard-coded size or colour vocabulary", !/CREATE TYPE|'XS'|'Siyah'|'Black'/.test(mig));
const q = read("lib/shop/queries.ts");
check("app passes the filters to the RPC (server authoritative)", /p_color: filters\.colors\.length \? filters\.colors : null/.test(q) && /p_size: filters\.sizes\.length \? filters\.sizes : null/.test(q) && /p_in_stock: filters\.inStock/.test(q));

// 2. URL state
const url = strip(read("lib/shop/listing-url.ts"));
check("URL params: q, renk (repeated), beden (repeated), stok=1, sirala, sayfa, baslangic", /p\.append\("renk", c\)/.test(url) && /p\.append\("beden", s\)/.test(url) && /p\.set\("stok", "1"\)/.test(url) && /p\.set\("sirala"/.test(url) && /p\.set\("q"/.test(url) && /p\.set\("sayfa"/.test(url) && /p\.set\("baslangic"/.test(url));
check("URL carries public value names, never ids", !/\.id\b|uuid/i.test(url));
check("category is the path, so the clean category route stays canonical", /kategori\/\$\{category\}/.test(url));
check("load more is bounded: at most 4 steps of 24 in a 96-card window", /Math\.min\(4,/.test(url) && /start % 96/.test(url) && /MAX_LOAD_STEPS = 4/.test(read("lib/shop/model.ts")));
const listing = strip(read("components/shop/listing.tsx"));
check("parameterised listing pages are noindex,follow; canonical always clean", /isParameterised\(searchParams\) \? \{ robots: \{ index: false, follow: true \} \}/.test(listing) && /canonical: cat \? `\/shop\/\$\{slug\}\/kategori\/\$\{cat\.slug\}` : `\/shop\/\$\{slug\}\/urunler`/.test(listing));

// 3. cards
const card = strip(read("components/shop/product-card.tsx"));
check("card: image is the link body; name, price, swatches; no internal fields", /<Link href=\{`\/shop\/\$\{slug\}\/urun\/\$\{card\.slug\}`\}/.test(card) && !/sku|barcode|available|cost/i.test(card));
check("card: hover image only when a second public image exists", /\{img && hover \? <Image/.test(card));
check("card: hover never needed on touch devices", /@media \(hover: none\) \{ \.shop-card-img-hover \{ display: none; \} \}/.test(read("app/shop/shop.css")));
check("card: at most 4 swatches + \"+N\", names for assistive tech, only for 2+ colours", /MAX_SWATCHES = 4/.test(card) && /\+\{more\}/.test(card) && /Renkler: /.test(card) && /card\.colors\.length > 1/.test(card));
check("card: sold out stays visible with 'Tükendi', image only softened", /Tükendi/.test(card) && /\.shop-card\[data-sold="true"\] \.shop-card-img \{ opacity: 0\.8; \}/.test(read("app/shop/shop.css")));
check("catalogue grid: 2 / 3 / 4 columns, hairline gap, no card border or shadow",
  /\.shop-catalog \{[^}]*repeat\(2, minmax\(0, 1fr\)\); column-gap: 2px/.test(read("app/shop/shop.css")) && /repeat\(3, minmax\(0, 1fr\)\)/.test(read("app/shop/shop.css")) && /min-width: 1200px\) \{ \.shop-catalog \{ grid-template-columns: repeat\(4/.test(read("app/shop/shop.css"))
  && !/\.shop-card[^{]*\{[^}]*(box-shadow: 0|border: 1px)/.test(read("app/shop/shop.css")));

// 4. filters
const ctl = strip(read("components/shop/listing-controls.tsx"));
check("filters live in a dialog sheet, not a permanent sidebar", /role="dialog"/.test(ctl) && !/<aside/.test(ctl + listing));
check("filter sections: Kategori, Beden, Renk, Stok", /Kategori<\/legend>[\s\S]*Beden<\/legend>[\s\S]*Renk<\/legend>[\s\S]*Stok<\/legend>/.test(ctl));
check("actions: Temizle + Sonuçları göster", /Temizle/.test(ctl) && /Sonuçları göster/.test(ctl));
check("no price slider", !/type="range"|fiyat aral/i.test(ctl));
const css = read("app/shop/shop.css");
check("touch targets: filter options / sizes / colours / switch / toolbar are 44px+", /\.shop-filter-option \{[^}]*min-height: 48px/.test(css) && /\.shop-filter-size \{[^}]*height: 48px/.test(css) && /\.shop-filter-color \{[^}]*min-height: 48px/.test(css) && /\.shop-filter-switch \{[^}]*min-height: 48px/.test(css) && /\.shop-toolbar-btn \{[^}]*height: 48px/.test(css));
check("filters + sort end in a URL (router.push / Link), no client-side filtering of rows", /router\.push\(listingHref/.test(ctl) && /href=\{listingHref/.test(ctl) && !/\.filter\(\(c\) => c\.(colors|sizes)/.test(ctl));

// 5. wording
check("search title: “q” için sonuçlar", /`“\$\{filters\.q\}” için sonuçlar`/.test(listing));
check("no result: 'Aradığın ürünü bulamadık.' + 'Tüm ürünleri keşfet'", /Aradığın ürünü bulamadık\./.test(listing) && /Tüm ürünleri keşfet/.test(listing));
check("no admin EmptyState / chips in the catalogue", !/@\/components\/ui\//.test(listing + ctl + card) && !/shop-chip/.test(listing));
check("load more: 'Daha fazla göster' jumps to the first new card", /Daha fazla göster/.test(listing) && /`urun-\$\{shownTo \+ 1\}`/.test(listing));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
