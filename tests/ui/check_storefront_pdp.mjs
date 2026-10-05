// Phase 14C Pass 3 — static guards for the public product detail (plain Node, no framework).
//   1. no SQL; reads stay rpc_shop_product + rpc_shop_availability + ONE bounded related listing
//   2. variant state from the public response + fresh availability only; cart write only (no reservation)
//   3. dynamic options; unavailable values visible but disabled with an accessible reason
//   4. customer wording; no technical stock copy, no invented content
//   5. gallery: native scroll-snap, public images only; sticky CTA phone-only with safe area
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/\{\/\*[\s\S]*?\*\/\}/g, "");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`[PASS] ${name}`); }
  else { fail++; console.log(`[FAIL] ${name}${detail ? " - " + detail : ""}`); }
}

// the storefront passes are judged on the migrations that existed up to 14C-4; later security
// migrations (20261003150000 anon privilege hardening, …) are outside their scope
const migs = readdirSync(join(root, "supabase/migrations")).filter((f) => f.endsWith(".sql") && f < "20261003150000").sort();
check("Pass 3 adds no migration (latest is the 14C-2 filter migration)", migs.at(-1) === "20261003140000_phase14c_shop_filters.sql", migs.at(-1));

const page = strip(read("app/shop/[slug]/urun/[pslug]/page.tsx"));
check("page reads: store + product, then availability and ONE related listing in parallel", /Promise\.all\(\[getStore\(slug\), getProduct\(slug, pslug\)\]\)/.test(page) && /Promise\.all\(\[\s*getAvailability\(slug, product\.variants\.map/.test(page) && (page.match(/listProducts\(/g) ?? []).length === 1);
check("related: same category, bounded (RELATED + 1 rows), current product excluded, ≤ 4", /listProducts\(slug, product\.category\?\.slug \?\? null, \{ q: null, colors: \[\], sizes: \[\], inStock: false, sort: "newest" \}, 0, RELATED \+ 1\)/.test(page) && /const RELATED = 4/.test(page) && /\.filter\(\(c\) => c\.slug !== product\.slug\)\.slice\(0, RELATED\)/.test(page));
check("related reuses the Pass 2 card system and is omitted when empty", /<ProductGrid slug=\{slug\} cards=\{relatedCards\}/.test(page) && /relatedCards\.length > 0 \?/.test(page) && /Benzer Ürünler/.test(page));
check("no per-variant availability request", !/variants\.(map|forEach)\([^)]*getAvailability/.test(page));

const view = strip(read("components/shop/product-view.tsx"));
check("product view talks to no database: no Supabase client, no RPC", !/supabase|\.rpc\(|createBrowserClient|fetch\(/.test(view));
check("variant state = public response overlaid with the server's fresh availability", /fresh\[v\.id\]\?\.state \?\? v\.state/.test(view) && /fresh\[v\.id\]\?\.price \?\? v\.price/.test(view));
check("add to cart writes the browser cart only (CART ≠ RESERVATION)", /writeCart\(cart\)/.test(view) && !/reserv|hold\(/i.test(view.replace(/CART ≠ RESERVATION/g, "")));
check("options are dynamic: colour / size / any other kind, no hard-coded sizes or colours", /o\.kind === "color"/.test(view) && /o\.kind === "size"/.test(view) && /o\.name/.test(view) && !/["'](XS|XL|S|M|L|Siyah|Black)["']/.test(view));
check("unavailable values: visible, disabled, with an accessible reason", /disabled=\{blocked\}/.test(view) && /" — Tükendi"/.test(view) && /" — Bu seçimde yok"/.test(view) && /aria-pressed=\{pressed\}/.test(view));
check("swatches only when every colour has real hex data; otherwise text buttons (no invented hex)", /isColor && o\.values\.every\(\(v\) => v\.hex\)/.test(view) && /background: v\.hex \?\? undefined/.test(view) && !/#[0-9a-fA-F]{6}/.test(view));
check("colour → its own public images first, otherwise the normal gallery", /own\.size === 0\) return product\.images/.test(view) && /v\.image_id/.test(view));
check("helpers in customer words", /Lütfen renk seçin\./.test(view) && /Lütfen beden seçin\./.test(view) && !/VARIANT_REQUIRED|OUT_OF_STOCK|CART_PROBLEM/.test(view));
check("one dominant CTA 'Sepete Ekle'; sold-out product keeps the page and shows 'Tükendi'", (view.match(/>\s*\{?allSold \? "Tükendi" : "Sepete Ekle"\}?/g) ?? []).length === 1 && /disabled=\{allSold\}/.test(view));
check("confirmation: 'Sepete eklendi', 'Sepete git', 'Alışverişe devam et'; no navigation on add", /Sepete eklendi/.test(view) && /Sepete git/.test(view) && /Alışverişe devam et/.test(view) && !/router\.push|location\.href\s*=/.test(view));
check("technical stock note removed", !/stok ayırmaz|müsaitliğe göre teslim/i.test(view));
check("disclosures render only with data; nothing invented", /description \? \(/.test(view) && /store\.pickup_branch \? \(/.test(view) && /contact\.length > 0 \? \(/.test(view) && !/(iade|kargo|bakım talimat|kumaş içeriği|teslimat süresi)/i.test(view));
check("price: chosen variant price, otherwise the range of web prices", /chosen \? formatShopPrice\(chosen\.price/.test(view) && /formatPriceRange\(/.test(view));

const gal = strip(read("components/shop/product-gallery.tsx"));
check("gallery: native scroll-snap, no carousel dependency, keyboard arrows, public images only", !/from "(embla|swiper|keen|react-slick)/.test(gal) && /ArrowRight/.test(gal) && /publicImageUrl\(img\.path\)/.test(gal) && /scroll-snap-type: x mandatory/.test(read("app/shop/shop.css")));
check("gallery images carry alt text; the indicator is decorative", /alt=\{img\.alt \?\?/.test(gal) && /shop-gal-dots" aria-hidden/.test(gal));

const css = read("app/shop/shop.css");
check("sticky phone CTA: fixed, safe-area padding, never on desktop", /\.shop-sticky-cta \{[^}]*position: fixed[^}]*env\(safe-area-inset-bottom\)/.test(css) && /min-width: 900px\) \{ \.shop-sticky-cta \{ display: none; \} \}/.test(css));
check("sticky CTA only after the real CTA scrolled away and never with the confirmation open", /!allSold && passedCta && !ctaVisible && !added/.test(view));
check("desktop purchase column sticky; gallery a vertical stack", /\.shop-buy \{ position: sticky;/.test(css) && /\.shop-gal-track \{ flex-direction: column;/.test(css));
check("touch targets: option buttons / swatches / disclosures ≥ 44px", /\.shop-opt-btn \{ min-height: 48px/.test(css) && /\.shop-opt-swatch \{[^}]*width: 44px; height: 44px/.test(css) && /\.shop-disclosure summary \{[^}]*min-height: 52px/.test(css));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
