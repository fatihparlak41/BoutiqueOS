import "server-only";

import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";
import { catalogCaps } from "@/lib/catalog/model";
import type {
  NamedRef,
  ProductDetail,
  ProductFilters,
  ProductListRow,
  ProductOption,
  ProductStatus,
  VariantRow,
  VariantStatus,
} from "@/lib/catalog/model";

// Server code keeps importing the vocabulary from here; the client imports it from model.
export * from "@/lib/catalog/model";

/**
 * Read side of the product catalogue.
 *
 * Every query is additionally filtered by business_id even though RLS already scopes it:
 * the filter is defence in depth, never the security boundary. No cost column is selected
 * anywhere in this file — cost lives in variant_cost_pools and belongs to goods receipt,
 * not to the catalogue.
 */

/** PostgREST serialises NUMERIC as a JSON number, but never assume it. */
function num(value: unknown): number {
  if (typeof value === "number") return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function numOrNull(value: unknown): number | null {
  return value === null || value === undefined ? null : num(value);
}

/** Removes the characters that would break a PostgREST `or=` filter expression. */
function sanitizeSearch(term: string): string {
  return term.replace(/[,()*\\%]/g, " ").trim();
}

export async function loadCatalogContext() {
  const tenant = await requireTenant();
  const supabase = await createClient();
  return {
    supabase,
    tenant,
    businessId: tenant.active.business_id,
    role: tenant.active.role,
    caps: catalogCaps(tenant.active.role),
  };
}

export type CatalogContext = Awaited<ReturnType<typeof loadCatalogContext>>;

export async function listCategories(): Promise<NamedRef[]> {
  const { supabase, businessId } = await loadCatalogContext();
  const { data, error } = await supabase
    .from("categories")
    .select("id, name")
    .eq("business_id", businessId)
    .eq("is_active", true)
    .order("sort_order", { ascending: true })
    .order("name", { ascending: true });

  if (error) throw new Error(`Kategoriler okunamadı: ${error.message}`);
  return (data ?? []).map((row) => ({ id: row.id as string, name: row.name as string }));
}

export async function listBrands(): Promise<NamedRef[]> {
  const { supabase, businessId } = await loadCatalogContext();
  const { data, error } = await supabase
    .from("brands")
    .select("id, name")
    .eq("business_id", businessId)
    .eq("is_active", true)
    .order("name", { ascending: true });

  if (error) throw new Error(`Markalar okunamadı: ${error.message}`);
  return (data ?? []).map((row) => ({ id: row.id as string, name: row.name as string }));
}

/** Options and their values exactly as this business defined them — no hard-coded size list. */
export async function listProductOptions(): Promise<ProductOption[]> {
  const { supabase, businessId } = await loadCatalogContext();

  const [{ data: optionRows, error: optionError }, { data: valueRows, error: valueError }] =
    await Promise.all([
      supabase
        .from("product_options")
        .select("id, name, sort_order")
        .eq("business_id", businessId)
        .order("sort_order", { ascending: true })
        .order("name", { ascending: true }),
      supabase
        .from("option_values")
        .select("id, product_option_id, value, sort_order")
        .eq("business_id", businessId)
        .order("sort_order", { ascending: true })
        .order("value", { ascending: true }),
    ]);

  if (optionError) throw new Error(`Seçenekler okunamadı: ${optionError.message}`);
  if (valueError) throw new Error(`Seçenek değerleri okunamadı: ${valueError.message}`);

  return (optionRows ?? []).map((option) => ({
    id: option.id as string,
    name: option.name as string,
    sort_order: option.sort_order as number,
    values: (valueRows ?? [])
      .filter((value) => value.product_option_id === option.id)
      .map((value) => ({
        id: value.id as string,
        value: value.value as string,
        sort_order: value.sort_order as number,
      })),
  }));
}

/** Raw shapes returned by PostgREST for the two variant child tables. */
type VariantOptionRow = { variant_id: string; product_option_id: string; option_value_id: string };
type BarcodeRow = {
  id: string;
  variant_id: string;
  barcode: string;
  barcode_type: "internal" | "supplier";
  symbology: string;
  is_primary: boolean;
};

export async function listProducts(filters: ProductFilters): Promise<ProductListRow[]> {
  const { supabase, businessId } = await loadCatalogContext();

  let query = supabase
    .from("products")
    .select("id, name, sku_prefix, status, default_sale_price, category_id, brand_id")
    .eq("business_id", businessId);

  const search = sanitizeSearch(filters.search ?? "");
  if (search) query = query.or(`name.ilike.%${search}%,sku_prefix.ilike.%${search}%`);
  if (filters.categoryId) query = query.eq("category_id", filters.categoryId);
  if (filters.brandId) query = query.eq("brand_id", filters.brandId);
  if (filters.status) query = query.eq("status", filters.status);

  const { data: productRows, error } = await query.order("name", { ascending: true }).limit(200);
  if (error) throw new Error(`Ürünler okunamadı: ${error.message}`);

  const products = productRows ?? [];
  if (products.length === 0) return [];

  const productIds = products.map((row) => row.id as string);

  // Variant counts are aggregated here rather than in SQL: the catalogue has no aggregate
  // RPC and adding one would mean a migration. Adequate at pilot size; revisit past a few
  // thousand products.
  const [{ data: variantRows, error: variantError }, categories, brands] = await Promise.all([
    supabase
      .from("product_variants")
      .select("id, product_id, sale_price_override, status")
      .eq("business_id", businessId)
      .in("product_id", productIds),
    listCategories(),
    listBrands(),
  ]);

  if (variantError) throw new Error(`Varyantlar okunamadı: ${variantError.message}`);

  return products.map((row) => {
    const id = row.id as string;
    const defaultPrice = num(row.default_sale_price);
    const own = (variantRows ?? []).filter((variant) => variant.product_id === id);
    const prices = own
      .filter((variant) => variant.status === "active")
      .map((variant) =>
        variant.sale_price_override === null ? defaultPrice : num(variant.sale_price_override),
      );

    return {
      id,
      name: row.name as string,
      sku_prefix: row.sku_prefix as string,
      status: row.status as ProductStatus,
      default_sale_price: defaultPrice,
      category: categories.find((c) => c.id === row.category_id) ?? null,
      brand: brands.find((b) => b.id === row.brand_id) ?? null,
      variant_count: own.length,
      price_min: prices.length > 0 ? Math.min(...prices) : null,
      price_max: prices.length > 0 ? Math.max(...prices) : null,
    };
  });
}

export async function getProduct(productId: string): Promise<ProductDetail | null> {
  const { supabase, businessId } = await loadCatalogContext();

  const { data: product, error } = await supabase
    .from("products")
    .select(
      "id, name, sku_prefix, status, default_sale_price, tax_rate, is_tax_inclusive, collection, description, category_id, brand_id",
    )
    .eq("business_id", businessId)
    .eq("id", productId)
    .maybeSingle();

  if (error) throw new Error(`Ürün okunamadı: ${error.message}`);
  if (!product) return null;

  const { data: variantRows, error: variantError } = await supabase
    .from("product_variants")
    .select("id, sku, status, sale_price_override")
    .eq("business_id", businessId)
    .eq("product_id", productId)
    .order("sku", { ascending: true });

  if (variantError) throw new Error(`Varyantlar okunamadı: ${variantError.message}`);

  const variantIds = (variantRows ?? []).map((row) => row.id as string);

  // Declared as concrete row shapes so the empty-variant case does not produce a union
  // of array types that TypeScript refuses to call .filter() on.
  let vovRows: VariantOptionRow[] = [];
  let barcodeRows: BarcodeRow[] = [];

  if (variantIds.length > 0) {
    const [vovResult, barcodeResult] = await Promise.all([
      supabase
        .from("variant_option_values")
        .select("variant_id, product_option_id, option_value_id")
        .eq("business_id", businessId)
        .in("variant_id", variantIds),
      supabase
        .from("barcodes")
        .select("id, variant_id, barcode, barcode_type, symbology, is_primary")
        .eq("business_id", businessId)
        .in("variant_id", variantIds)
        .order("is_primary", { ascending: false })
        .order("barcode", { ascending: true }),
    ]);

    if (vovResult.error) throw new Error(`Varyant seçenekleri okunamadı: ${vovResult.error.message}`);
    if (barcodeResult.error) throw new Error(`Barkodlar okunamadı: ${barcodeResult.error.message}`);

    vovRows = (vovResult.data ?? []) as VariantOptionRow[];
    barcodeRows = (barcodeResult.data ?? []) as BarcodeRow[];
  }

  const [options, categories, brands] = await Promise.all([
    listProductOptions(),
    listCategories(),
    listBrands(),
  ]);

  const variants: VariantRow[] = (variantRows ?? []).map((row) => {
    const variantId = row.id as string;
    return {
      id: variantId,
      sku: row.sku as string,
      status: row.status as VariantStatus,
      sale_price_override: numOrNull(row.sale_price_override),
      options: vovRows
        .filter((vov) => vov.variant_id === variantId)
        .map((vov) => {
          const option = options.find((o) => o.id === vov.product_option_id);
          const value = option?.values.find((v) => v.id === vov.option_value_id);
          return {
            option_id: vov.product_option_id,
            option_name: option?.name ?? "—",
            value_id: vov.option_value_id,
            value: value?.value ?? "—",
          };
        })
        .sort((a, b) => a.option_name.localeCompare(b.option_name, "tr")),
      barcodes: barcodeRows
        .filter((barcode) => barcode.variant_id === variantId)
        .map((barcode) => ({
          id: barcode.id,
          barcode: barcode.barcode,
          barcode_type: barcode.barcode_type,
          symbology: barcode.symbology,
          is_primary: barcode.is_primary,
        })),
    };
  });

  return {
    id: product.id as string,
    name: product.name as string,
    sku_prefix: product.sku_prefix as string,
    status: product.status as ProductStatus,
    default_sale_price: num(product.default_sale_price),
    tax_rate: num(product.tax_rate),
    is_tax_inclusive: product.is_tax_inclusive as boolean,
    collection: (product.collection as string | null) ?? null,
    description: (product.description as string | null) ?? null,
    category_id: (product.category_id as string | null) ?? null,
    brand_id: (product.brand_id as string | null) ?? null,
    category: categories.find((c) => c.id === product.category_id) ?? null,
    brand: brands.find((b) => b.id === product.brand_id) ?? null,
    variants,
  };
}
