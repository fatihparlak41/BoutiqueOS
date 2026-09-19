// UX sprint pass 3 — static guards over the global polish: product detail, stock, counts,
// POS, customers, reservations, online orders, terminology and the destructive-action
// pattern (plain Node, no framework).
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");
let pass = 0, fail = 0;
const check = (name, cond, detail = "") => { if (cond) { pass++; console.log(`[PASS] ${name}`); } else { fail++; console.log(`[FAIL] ${name}${detail ? " - " + detail : ""}`); } };

// ---- product detail
const product = read("app/app/urunler/[id]/page.tsx");
const hero = read("components/catalog/product-hero.tsx");
check("product: hero carries image, name, price, category, status", /<ProductHero[\s\S]{0,400}price=\{priceLabel\}[\s\S]{0,200}status=\{product\.status\}/.test(product) && /ProductThumb/.test(hero) && /StatusPill/.test(hero));
check("product: one plum primary 'Stok say', secondary 'Ürünü düzenle', rest behind ⋯", (hero.match(/variant="accent"/g) ?? []).length === 1 && /Stok say/.test(hero) && /Ürünü düzenle/.test(hero) && /product-menu/.test(hero));
check("product: archive only through ConfirmDialog, destructive when archiving", /ConfirmDialog/.test(hero) && /destructive=\{!archived\}/.test(hero) && !/confirm\(/.test(hero));
check("product: old archive toggle removed", (() => { try { read("app/app/urunler/[id]/archive-toggle.tsx"); return false; } catch { return true; } })());
check("product: stock summary Rafta / Ayrılmış / Satılabilir, damaged only when present", /stock-summary/.test(product) && /Rafta/.test(product) && /Ayrılmış/.test(product) && /Satılabilir/.test(product) && /damaged > 0 \?/.test(product));
check("product: quiet inventory value only from the manager-gated valuation", /valuation \?[\s\S]{0,200}Stok değeri/.test(product) && /productInventoryValue\(product\.id, branchId\)/.test(product));
check("product: 'Renkler ve bedenler' section, SKU codes under 'Ayrıntılar'", /Renkler ve bedenler/.test(product) && /product-details/.test(product) && /Seçenek kodları ve barkodlar/.test(product));
check("product: primary count action hidden on archived product", /canCount && !archived \?/.test(hero));
const matrix = read("components/catalog/variant-matrix.tsx");
check("variant matrix: no SKU in the default view, 'Satılabilir' column", !/>\s*\{v\.sku\}/.test(matrix) && /Satılabilir/.test(matrix) && !/Uygun/.test(matrix));

// ---- stock
const stock = read("app/app/stok/page.tsx");
const rows = read("components/stock/stock-rows.tsx");
check("stock: PageHeader with one plum 'Stok say' for counting roles", /<PageHeader/.test(stock) && /countCaps\(role\)\.canCount \? \([\s\S]{0,160}variant="accent"[\s\S]{0,120}Stok say/.test(stock));
check("stock: Search + Filtre pattern (SearchFilters), FilterBar gone", /<SearchFilters/.test(stock) && !/FilterBar/.test(stock));
check("stock: mobile cards + desktop table, Rafta / Ayrılmış / Satılabilir", /stock-cards/.test(rows) && /stock-table/.test(rows) && /Rafta/.test(rows) && /Ayrılmış/.test(rows) && /Satılabilir/.test(rows));
check("stock: damaged / quarantine secondary (only when non-zero)", /row\.quarantine > 0/.test(rows) && /row\.damaged > 0/.test(rows));
check("stock: 'Arşivde' marking and an archive filter link", /Arşivde/.test(rows) && /arsiv: "1"/.test(stock));
check("stock: empty states through EmptyState (filtered + editorial)", (stock.match(/<EmptyState/g) ?? []).length === 2 && /editorial/.test(stock));
check("stock: no cost / value column in the list", !/cost|value_base|MWA/i.test(rows));

// ---- counts
const create = read("components/stock/count/create-count-form.tsx");
const review = read("components/stock/count/review-screen.tsx");
const model = read("lib/stock/count-model.ts");
check("count start: default is the full count, 'Tüm mağazayı say', type under 'Diğer seçenekler'", /useState<StockCountType>\("full"\)/.test(create) && /Tüm mağazayı say/.test(create) && /Diğer seçenekler/.test(create) && /count-more-options/.test(create));
check("count start: semantics unchanged (count_type still posted from the select)", /count_type: type/.test(create) && /COUNT_TYPE_LABELS/.test(create));
check("count review: Sayılan / Sistemde / Fark, no 'Beklenen'", /Sayılan/.test(review) && /Sistemde/.test(review) && /Fark/.test(review) && !/>Beklenen</.test(review));
check("count review: cost copy is human, no COST_REQUIRED in the UI", /Bu ürün için alış maliyeti gerekli\./.test(review) && !/COST_REQUIRED|STALE_REVIEW|UNRESOLVED_LINES/.test(review));
check("count review: cancel through ConfirmDialog (destructive, with reason)", /<ConfirmDialog[\s\S]{0,300}Bu sayım iptal edilsin mi\?[\s\S]{0,300}destructive/.test(review) && !/confirm\(/.test(review));
check("count review: post is the plum primary 'Sayımı tamamla' and still needs the review hash", /variant="accent"[\s\S]{0,300}Sayımı tamamla/.test(review) && /postAction\(count\.id, count\.review_hash\)/.test(review));
check("count review: staff never see cost values (query gate untouched)", /cost rows only|canCost/.test(read("lib/stock/count-queries.ts")) && /cost-staff-note/.test(review));
check("count status: 'Tamamlandı' instead of 'İşlendi'", /posted: "Tamamlandı"/.test(model) && !/İşlendi/.test(model));
const dbErrors = read("lib/db-errors.ts");
check("db errors: STALE_REVIEW / COST_REQUIRED map to sentences the review screen recognises", /\["STALE_REVIEW", "Sayım incelemeden sonra değişti/.test(dbErrors) && /\["COST_REQUIRED: surplus", "Fazla çıkan bir ürün için alış maliyeti gerekli/.test(dbErrors) && /incelemeden sonra değişti/.test(review));

// ---- POS
const pos = read("app/app/pos/page.tsx");
const terminal = read("components/pos/pos-terminal.tsx");
const session = read("components/pos/session-panel.tsx");
check("pos: PageHeader, notices through Notice, no ad-hoc bordered paragraphs", /<PageHeader/.test(pos) && !/border-l-2/.test(pos));
check("pos: Ürün / Sepet / Ödeme stages kept", /"Ürün" : s === "cart" \? `Sepet \(\$\{count\}\)` : "Ödeme"/.test(terminal));
check("pos: payment CTA and mobile next are the plum primary", /variant="accent"[\s\S]{0,200}data-testid="pos-complete"/.test(terminal) && /variant="accent"[\s\S]{0,200}data-testid="pos-next"/.test(terminal));
check("pos: banners through Notice (order / reservation)", /<Notice tone="info">[\s\S]{0,120}pos-order-banner/.test(terminal) && /<Notice tone="info">[\s\S]{0,120}pos-reservation-banner/.test(terminal));
check("pos: 'Kasayı kapat' through ConfirmDialog (destructive) with counted cash", /<ConfirmDialog[\s\S]{0,200}Kasa kapatılsın mı\?[\s\S]{0,400}destructive[\s\S]{0,600}counted_cash/.test(session) && !/confirm\(/.test(session));
check("pos: long-open warning 'Kasa oturumu … beri açık.' with Detay, never auto-closes", /LONG_OPEN_HOURS = 16/.test(session) && /beri açık\./.test(session) && /Detay/.test(session) && /long-open-warning/.test(session) && !/rpc_close_register_session/.test(session) && (session.match(/closeSessionAction\(/g) ?? []).length === 1);
check("pos: long-open hours computed after mount (no hydration mismatch)", /useEffect\(\(\) => \{[\s\S]{0,200}setHoursOpen/.test(session));
check("pos: no cost / COGS / MWA in the terminal", !/cost|cogs|mwa/i.test(terminal));

// ---- customers / reservations / orders
const customers = read("components/crm/customer-search.tsx");
check("customers: empty copy as specified", customers.includes('title="Müşteri listen henüz boş."') && customers.includes('description="Satış sırasında müşteri ekleyebilir veya buradan yeni müşteri oluşturabilirsin."'));
check("customers: PageHeader with one plum 'Yeni müşteri'", /<PageHeader/.test(read("app/app/musteriler/page.tsx")) && (read("app/app/musteriler/page.tsx").match(/variant="accent"/g) ?? []).length === 1);
check("customers: 44px+ rows", /min-h-14/.test(customers));
const rsv = read("app/app/rezervasyonlar/page.tsx");
const crm = read("lib/crm/model.ts");
check("reservations: status words Aktif / Süresi doldu / Tamamlandı / İptal edildi", /active: "Aktif", converted: "Tamamlandı", cancelled: "İptal edildi", expired: "Süresi doldu"/.test(crm) && /Süresi doldu/.test(rsv) && !/Süresi geçti/.test(rsv + read("components/crm/reservation-detail.tsx")));
check("reservations: PageHeader, editorial empty state with purpose", /<PageHeader/.test(rsv) && /editorial/.test(rsv) && /Bekleyen rezervasyon yok/.test(rsv));
const orders = read("app/app/online-siparisler/page.tsx");
const omodel = read("lib/orders/model.ts");
check("orders: merchant status words Yeni / Onaylandı / Hazır / Tamamlandı", /pending_confirmation: "Yeni"/.test(omodel) && /confirmed: "Onaylandı"/.test(omodel) && /ready: "Hazır"/.test(omodel) && /completed: "Tamamlandı"/.test(omodel));
check("orders: mobile cards + desktop table, customer / number / time / total / hold expiry", /order-cards/.test(orders) && /order-table/.test(orders) && /o\.customer_name/.test(orders) && /o\.order_number/.test(orders) && /fmtDateTime\(o\.created_at\)/.test(orders) && /formatShopPrice\(o\.total/.test(orders) && /ayırma bitişi/.test(orders));
check("orders: Search + Filtre pattern, FilterBar gone", /<SearchFilters/.test(orders) && !/FilterBar/.test(orders));
check("orders: customer-facing labels untouched", /completed: "Teslim edildi"/.test(read("lib/shop/model.ts")));

// ---- shared patterns
const sf = read("components/ui/search-filters.tsx");
check("SearchFilters: search field first, Filtre opens a Sheet, plain GET forms", /<Sheet/.test(sf) && /filter-button/.test(sf) && (sf.match(/method="get"/g) ?? []).length >= 2 && !/fetch\(|supabase/.test(sf));
const scoped = ["app/app/urunler/[id]/page.tsx", "app/app/stok/page.tsx", "app/app/stok/sayim/page.tsx", "app/app/pos/page.tsx", "app/app/musteriler/page.tsx", "app/app/rezervasyonlar/page.tsx", "app/app/online-siparisler/page.tsx"];
check("page headers: every scoped list page uses PageHeader (no ad-hoc h2 header)", scoped.every((p) => /<PageHeader/.test(read(p)) || /ProductHero/.test(read(p))) && scoped.every((p) => !/<h2 className="font-serif/.test(read(p))));
check("page headers: at most one plum primary per scoped page (empty states use outline)", scoped.every((p) => (read(p).match(/variant="accent"/g) ?? []).length <= 1) && (customers.match(/variant="accent"/g) ?? []).length === 0);
const termFiles = ["components/stock/stock-rows.tsx", "components/stock/count/review-screen.tsx", "components/stock/count/result-screen.tsx", "components/stock/count/shared.tsx", "components/pos/pos-terminal.tsx", "components/pos/returns-terminal.tsx", "components/crm/reservation-form.tsx", "components/crm/reservation-detail.tsx", "components/catalog/variant-matrix.tsx", "components/catalog/variant-manager.tsx", "app/app/pos/satis/[id]/page.tsx"];
check("terminology: no 'varyant' in shop-floor copy (seçenek / renk-beden)", termFiles.every((p) => !/[Vv]aryant/.test(read(p).replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, ""))));
const destructive = [hero, review, session, read("components/catalog/product-list.tsx"), read("components/stock/count/counting-screen.tsx")];
check("destructive actions: ConfirmDialog everywhere, no native confirm()", destructive.every((s) => /ConfirmDialog/.test(s) && !/window\.confirm|[^a-zA-Z.]confirm\(\s*["'`]/.test(s)));
check("no native alert()", !/[^a-zA-Z.]alert\(/.test(hero + review + session + terminal + customers));

// ---- safety: cost privacy and no SQL change
check("cost privacy: stock rows / terminal / orders carry no cost fields", !/unit_cost|landed|total_value_base|cost_pool/.test(rows + terminal + orders + customers + rsv));
check("no new migration in pass 3 (UI only): latest is 15B-0", readdirSync(join(root, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort().at(-1) === "20260919210000_phase15b0_count_cost_bridge.sql");

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
