// Phase 14C Pass 4 — static guards for cart, checkout, order success and tracking (plain Node).
//   1. no SQL; 14B logic intact (idempotency key, in-flight lock, server truth for CART_PROBLEMS)
//   2. wording: cart "Siparişe Devam Et", checkout "Sipariş Talebi Oluştur" + the required copy,
//      never payment words; one quiet contact link
//   3. errors: every code the public order RPCs raise maps to customer words; no raw codes
//   4. tracking: customer labels, milestones from status timestamps only, no internal events
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

const migs = readdirSync(join(root, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort();
check("Pass 4 adds no migration", migs.at(-1) === "20261003140000_phase14c_shop_filters.sql", migs.at(-1));

// cart
const cart = strip(read("components/shop/cart-view.tsx"));
check("cart CTA is 'Siparişe Devam Et' and only leads to checkout", /Siparişe Devam Et/.test(cart) && /href=\{`\$\{base\}\/checkout`\}/.test(cart) && !/Sipariş Talebi Oluştur|Ödemeye Geç/.test(cart));
check("cart does not submit, reserve or order anything", !/rpc_shop_create_order|reserv/i.test(cart));
check("one honest payment line", /Ödeme mağazada teslim sırasında yapılır\./.test(cart) && !/hold|rezerv|ayrılır|stok ayırmaz/i.test(cart));
check("one quiet contact link instead of competing buttons", /Sorunuz mu var\?/.test(cart) && !/className="shop-btn[^"]*"[^>]*href=\{wa\}/.test(cart) && (cart.match(/className="shop-btn/g) ?? []).length <= 2);
check("empty cart: 'Sepetin boş.' / start copy / 'Ürünleri keşfet'", /Sepetin boş\./.test(cart) && /Beğendiğin ürünleri sepete ekleyerek başlayabilirsin\./.test(cart) && /Ürünleri keşfet/.test(cart));
check("cart availability is ONE batched call", (cart.match(/rpc_shop_availability/g) ?? []).length === 1 && /p_variant_ids: c\.lines\.map/.test(cart));
check("quantity buttons are 44px", /\.shop-qty button \{[^}]*width: 44px; height: 44px/.test(read("app/shop/shop.css")));

