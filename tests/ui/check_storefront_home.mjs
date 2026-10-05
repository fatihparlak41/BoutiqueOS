// Phase 14C Pass 5 — static guards for the editorial homepage + image pipeline (plain Node).
//   1. one migration, minimal schema (hero_image_path + hero_heading), media RPC owner/manager + tenant path
//   2. image pipeline: no `unoptimized`, optimiser limited to the public storefront bucket, real dimensions on upload
//   3. homepage: section order, real data only, reuse of the Pass-2 card, one priority image
//   4. admin: grouped settings, logo/hero upload + confirmed removal; no builder
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
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

// 1. migration
const MIG = "20261005100000_phase14c_home_editorial.sql";
const migs = readdirSync(join(root, "supabase/migrations")).filter((f) => f.endsWith(".sql") && f > "20261003150000_public_anon_privilege_hardening.sql" && f < "20261006");
check("Pass 5 adds exactly one migration", migs.join() === MIG, migs.join());
const mig = sqlStrip(read(`supabase/migrations/${MIG}`));
const added = [...mig.matchAll(/ADD COLUMN\s+(\w+)/g)].map((m) => m[1]);
check("schema: only storefronts.hero_image_path + hero_heading are added", added.join() === "hero_image_path,hero_heading" && /ALTER TABLE storefronts\s+ADD COLUMN hero_image_path/.test(mig), added.join());
check("no page builder / sections JSON / theme editor / category image schema", !/page_sections|sections\s+JSONB|CREATE TABLE|category_image|ALTER TABLE categories/i.test(mig));
check("CHECKs bind hero and logo paths to the row's own business", /chk_storefronts_hero_path CHECK \(hero_image_path IS NULL OR hero_image_path ~ \('\^store\/' \|\| business_id::text \|\| '\/hero\//.test(mig) && /chk_storefronts_logo_tenant CHECK \(logo_path IS NULL OR logo_path ~ \('\^store\/' \|\| business_id::text \|\| '\/logo\//.test(mig));
const media = mig.slice(mig.indexOf("CREATE OR REPLACE FUNCTION rpc_storefront_set_media"), mig.indexOf("GRANT  EXECUTE ON FUNCTION rpc_storefront_set_media"));
check("media RPC: owner/manager, kind logo|hero, own-tenant uuid path, object must exist in the public bucket",
  /fn_require_role\(p_business_id, ARRAY\['owner','manager'\]::user_role\[\]\)/.test(media) && /p_kind NOT IN \('logo', 'hero'\)/.test(media)
  && /'\^store\/' \|\| p_business_id::text \|\| '\/' \|\| p_kind \|\| '\/\[0-9a-f\]\{8\}/.test(media) && /storage\.objects o WHERE o\.bucket_id = 'storefront-images' AND o\.name = v_path/.test(media));
check("media RPC grants: authenticated only", /REVOKE EXECUTE ON FUNCTION rpc_storefront_set_media\(UUID, TEXT, TEXT\) FROM PUBLIC, anon, authenticated;/.test(mig) && /GRANT  EXECUTE ON FUNCTION rpc_storefront_set_media\(UUID, TEXT, TEXT\) TO authenticated;/.test(mig));
check("home RPC: category blocks from published + active products with a public image, bounded at 6",
  /'categories'/.test(mig) && /p\.web_published AND p\.status = 'active'\s+AND i\.public_path IS NOT NULL/.test(mig) && /LIMIT 6\) x/.test(mig));

// 2. image pipeline
const shopFiles = ["app/shop/[slug]/page.tsx", "components/shop/header.tsx", "components/shop/product-card.tsx", "components/shop/product-gallery.tsx", "components/shop/cart-view.tsx", "components/shop/checkout-view.tsx", "components/shop/order-view.tsx", "components/shop/product-view.tsx"];
const offenders = shopFiles.filter((f) => /\bunoptimized\b/.test(strip(read(f))));
check("storefront images go through the optimiser (no `unoptimized`)", offenders.length === 0, offenders.join());
const cfg = read("next.config.mjs");
check("next.config: remotePatterns = the Supabase host, public storefront-images path only; no wildcard host",
  /pathname: "\/storage\/v1\/object\/public\/storefront-images\/\*\*"/.test(cfg) && /hostname: supabaseUrl\.hostname/.test(cfg) && !/hostname: "\*\*?"|domains:/.test(cfg) && !/product-images/.test(cfg.replace(/\/\*[\s\S]*?\*\//g, "")));
check("upload body limit matches the hosting limit (4 MB file, 4.5 MB action body)", /bodySizeLimit: "4\.5mb"/.test(cfg) && /IMAGE_MAX_BYTES = 4 \* 1024 \* 1024/.test(read("lib/catalog/images.ts")));
const info = read("lib/media/image-info.ts");
check("image-info reads JPEG / PNG / WebP headers without a dependency", /image\/jpeg/.test(info) && /IHDR/.test(info) && /VP8X/.test(info) && !/^import /m.test(info));
const up = strip(read("app/app/urunler/actions.ts"));
check("product upload records the real width/height and refuses bytes that are not the declared type",
  /const info = readImageInfo\(bytes\)/.test(up) && /info\.mime !== check\.mime/.test(up) && /width: info\.width,\s+height: info\.height/.test(up));
const act = strip(read("app/app/online-magaza/actions.ts"));
check("store media upload: validated bytes, own store/<business>/<kind>/<uuid> path, RPC re-check, old object removed",
  /readImageInfo\(bytes\)/.test(act) && /`store\/\$\{active\.business_id\}\/\$\{kind\}\/\$\{randomUUID\(\)\}\.\$\{check\.ext\}`/.test(act)
  && /rpc_storefront_set_media/.test(act) && /remove\(\[r\.previous_path\]\)/.test(act) && /remove\(\[path\]\)/.test(act));

// 3. homepage
const page = strip(read("app/shop/[slug]/page.tsx"));
const order = ["<Hero ", "Yeni Gelenler", "Kategoriler", "Öne Çıkanlar", "Hakkımızda", "Instagram&apos;da bizi takip edin"].map((t) => page.indexOf(t));
check("homepage order: hero → Yeni Gelenler → categories → Öne Çıkanlar → about → Instagram", order.every((i, n) => i > 0 && (n === 0 || i > order[n - 1])), order.join());
check("sections render only from data (new arrivals / blocks ≥ 2 / featured / about / instagram)",
  /arrivals\.length > 0 \?/.test(page) && /blocks\.length >= 2 \?/.test(page) && /featured\.length > 0 \?/.test(page) && /store\.about \?/.test(page) && /store\.instagram \?/.test(page));
check("product sections reuse the Pass-2 card grid; one featured product gets the editorial single layout, 2–4 the grid",
  (page.match(/<ProductGrid /g) ?? []).length === 2 && !/shop-card"/.test(page) && /featured\.length === 1 \? \(\s*<FeaturedSingle /.test(page) && /data-mode=\{featured\.length === 1 \? "single" : "grid"\}/.test(page));
check("hero sizes describe the rendered width (phone 100vw, tablet ≤ 600 px, desktop ≤ 585 px), and device sizes have 828 / 1200 buckets",
  /HERO_SIZES = "\(min-width: 1330px\) 585px, \(min-width: 900px\) 44vw, \(min-width: 600px\) 600px, 100vw"/.test(page) && /sizes=\{HERO_SIZES\}/.test(page) && /deviceSizes: \[390, 640, 768, 828, 1080, 1200, 1440, 1920\]/.test(read("next.config.mjs")));
check("product upload guidance: portrait, ≥ 1200 px long edge recommended — never blocked or upscaled",
  /uzun kenarı en az 1200 px önerilir/.test(read("components/catalog/image-manager.tsx")) && /longEdge < 1200 \?/.test(read("app/app/urunler/actions.ts")));
check("only the hero (or the first fallback photo) is a priority image", (page.match(/\bpriority\b/g) ?? []).length === 2 && /fill priority sizes=\{HERO_SIZES\}/.test(page) && /priority=\{i === 0\}/.test(page) && !/eager=/.test(page));
check("hero: one CTA 'Yeni Gelenleri Keşfet'; heading from settings; no hard-coded campaign or TLC copy",
  (page.match(/Yeni Gelenleri Keşfet/g) ?? []).length === 1 && /store\.hero_heading \?\? store\.store_name/.test(page) && !/Things Like Crop|TLC|Yaz 2\d|İndirim|Kampanya|%\s?\d/.test(page));
check("hero fallback: store name + tagline + up to 3 product photos when ≥ 2 exist; never a placeholder", /photos\.length >= 2 \?/.test(page) && /slice\(0, 3\)/.test(page) && !/placeholder|picsum|unsplash/i.test(page));
check("category blocks: image + name + 'Keşfet'; no pill chips", /shop-catblock-name/.test(page) && /Keşfet/.test(page) && !/shop-chip/.test(page) && !/\.shop-chip/.test(read("app/shop/shop.css")));
check("Instagram: a plain profile link (no feed, no fetch, no embed)", /href=\{`https:\/\/www\.instagram\.com\/\$\{store\.instagram\}\/`\}/.test(page) && !/fetch\(|<iframe|embed/i.test(page));
check("announcement bar only when text exists", /\{store\.announcement \? <div className="shop-announce">/.test(read("components/shop/header.tsx")));
check("logo: optional, contained box; text fallback otherwise", /logo \? <span className="shop-logo"><Image/.test(read("components/shop/header.tsx")) && /: store\.store_name\}/.test(read("components/shop/header.tsx")));
const css = read("app/shop/shop.css");
check("hero CSS: explicit box sizes (phone full width at 4:5 capped 78svh; desktop definite height at 3:4, flush end), no layout shift", /\.shop-hero-ed-media \{[^}]*width: 100%; height: min\(133\.333vw, 78svh\)/.test(css) && /\.shop-hero-ed-media \{ justify-self: center; width: min\(100%, calc\(78svh \* 0\.75\)\); height: auto; aspect-ratio: 3 \/ 4; \}/.test(css) && /\.shop-hero-ed-media \{ height: min\(76vh, 780px\); width: auto; max-width: 100%; aspect-ratio: 3 \/ 4; justify-self: end; \}/.test(css));
check("visual language: no gradients / heavy shadows / glass in the home CSS", !/\.shop-(hero|catblock|about|insta)[^{]*\{[^}]*(gradient|box-shadow|backdrop-filter)/.test(css));
check("home reads stay at 2 RPCs (resolve shared with the layout + one bounded home call)", /Promise\.all\(\[getStore\(slug\), getHome\(slug\)\]\)/.test(page) && /rpc_shop_home", \{ p_slug: slug, p_limit: 4 \}/.test(read("lib/shop/queries.ts")));

// 4. admin
const forms = strip(read("app/app/online-magaza/forms.tsx"));
check("admin groups: Mağaza · Görünüm · İletişim · Stok ve sipariş; one settings form across groups", /title="Mağaza"/.test(forms) && /title="Görünüm"/.test(forms) && /title="İletişim"/.test(forms) && /title="Stok ve sipariş"/.test(forms) && /<form id=\{f\} action=\{formAction\}/.test(forms) && (forms.match(/form=\{f\}/g) ?? []).length >= 15);
check("admin: Mağazayı görüntüle, Ana başlık, Teslim şubesi; logo + ana görsel fields", /Mağazayı görüntüle/.test(forms) && /Ana başlık/.test(forms) && /Teslim şubesi/.test(forms) && /<StoreMediaField kind="logo"/.test(forms) && /<StoreMediaField kind="hero"/.test(forms));
check("media removal only through ConfirmDialog (destructive)", /<ConfirmDialog[\s\S]*destructive[\s\S]*onConfirm=\{remove\}/.test(forms));
check("admin copy no longer claims there are no orders", !/Online ödeme ve sipariş bu sürümde yoktur/.test(read("app/app/online-magaza/page.tsx")));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
