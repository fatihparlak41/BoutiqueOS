import type { UserRole } from "@/lib/roles";
import type { StockDisplay } from "@/lib/shop/model";

/**
 * Tenant-side online store model (Phase 14A): settings, publishing state and the
 * per-product web view returned by rpc_storefront_admin / rpc_storefront_admin_product.
 * Owner and manager configure; staff have no online-store surface.
 */

export type StorefrontSettings = {
  id: string;
  business_id: string;
  enabled: boolean;
  slug: string;
  store_name: string;
  tagline: string | null;
  announcement: string | null;
  about: string | null;
  instagram: string | null;
  whatsapp: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  fulfillment_branch_id: string | null;
  stock_display: StockDisplay;
  low_stock_threshold: number;
  logo_path: string | null;
};

export type AdminProductRow = {
  id: string;
  name: string;
  web_title: string | null;
  web_slug: string | null;
  web_published: boolean;
  web_featured: boolean;
  web_sort_order: number;
  status: string;
  category: string | null;
  variants: number;
  web_variants: number;
  public_images: number;
  price_from: number | null;
};

export type StorefrontAdmin = {
  storefront: StorefrontSettings | null;
  currency: string;
  branches: Array<{ id: string; name: string; is_default: boolean }>;
  published_count: number;
  products: AdminProductRow[];
  total: number;
};

export type AdminProduct = {
  id: string;
  name: string;
  status: string;
  description: string | null;
  default_sale_price: number;
  web_published: boolean;
  web_published_at: string | null;
  web_title: string | null;
  web_description: string | null;
  web_slug: string | null;
  web_featured: boolean;
  web_sort_order: number;
  variants: Array<{ id: string; sku: string; web_enabled: boolean; price: number; labels: string }>;
  images: Array<{ id: string; role: string; storage_path: string | null; public_path: string | null; alt: string | null; variant_id: string | null; mime_type: string | null }>;
};

export const PUBLIC_IMAGE_ROLES = ["product_main", "product_gallery", "variant"] as const;
export const IMAGE_ROLE_LABELS: Record<string, string> = {
  product_main: "Ana görsel",
  product_gallery: "Galeri",
  variant: "Varyant görseli",
  label_tag: "Etiket (özel)",
  receiving_proof: "Mal kabul kanıtı (özel)",
};

export function storefrontCaps(role: UserRole) {
  const manage = role === "owner" || role === "manager";
  return { canManage: manage };
}

export type StorefrontActionState = { error: string | null; ok: boolean; message?: string };
export const STOREFRONT_IDLE: StorefrontActionState = { error: null, ok: false };
