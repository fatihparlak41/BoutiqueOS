// Phase 14C Pass 6 — static guards for storefront SEO + structured data (plain Node).
//   1. one sitemap RPC (published-only, bounded, no ids) and the 11-RPC anon allowlist
//   2. centralised canonical / URL helpers; no hand-built canonical strings in pages
//   3. noindex rules: parameterised listings, private pages, not-found metadata
//   4. JSON-LD: escaped serialiser, Product (+ Offer/AggregateOffer) without internals, ClothingStore
//   5. robots + sitemap routes
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/\{\/\*[\s\S]*?\*\/\}/g, "");
const sqlStrip = (s) => s.replace(/--.*$/gm, "");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`[PASS] ${name}`); }
  else { fail++; console.log(`[FAIL] ${name}${detail ? " - " + detail : ""}`); }
}

// 1. sitemap RPC
const MIG = "20261006100000_phase14c_shop_sitemap.sql";
const migs = readdirSync(join(root, "supabase/migrations")).filter((f) => f.endsWith(".sql") && f > "20261005100000_phase14c_home_editorial.sql" && f < "20261007");
check("Pass 6 adds exactly one migration (the sitemap RPC)", migs.join() === MIG, migs.join());
const mig = sqlStrip(read(`supabase/migrations/${MIG}`));
check("sitemap RPC: STABLE SECURITY DEFINER, pinned search_path, anon + authenticated only", /RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public/.test(mig)
  && /REVOKE EXECUTE ON FUNCTION rpc_shop_sitemap\(INTEGER, INTEGER\) FROM PUBLIC, anon, authenticated;/.test(mig) && /GRANT  EXECUTE ON FUNCTION rpc_shop_sitemap\(INTEGER, INTEGER\) TO anon, authenticated;/.test(mig));
check("sitemap RPC: enabled stores on active businesses; published active products; categories with published products",
  /WHERE s\.enabled AND b\.status = 'active'/.test(mig) && /p\.web_published AND p\.status = 'active' AND p\.web_slug IS NOT NULL/.test(mig) && /c\.is_active AND EXISTS \(SELECT 1 FROM products p WHERE p\.category_id = c\.id AND p\.web_published AND p\.status = 'active'\)/.test(mig));
