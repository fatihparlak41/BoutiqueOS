/**
 * Public storefront model (Phase 14A). Shapes returned by the rpc_shop_* reads and the
 * browser-side cart. Nothing here knows an internal id beyond the variant id a cart
 * line needs; there is no SKU, no barcode, no cost and no supplier anywhere in these types.
 */

export type Availability = "in_stock" | "low" | "sold_out";
export type StockDisplay = "state" | "exact";

export type ShopImage = { id?: string; path: string; alt: string | null; role?: string; variant_id?: string | null; width: number | null; height: number | null };

export type ShopCategory = { slug: string; name: string; count: number };

export type Store = {
  slug: string;
  store_name: string;
  tagline: string | null;
  announcement: string | null;
  about: string | null;
  instagram: string | null;
  whatsapp: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  logo_path: string | null;
  theme: Record<string, unknown>;
  stock_display: StockDisplay;
  low_stock_threshold: number;
  currency: string;
  orders_enabled: boolean;
  order_hold_minutes: number;
  pickup_note: string | null;
  pickup_branch: string | null;
  categories: ShopCategory[];
  published_count: number;
};

export type ProductCard = {
  slug: string;
  name: string;
  featured: boolean;
  price_from: number | null;
  price_to: number | null;
  availability: Availability;
  image: { path: string; alt: string | null; width: number | null; height: number | null } | null;
  colors: Array<{ value: string; hex: string | null }>;
  category: { slug: string; name: string } | null;
  published_at: string | null;
};

export type ShopHome = { featured: ProductCard[]; new_arrivals: ProductCard[] };
export type ProductList = { rows: ProductCard[]; total: number; limit: number; offset: number; category: { slug: string; name: string } | null };

export type ShopOption = { id: string; name: string; kind: "color" | "size" | "other"; values: Array<{ id: string; value: string; code: string | null; hex: string | null }> };
export type ShopVariant = { id: string; price: number; option_value_ids: string[]; available: number | null; state: Availability; image_id: string | null };

export type ShopProduct = {
  slug: string;
  name: string;
  description: string | null;
  currency: string;
  stock_display: StockDisplay;
  low_stock_threshold: number;
  category: { slug: string; name: string } | null;
  images: ShopImage[];
  options: ShopOption[];
  variants: ShopVariant[];
};

export type AvailabilityMap = Record<string, { state: Availability; available: number | null; price: number | null; product_slug: string | null }>;

export const AVAILABILITY_LABELS: Record<Availability, string> = { in_stock: "Stokta", low: "Son ürünler", sold_out: "Tükendi" };
export const SORT_OPTIONS = [
  { value: "newest", label: "Yeni gelenler" },
  { value: "price_asc", label: "Fiyat: düşükten yükseğe" },
  { value: "price_desc", label: "Fiyat: yüksekten düşüğe" },
] as const;
export type SortKey = (typeof SORT_OPTIONS)[number]["value"];
export const PAGE_SIZE = 24;

/** Public image URL: the storefront bucket is public; only published copies live there. */
export function publicImageUrl(path: string | null | undefined): string | null {
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!path || !base) return null;
  return `${base}/storage/v1/object/public/storefront-images/${path}`;
}

export function formatShopPrice(amount: number, currency: string): string {
  return new Intl.NumberFormat("tr-TR", { style: "currency", currency, maximumFractionDigits: 2, minimumFractionDigits: 0 }).format(amount);
}

/** "1.200 ₺" or "800 – 1.200 ₺" for a card. */
export function formatPriceRange(from: number | null, to: number | null, currency: string): string {
  if (from === null) return "—";
  if (to === null || to === from) return formatShopPrice(from, currency);
  return `${formatShopPrice(from, currency)} – ${formatShopPrice(to, currency)}`;
}

export function availabilityText(state: Availability, exact: number | null, display: StockDisplay): string {
  if (state === "sold_out") return AVAILABILITY_LABELS.sold_out;
  if (display === "exact" && exact !== null) return exact === 1 ? "Son 1 adet" : `${exact} adet`;
  return AVAILABILITY_LABELS[state];
}

// ---------------------------------------------------------------- cart (browser state; CART ≠ RESERVATION)

export type CartLine = {
  variant_id: string;
  product_slug: string;
  name: string;
  /** Option labels chosen, e.g. "Siyah / M". */
  labels: string;
  /** Unit price at the time the line was added — display only, re-checked before continuing. */
  unit_price: number;
  currency: string;
  quantity: number;
  image_path: string | null;
};

export type Cart = { store: string; lines: CartLine[]; updated_at: string };

export const CART_MAX_LINES = 20;
export const CART_MAX_QTY = 10;

export function cartKey(slug: string): string {
  return `bos_cart:${slug}`;
}

