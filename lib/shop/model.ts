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
