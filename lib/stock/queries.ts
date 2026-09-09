import "server-only";

import { loadAppContext } from "@/lib/app-context";
import type { Bucket, MovementReason, MovementRow, StockRow, StockState } from "@/lib/stock/model";

/**
 * Read side of stock visibility.
 *
 * Quantities come only from the two member-readable views — v_stock_by_bucket and
 * v_stock_available — plus the immutable ledger. variant_cost_pools is deliberately never
 * queried: it is manager+ only, and the stock screens must stay operational rather than
 * financial. ON_HAND is aggregated here, in one place, so no component invents its own sum.
 *
 * Nothing in this module writes. Stock is a consequence of the ledger.
 */

/** Explicit ceilings — the list is variant-based, so this bounds the whole screen. */
export const STOCK_LIST_LIMIT = 300;
export const MOVEMENT_LIMIT = 200;

function num(value: unknown): number {
  if (typeof value === "number") return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function sanitize(term: string): string {
  return term.replace(/[,()*\\%]/g, " ").trim();
}

export type StockFilters = {
  search?: string;
  categoryId?: string;
  brandId?: string;
  branchId?: string;
  state?: StockState;
};

type Quantities = { sellable: number; quarantine: number; damaged: number; reserved: number; available: number };

const EMPTY: Quantities = { sellable: 0, quarantine: 0, damaged: 0, reserved: 0, available: 0 };

/**
 * The single aggregation point. Given variant ids and a branch, returns the per-variant
 * quantities from the two views. ON_HAND is the sum of the three buckets — never the cost
 * pool's on_hand_qty, which sales_staff cannot read.
 */
async function loadQuantities(
  variantIds: string[],
  branchId: string,
): Promise<Map<string, Quantities>> {
  const out = new Map<string, Quantities>();
  if (variantIds.length === 0) return out;

  const { supabase, businessId } = await loadAppContext();

  const [bucketResult, availableResult] = await Promise.all([
    supabase
      .from("v_stock_by_bucket")
      .select("variant_id, bucket, quantity")
      .eq("business_id", businessId)
      .eq("branch_id", branchId)
      .in("variant_id", variantIds),
    supabase
      .from("v_stock_available")
      .select("variant_id, sellable_quantity, reserved_quantity, available_quantity")
      .eq("business_id", businessId)
      .eq("branch_id", branchId)
      .in("variant_id", variantIds),
  ]);

  if (bucketResult.error) throw new Error(`Stok okunamadı: ${bucketResult.error.message}`);
  if (availableResult.error) throw new Error(`Uygun stok okunamadı: ${availableResult.error.message}`);

  for (const id of variantIds) out.set(id, { ...EMPTY });

  for (const row of bucketResult.data ?? []) {
    const entry = out.get(row.variant_id as string);
    if (!entry) continue;
    const bucket = row.bucket as Bucket;
    entry[bucket] = num(row.quantity);
  }

  for (const row of availableResult.data ?? []) {
    const entry = out.get(row.variant_id as string);
    if (!entry) continue;
    entry.reserved = num(row.reserved_quantity);
    entry.available = num(row.available_quantity);
  }

  // A variant with no sellable row at all has nothing reserved and nothing available.
  for (const entry of out.values()) {
    if (entry.sellable === 0 && entry.reserved === 0) entry.available = entry.available || 0;
  }

  return out;
}

function onHand(q: Quantities): number {
  return q.sellable + q.quarantine + q.damaged;
}

function matchesState(q: Quantities, state: StockState | undefined): boolean {
  if (!state) return true;
  if (state === "in_stock") return onHand(q) > 0;
  if (state === "out_of_stock") return onHand(q) === 0;
  if (state === "has_quarantine") return q.quarantine > 0;
  return q.damaged > 0;
}

type VariantBase = {
  variant_id: string;
  product_id: string;
  product_name: string;
  sku: string;
  options: string;
  primary_barcode: string | null;
  category_name: string | null;
  brand_name: string | null;
};

/**
 * The list is variant-based rather than ledger-based, so a catalogue variant that has
 * never been received still appears with zeros — which is what makes "tükenmiş" meaningful.
 */
async function loadVariantBase(filters: StockFilters): Promise<VariantBase[]> {
  const { supabase, businessId } = await loadAppContext();

  const search = sanitize(filters.search ?? "");

  // A barcode or SKU search narrows to specific variants; a name search narrows to products.
  let variantIdFilter: string[] | null = null;
  if (search) {
    const [barcodeResult, skuResult] = await Promise.all([
      supabase
        .from("barcodes")
        .select("variant_id")
        .eq("business_id", businessId)
        .ilike("barcode", `%${search}%`)
        .limit(STOCK_LIST_LIMIT),
      supabase
        .from("product_variants")
        .select("id")
        .eq("business_id", businessId)
        .ilike("sku", `%${search}%`)
        .limit(STOCK_LIST_LIMIT),
    ]);
    if (barcodeResult.error) throw new Error(`Barkod araması başarısız: ${barcodeResult.error.message}`);
    if (skuResult.error) throw new Error(`SKU araması başarısız: ${skuResult.error.message}`);

    const ids = new Set<string>();
    for (const row of barcodeResult.data ?? []) ids.add(row.variant_id as string);
    for (const row of skuResult.data ?? []) ids.add(row.id as string);
    variantIdFilter = Array.from(ids);
  }

  let productQuery = supabase
    .from("products")
    .select("id, name, category_id, brand_id")
    .eq("business_id", businessId);
  if (filters.categoryId) productQuery = productQuery.eq("category_id", filters.categoryId);
  if (filters.brandId) productQuery = productQuery.eq("brand_id", filters.brandId);
  if (search) productQuery = productQuery.ilike("name", `%${search}%`);

  const { data: productRows, error: productError } = await productQuery.limit(STOCK_LIST_LIMIT);
  if (productError) throw new Error(`Ürünler okunamadı: ${productError.message}`);
  const products = productRows ?? [];

  let variantQuery = supabase
    .from("product_variants")
    .select("id, product_id, sku")
    .eq("business_id", businessId)
    .eq("status", "active");

  if (search) {
    // Either the variant matched directly, or its product name matched.
    const productIds = products.map((p) => p.id as string);
    const direct = variantIdFilter ?? [];
    if (direct.length === 0 && productIds.length === 0) return [];
    if (direct.length > 0 && productIds.length > 0) {
      const { data: byProduct, error: byProductError } = await supabase
        .from("product_variants")
        .select("id")
        .eq("business_id", businessId)
        .eq("status", "active")
        .in("product_id", productIds)
        .limit(STOCK_LIST_LIMIT);
      if (byProductError) throw new Error(`Varyantlar okunamadı: ${byProductError.message}`);
      const merged = new Set(direct);
      for (const row of byProduct ?? []) merged.add(row.id as string);
      variantQuery = variantQuery.in("id", Array.from(merged).slice(0, STOCK_LIST_LIMIT));
    } else if (direct.length > 0) {
      variantQuery = variantQuery.in("id", direct.slice(0, STOCK_LIST_LIMIT));
    } else {
      variantQuery = variantQuery.in("product_id", productIds);
    }
  } else if (filters.categoryId || filters.brandId) {
    const productIds = products.map((p) => p.id as string);
    if (productIds.length === 0) return [];
    variantQuery = variantQuery.in("product_id", productIds);
  }

  const { data: variantRows, error: variantError } = await variantQuery.limit(STOCK_LIST_LIMIT);
  if (variantError) throw new Error(`Varyantlar okunamadı: ${variantError.message}`);
  const variants = variantRows ?? [];
  if (variants.length === 0) return [];

  const variantIds = variants.map((v) => v.id as string);
  const neededProductIds = Array.from(new Set(variants.map((v) => v.product_id as string)));

  const [productMetaResult, vovResult, valueResult, optionResult, barcodeResult, categoryResult, brandResult] =
    await Promise.all([
      supabase.from("products").select("id, name, category_id, brand_id").eq("business_id", businessId).in("id", neededProductIds),
      supabase
        .from("variant_option_values")
        .select("variant_id, product_option_id, option_value_id")
        .eq("business_id", businessId)
        .in("variant_id", variantIds),
      supabase.from("option_values").select("id, value").eq("business_id", businessId),
      supabase.from("product_options").select("id, name, sort_order").eq("business_id", businessId),
      supabase
        .from("barcodes")
        .select("variant_id, barcode")
        .eq("business_id", businessId)
        .in("variant_id", variantIds)
        .eq("is_primary", true),
      supabase.from("categories").select("id, name").eq("business_id", businessId),
      supabase.from("brands").select("id, name").eq("business_id", businessId),
    ]);

  for (const r of [productMetaResult, vovResult, valueResult, optionResult, barcodeResult, categoryResult, brandResult]) {
    if (r.error) throw new Error(`Stok listesi hazırlanamadı: ${r.error.message}`);
  }

  const productMeta = productMetaResult.data ?? [];
  const vov = vovResult.data ?? [];
  const values = valueResult.data ?? [];
  const options = optionResult.data ?? [];
  const barcodes = barcodeResult.data ?? [];
  const categories = categoryResult.data ?? [];
  const brands = brandResult.data ?? [];

  return variants.map((variant) => {
    const variantId = variant.id as string;
    const product = productMeta.find((p) => p.id === variant.product_id);
    const pairs = vov
      .filter((row) => row.variant_id === variantId)
      .map((row) => {
        const option = options.find((o) => o.id === row.product_option_id);
        const value = values.find((v) => v.id === row.option_value_id);
        return {
          sort: (option?.sort_order as number | undefined) ?? 0,
          text: `${option?.name ?? "—"}: ${value?.value ?? "—"}`,
        };
      })
      .sort((a, b) => a.sort - b.sort);

    return {
      variant_id: variantId,
      product_id: variant.product_id as string,
      product_name: (product?.name as string) ?? "—",
      sku: variant.sku as string,
      options: pairs.length > 0 ? pairs.map((p) => p.text).join(" · ") : "Seçeneksiz",
      primary_barcode: (barcodes.find((b) => b.variant_id === variantId)?.barcode as string) ?? null,
      category_name: (categories.find((c) => c.id === product?.category_id)?.name as string) ?? null,
      brand_name: (brands.find((b) => b.id === product?.brand_id)?.name as string) ?? null,
    };
  });
}

export async function listBranchOptions(): Promise<Array<{ id: string; name: string }>> {
  const { supabase, businessId } = await loadAppContext();
  const { data, error } = await supabase
    .from("branches")
    .select("id, name")
    .eq("business_id", businessId)
    .eq("status", "active")
    .order("is_default", { ascending: false })
    .order("name", { ascending: true });
  if (error) throw new Error(`Şubeler okunamadı: ${error.message}`);
  return (data ?? []).map((row) => ({ id: row.id as string, name: row.name as string }));
}

export async function listStock(filters: StockFilters = {}): Promise<StockRow[]> {
  const { branchId: contextBranch } = await loadAppContext();
  const branches = await listBranchOptions();
  const branchId = filters.branchId ?? contextBranch ?? branches[0]?.id ?? null;
  if (!branchId) return [];

  const branchName = branches.find((b) => b.id === branchId)?.name ?? "—";
  const base = await loadVariantBase(filters);
  if (base.length === 0) return [];

  const quantities = await loadQuantities(base.map((v) => v.variant_id), branchId);

  return base
    .map((variant) => {
      const q = quantities.get(variant.variant_id) ?? { ...EMPTY };
      return {
        ...variant,
        branch_id: branchId,
        branch_name: branchName,
        sellable: q.sellable,
        quarantine: q.quarantine,
        damaged: q.damaged,
        on_hand: onHand(q),
        reserved: q.reserved,
        available: q.available,
      };
    })
    .filter((row) =>
      matchesState(
        { sellable: row.sellable, quarantine: row.quarantine, damaged: row.damaged, reserved: row.reserved, available: row.available },
        filters.state,
      ),
    )
    .sort((a, b) => a.product_name.localeCompare(b.product_name, "tr") || a.sku.localeCompare(b.sku, "tr"));
}

/** Per-branch quantities for one variant, using the same aggregation as the list. */
export async function getVariantStock(variantId: string): Promise<StockRow[]> {
  const base = await loadVariantBase({});
  const variant = base.find((v) => v.variant_id === variantId);
  const branches = await listBranchOptions();

  if (!variant) return [];

  const rows: StockRow[] = [];
  for (const branch of branches) {
    const quantities = await loadQuantities([variantId], branch.id);
    const q = quantities.get(variantId) ?? { ...EMPTY };
    rows.push({
      ...variant,
      branch_id: branch.id,
      branch_name: branch.name,
      sellable: q.sellable,
      quarantine: q.quarantine,
      damaged: q.damaged,
      on_hand: onHand(q),
      reserved: q.reserved,
      available: q.available,
    });
  }
  return rows;
}

export async function listMovements(variantId: string): Promise<MovementRow[]> {
  const { supabase, businessId } = await loadAppContext();

  // No cost column is selected: inventory_movement_costs is manager+ and out of scope here.
  const { data, error } = await supabase
    .from("inventory_movements")
    .select("id, occurred_at, created_at, quantity, bucket, reason, reference_type, reference_id, note")
    .eq("business_id", businessId)
    .eq("variant_id", variantId)
    .order("occurred_at", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(MOVEMENT_LIMIT);

  if (error) throw new Error(`Stok hareketleri okunamadı: ${error.message}`);

  const movements = data ?? [];
  const receiptItemIds = movements
    .filter((row) => row.reference_type === "goods_receipt_item")
    .map((row) => row.reference_id as string);

  const receiptByItem = new Map<string, { id: string; number: string }>();
  if (receiptItemIds.length > 0) {
    const { data: itemRows, error: itemError } = await supabase
      .from("goods_receipt_items")
      .select("id, goods_receipt_id")
      .eq("business_id", businessId)
      .in("id", receiptItemIds);

    // A sales_staff user cannot read goods_receipt_items; the link is simply omitted then.
    if (!itemError && itemRows && itemRows.length > 0) {
      const receiptIds = Array.from(new Set(itemRows.map((row) => row.goods_receipt_id as string)));
      const { data: receiptRows } = await supabase
        .from("goods_receipts")
        .select("id, receipt_number")
        .eq("business_id", businessId)
        .in("id", receiptIds);

      for (const item of itemRows) {
        const receipt = (receiptRows ?? []).find((r) => r.id === item.goods_receipt_id);
        if (receipt) {
          receiptByItem.set(item.id as string, {
            id: receipt.id as string,
            number: receipt.receipt_number as string,
          });
        }
      }
    }
  }

  return movements.map((row) => {
    const link = receiptByItem.get(row.reference_id as string);
    return {
      id: row.id as string,
      occurred_at: row.occurred_at as string,
      created_at: row.created_at as string,
      quantity: num(row.quantity),
      bucket: row.bucket as Bucket,
      reason: row.reason as MovementReason,
      reference_type: row.reference_type as string,
      reference_id: row.reference_id as string,
      note: (row.note as string | null) ?? null,
      receipt_id: link?.id ?? null,
      receipt_number: link?.number ?? null,
    };
  });
}
