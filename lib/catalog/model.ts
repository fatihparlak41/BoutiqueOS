import type { UserRole } from "@/lib/tenant";

/**
 * Catalogue vocabulary shared by server queries and client forms.
 *
 * Deliberately free of "server-only" and of any data access: the variant and product
 * forms are client components and need these types, the status labels and the capability
 * rules. Everything that touches Supabase lives in queries.ts instead.
 *
 * The status unions mirror the product_status / variant_status enums from migration
 * 20260908000001. They are not invented booleans — "aktif/pasif" is a three-state enum on
 * products and a two-state enum on variants.
 */

export type ProductStatus = "draft" | "active" | "archived";
export type VariantStatus = "active" | "archived";

export const PRODUCT_STATUS_LABELS: Record<ProductStatus, string> = {
  draft: "Taslak",
  active: "Aktif",
  archived: "Arşiv",
};

export const VARIANT_STATUS_LABELS: Record<VariantStatus, string> = {
  active: "Aktif",
  archived: "Arşiv",
};

export type NamedRef = { id: string; name: string };

export type OptionValue = { id: string; value: string; sort_order: number };
export type ProductOption = { id: string; name: string; sort_order: number; values: OptionValue[] };

export type Barcode = {
  id: string;
  barcode: string;
  barcode_type: "internal" | "supplier";
  symbology: string;
  is_primary: boolean;
};

export type VariantOptionPair = {
  option_id: string;
  option_name: string;
  value_id: string;
  value: string;
};

export type VariantRow = {
  id: string;
  sku: string;
  status: VariantStatus;
  sale_price_override: number | null;
  options: VariantOptionPair[];
  barcodes: Barcode[];
};

export type ProductListRow = {
  id: string;
  name: string;
  sku_prefix: string;
  status: ProductStatus;
  default_sale_price: number;
  category: NamedRef | null;
  brand: NamedRef | null;
  variant_count: number;
  /** Effective price span across active variants; null when the product has no active variant. */
  price_min: number | null;
  price_max: number | null;
};

export type ProductDetail = {
  id: string;
  name: string;
  sku_prefix: string;
  status: ProductStatus;
  default_sale_price: number;
  tax_rate: number;
  is_tax_inclusive: boolean;
  collection: string | null;
  description: string | null;
  category_id: string | null;
  brand_id: string | null;
  category: NamedRef | null;
  brand: NamedRef | null;
  variants: VariantRow[];
};

export type ProductFilters = {
  search?: string;
  categoryId?: string;
  brandId?: string;
  status?: ProductStatus;
};

export type CatalogCaps = {
  /** products / variants / options / brands: pol_*_write => fn_is_manager_plus */
  canEditCatalog: boolean;
  /** barcodes: pol_barcodes_write => fn_is_procurement (owner | manager | stock_staff) */
  canManageBarcodes: boolean;
};

/**
 * Mirrors the RLS predicates, so a button is hidden when the database would refuse the
 * write anyway. Hiding is a courtesy; RLS is the actual boundary.
 */
export function catalogCaps(role: UserRole): CatalogCaps {
  return {
    canEditCatalog: role === "owner" || role === "manager",
    canManageBarcodes: role === "owner" || role === "manager" || role === "stock_staff",
  };
}