check("sitemap RPC: rows are only s/k/p/m (no ids, names, prices) and the page is bounded (≤ 10000)",
  /jsonb_build_object\('s', s, 'k', k, 'p', p, 'm', m\)/.test(mig) && /LEAST\(GREATEST\(COALESCE\(p_limit, 5000\), 1\), 10000\)/.test(mig) && !/\b(id|store_name|price|cost|sku|barcode|customer)\b'?,/i.test(mig.slice(mig.indexOf("jsonb_build_object"))));
check("sitemap RPC writes nothing", !/INSERT INTO|UPDATE \w+ SET|DELETE FROM/.test(mig));

// 2. central URL helpers
const seo = strip(read("lib/shop/seo.ts"));
check("one origin helper for every storefront URL (custom-domain pass changes only storefrontOrigin)", /export function storefrontOrigin\(_storeSlug: string\): string \{\s*return siteOrigin\(\);/.test(seo) && /export function storefrontUrl\(/.test(seo));
const pages = ["app/shop/[slug]/page.tsx", "app/shop/[slug]/urun/[pslug]/page.tsx", "components/shop/listing.tsx", "app/shop/[slug]/layout.tsx"].map((f) => [f, strip(read(f))]);
check("pages build canonicals only through storefrontUrl (no hand-written canonical / og:url strings)",
  pages.every(([, s]) => !/canonical: `|canonical: "\//.test(s) && !/url: `\$\{origin\}/.test(s)) && pages.filter(([f]) => !f.endsWith("layout.tsx")).every(([, s]) => /alternates: \{ canonical: url \}/.test(s)));
check("layout sets no canonical and no robots default (private pages and 404s must not inherit them)", !/canonical|robots:/.test(pages.find(([f]) => f.endsWith("layout.tsx"))[1].split("generateMetadata")[1].split("export default")[0].replace(/if \(!store\) return \{[^}]*\}[^}]*\};/, "")));
check("share images only via seoImage (public store/ paths, absolute)", /if \(!url \|\| !img\?\.path\.startsWith\("store\/"\)\) return null;/.test(seo) && pages.every(([, s]) => !/publicImageUrl\(/.test(s) || /seoImage/.test(s)));

// 3. noindex
const listing = strip(read("components/shop/listing.tsx"));
check("parameterised listings: noindex,follow + clean canonical", /\.\.\.\(parameterised \? \{ robots: \{ index: false, follow: true \} \} : \{\}\)/.test(listing) && /isParameterised\(searchParams\)/.test(listing));
check("query keys that make a listing parameterised: q, renk, beden, stok, sirala, sayfa, baslangic", /\["q", "renk", "beden", "stok", "sirala", "sayfa", "baslangic"\]/.test(read("lib/shop/listing-url.ts")));
check("unknown store / category / product metadata: noindex,nofollow and no record details",
  /if \(category && !cat\) return \{ title: "Sayfa bulunamadı", robots: \{ index: false, follow: false \} \};/.test(listing)
  && /if \(!store \|\| !product\) return \{ title: "Ürün bulunamadı", robots: \{ index: false, follow: false \} \};/.test(read("app/shop/[slug]/urun/[pslug]/page.tsx")));
for (const [f, label] of [["app/shop/[slug]/sepet/page.tsx", "cart"], ["app/shop/[slug]/checkout/page.tsx", "checkout"], ["app/shop/[slug]/siparis/[token]/page.tsx", "tracking"]]) {
  const s = strip(read(f));
  check(`${label}: noindex,nofollow, no canonical, no openGraph url`, /robots: \{ index: false, follow: false/.test(s) && !/canonical|openGraph/.test(s));
}

// 4. JSON-LD
check("JSON-LD only through <JsonLd> (no raw JSON.stringify inside a script)", pages.every(([, s]) => !/dangerouslySetInnerHTML=\{\{ __html: JSON\.stringify/.test(s)) && /serializeJsonLd\(data\)/.test(read("components/shop/json-ld.tsx")));
const prod = seo.slice(seo.indexOf("export function productJsonLd"));
check("Product JSON-LD: Offer / AggregateOffer from web prices + fresh availability; no SKU, barcode, id, brand, rating, quantity",
  /"@type": "Product"/.test(prod) && /"@type": "Offer"/.test(prod) && /"@type": "AggregateOffer"/.test(prod) && /https:\/\/schema\.org\/InStock/.test(prod)
  && !/\bsku\b|gtin|barcode|brand|aggregateRating|review|inventoryLevel|\.available\b|variant_id|\bv\.id\b\s*[,}]/.test(prod.replace(/fresh\[v\.id\]/g, "")));
const store = seo.slice(seo.indexOf("export function storeJsonLd"), seo.indexOf("export function breadcrumbJsonLd"));
check("ClothingStore JSON-LD: configured public fields only; no address, opening hours or ratings", /"@type": "ClothingStore"/.test(store) && !/address|openingHours|aggregateRating|geo/i.test(store.replace(/No address[^\n]*\n/, "")));

// serializer behaviour (pure; executed)
const src = read("lib/shop/seo.ts");
const body = src.slice(src.indexOf("export function serializeJsonLd"), src.indexOf("}\n", src.indexOf("export function serializeJsonLd")) + 2).replace("export function", "function").replace("(data: unknown): string", "(data)");
const serialize = new Function(`${body}; return serializeJsonLd;`)();
const LS = String.fromCharCode(0x2028), PS = String.fromCharCode(0x2029);
const evil = { d: "</script><script>alert(1)</script> & <!-- " + LS + " " + PS };
const out = serialize(evil);
check("serializer: no raw <, >, &, U+2028/2029 survive, and the JSON round-trips", !["<", ">", "&", LS, PS].some((c) => out.includes(c)) && JSON.parse(out).d === evil.d, out);

// 5. robots + sitemap
const robots = read("app/robots.ts");   // not stripped: "/shop/*/…" would look like a block comment
check("robots: allows /shop/, disallows operational + private storefront routes, references the root sitemap",
  /allow: \["\/shop\/"\]/.test(robots) && ["/app/", "/platform/", "/login", "/shop/*/sepet", "/shop/*/checkout", "/shop/*/siparis/"].every((p) => robots.includes(`"${p}"`)) && /sitemap: `\$\{siteOrigin\(\)\}\/sitemap\.xml`/.test(robots));
const sitemap = strip(read("app/sitemap.ts"));
check("sitemap: built from the public RPC rows via storefrontUrl; lastModified only when the row carries one; hourly", /getSitemapEntries\(\)/.test(sitemap) && /url: storefrontUrl\(r\.s, r\.k, r\.p\)/.test(sitemap) && /\.\.\.\(r\.m \? \{ lastModified: new Date\(r\.m\) \} : \{\}\)/.test(sitemap) && /revalidate = 3600/.test(sitemap) && !/new Date\(\)/.test(sitemap));
const q = strip(read("lib/shop/queries.ts"));
check("sitemap read: anon client + the one RPC, paged, capped at one sitemap file, cached with its own tag", /rpc\("rpc_shop_sitemap", \{ p_offset: offset, p_limit: SITEMAP_PAGE \}\)/.test(q) && /SITEMAP_MAX_URLS = 50000/.test(q) && /tags: \["shop-sitemap"\]/.test(q) && !/service_role|SERVICE_ROLE/.test(q));

check("metadata is never streamed into <body>: htmlLimitedBots covers every user agent", read("next.config.mjs").includes("htmlLimitedBots: /.*/,"));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