/** Reads the cart of ONE store; a cart never spans two boutiques. */
export function readCart(slug: string): Cart {
  const empty: Cart = { store: slug, lines: [], updated_at: new Date(0).toISOString() };
  try {
    const raw = typeof window !== "undefined" ? window.localStorage.getItem(cartKey(slug)) : null;
    if (!raw) return empty;
    const parsed = JSON.parse(raw) as Cart;
    if (!parsed || parsed.store !== slug || !Array.isArray(parsed.lines)) return empty;
    return { store: slug, lines: parsed.lines.filter((l) => typeof l.variant_id === "string" && l.quantity > 0).slice(0, CART_MAX_LINES), updated_at: parsed.updated_at ?? empty.updated_at };
  } catch {
    return empty;
  }
}

export function writeCart(cart: Cart): void {
  try {
    window.localStorage.setItem(cartKey(cart.store), JSON.stringify({ ...cart, updated_at: new Date().toISOString() }));
    window.dispatchEvent(new CustomEvent("bos-cart", { detail: { store: cart.store } }));
  } catch {
    // storage unavailable (private mode): the cart simply does not persist
  }
}

export function cartCount(cart: Cart): number {
  return cart.lines.reduce((n, l) => n + l.quantity, 0);
}

export function cartTotal(cart: Cart): number {
  return cart.lines.reduce((n, l) => n + l.quantity * l.unit_price, 0);
}

// ---------------------------------------------------------------- guest order (Phase 14B)

export type OnlineOrderStatus = "pending_confirmation" | "confirmed" | "ready" | "completed" | "cancelled" | "expired";

export const ORDER_STATUS_LABELS: Record<OnlineOrderStatus, string> = {
  pending_confirmation: "Onay bekliyor",
  confirmed: "Onaylandı",
  ready: "Teslime hazır",
  completed: "Teslim edildi",
  cancelled: "İptal edildi",
  expired: "Süresi doldu",
};

/** What the customer sees on the tracking page (rpc_shop_order). Order-safe: no internal ids. */
export type PublicOrder = {
  order_number: string;
  status: OnlineOrderStatus;
  stored_status: OnlineOrderStatus;
  fulfillment_method: "store_pickup" | "local_delivery" | "shipping";
  customer_name: string;
  phone: string;
  email: string | null;
  note: string | null;
  currency: string;
  subtotal: number;
  discount_total: number;
  total: number;
  item_count: number;
  reservation_expires_at: string | null;
  reservation_active: boolean | null;
  created_at: string;
  confirmed_at: string | null;
  ready_at: string | null;
  completed_at: string | null;
  cancelled_at: string | null;
  expired_at: string | null;
  cancelled_by_customer: boolean;
  can_cancel: boolean;
  pickup: { branch: string; note: string | null; store_name: string; whatsapp: string | null; instagram: string | null; phone: string | null } | null;
  items: Array<{ product_slug: string; name: string; labels: string; image_path: string | null; quantity: number; unit_price: number; line_total: number }>;
  timeline: Array<{ event: string; at: string }>;
};

export type CheckoutResult = { order_number: string; tracking_token: string; status: OnlineOrderStatus; total: number; currency: string; reservation_expires_at: string | null; replayed: boolean };

/** A problem the server found with a cart line at checkout (CART_PROBLEMS). */
export type CartProblem = { variant_id: string; code: "UNAVAILABLE" | "INSUFFICIENT"; available?: number; name?: string; labels?: string };

export function checkoutKeyStorage(slug: string): string {
  return `bos_checkout:${slug}`;
}
export function ordersStorage(slug: string): string {
  return `bos_orders:${slug}`;
}

/** The browser's high-entropy idempotency key for one checkout attempt of one store (kept until the order exists). */
export function getOrCreateCheckoutKey(slug: string): string {
  try {
    const existing = window.localStorage.getItem(checkoutKeyStorage(slug));
    if (existing && /^[0-9a-f]{64}$/.test(existing)) return existing;
  } catch { /* no storage */ }
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const key = Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
  try { window.localStorage.setItem(checkoutKeyStorage(slug), key); } catch { /* no storage */ }
  return key;
}

export function clearCheckoutKey(slug: string): void {
  try { window.localStorage.removeItem(checkoutKeyStorage(slug)); } catch { /* no storage */ }
}

/** Remembers this browser's order tokens so the customer can find their orders again. */
export function rememberOrder(slug: string, orderNumber: string, token: string): void {
  try {
    const raw = window.localStorage.getItem(ordersStorage(slug));
    const list: Array<{ order_number: string; token: string; at: string }> = raw ? JSON.parse(raw) : [];
    if (!list.some((o) => o.token === token)) list.unshift({ order_number: orderNumber, token, at: new Date().toISOString() });
    window.localStorage.setItem(ordersStorage(slug), JSON.stringify(list.slice(0, 10)));
  } catch { /* no storage */ }
}

export function orderStatusText(status: OnlineOrderStatus): string {
  return ORDER_STATUS_LABELS[status];
}