// checkout
const co = strip(read("components/shop/checkout-view.tsx"));
check("required explanation copy", /Bu işlem bir sipariş talebi oluşturur\.<br \/>\s*Mağaza siparişinizi onayladıktan sonra sizinle iletişime geçecektir\./.test(co));
check("CTA 'Sipariş Talebi Oluştur' with a visible submitting state; no payment words", /Sipariş Talebi Oluştur/.test(co) && /Gönderiliyor…/.test(co) && !/Satın Al|Ödemeyi Tamamla|>\s*Öde\s*</.test(co));
check("fields: Ad Soyad, Telefon, E-posta + Not optional; no address / account / shipping", /Ad Soyad/.test(co) && /Telefon/.test(co) && /E-posta <em>isteğe bağlı<\/em>/.test(co) && /Not <em>isteğe bağlı<\/em>/.test(co) && !/name="(address|city|password)"|teslimat adresi|şifre|parola|kargo/i.test(co));
check("only 'Mağazadan Teslim' with the configured branch", /Mağazadan Teslim/.test(co) && /store\.pickup_branch \?\? store\.store_name/.test(co) && /p_fulfillment: "store_pickup"/.test(co));
check("double submit: in-flight lock + one idempotency key per attempt", /if \(!cart \|\| inFlight\.current\) return;/.test(co) && /getOrCreateCheckoutKey\(store\.slug\)/.test(co) && /p_idempotency_key: key/.test(co));
check("cart cleared only after the server returned the order", /const r = data as CheckoutResult;[\s\S]*clearCheckoutKey[\s\S]*writeCart\(\{ store: store\.slug, lines: \[\]/.test(co) && co.indexOf("writeCart({ store: store.slug, lines: []") > co.indexOf("if (err) {"));
check("server truth on CART_PROBLEMS: lines removed / shrunk, customer notices", /CART_PROBLEMS/.test(co) && /bu ürün artık müsait değil/.test(co));
check("human validation messages", /Lütfen adınızı girin\./.test(co) && /Lütfen telefon numaranızı girin\./.test(co) && /Lütfen geçerli bir telefon numarası girin\./.test(co));
check("errors go through the customer mapper, never the merchant one", /checkoutErrorMessage\(err\)/.test(co) && !/toUserMessage/.test(co));
check("success lands on the order page (?yeni=1)", /router\.push\(`\$\{base\}\/siparis\/\$\{r\.tracking_token\}\?yeni=1`\)/.test(co));

// error coverage: every RAISE code of the public order RPCs has a customer sentence (or the safe fallback)
const sql = read("supabase/migrations/20260919190000_phase14b_current_hold_fix.sql") + read("supabase/migrations/20260919170000_phase14b_online_orders.sql");
const body = (name) => { const i = sql.indexOf(`CREATE OR REPLACE FUNCTION ${name}`); return i < 0 ? "" : sql.slice(i, sql.indexOf("END $$", i)); };
const codes = new Set([...`${body("rpc_shop_create_order")}${body("rpc_shop_cancel_order")}`.matchAll(/RAISE EXCEPTION '([A-Z_]+)/g)].map((m) => m[1]));
const mapper = read("lib/shop/customer-errors.ts");
const unmapped = [...codes].filter((c) => !new RegExp(c).test(mapper) && !["NOT_FOUND", "INVALID_INPUT", "INVALID_KEY"].includes(c));
check("every public order error code has customer wording (others fall back safely)", unmapped.length === 0 && /FALLBACK_CHECKOUT/.test(mapper), unmapped.join(", "));
check("the customer mapper never returns a raw code", !/=> err\.message|return raw/.test(mapper));
check("merchant 'İşletme adı gerekli.' can no longer reach a shopper", !/İşletme adı/.test(mapper) && /INVALID_NAME\/, "Lütfen adınızı girin\."/.test(mapper));

// tracking
const ov = strip(read("components/shop/order-view.tsx"));
const model = read("lib/shop/model.ts");
check("customer status labels", /pending_confirmation: "Talep alındı"/.test(model) && /confirmed: "Onaylandı"/.test(model) && /ready: "Hazır"/.test(model) && /completed: "Tamamlandı"/.test(model) && /cancelled: "İptal edildi"/.test(model) && /expired: "Süresi doldu"/.test(model));
check("milestones from status timestamps only; no internal engine events rendered", /o\.confirmed_at/.test(ov) && /o\.ready_at/.test(ov) && !/order\.timeline|rereserved|converted|yeniden ayrıldı|Ayırma süresi|POS/.test(ov));
check("status copy: success / expired / cancelled / completed in customer words", /Sipariş talebiniz alındı\./.test(ov) && /Sipariş talebinin süresi doldu\./.test(ov) && /Sipariş iptal edildi\./.test(ov) && /Sipariş tamamlandı\./.test(ov) && !/Ödeme başarılı|iade edil/i.test(ov));
check("success actions: 'Sipariş durumunu görüntüle' + 'Alışverişe devam et'", /Sipariş durumunu görüntüle/.test(ov) && /Alışverişe devam et/.test(ov));
check("cancel errors use customer wording", /cancelErrorMessage\(err\)/.test(ov) && !/toUserMessage/.test(ov));
const page = strip(read("app/shop/[slug]/siparis/[token]/page.tsx"));
check("order page: noindex, never cached, unknown token → store 404", /index: false, follow: false, noarchive: true/.test(page) && /dynamic = "force-dynamic"/.test(page) && /if \(!order\) notFound\(\)/.test(page));
check("the token is never logged", !/console\.(log|info|error)\([^)]*token/.test(page + ov + co));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
