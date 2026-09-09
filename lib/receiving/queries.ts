import "server-only";

import { loadAppContext } from "@/lib/app-context";
import {
  CURRENCIES,
  receivingCaps,
  type Currency,
  type PickableVariant,
  type ReceiptDetail,
  type ReceiptLine,
  type ReceiptListRow,
  type ReceiptStatus,
  type Supplier,
  type SupplierStatus,
} from "@/lib/receiving/model";

/**
 * Read side of receiving.
 *
 * Every query is additionally filtered by business_id even though RLS already scopes it.
 * Cost columns appear only where the contract allows them: goods_receipt_items.unit_cost
 * and the post-time snapshots, which pol_gri_select opens to procurement roles.
 * variant_cost_pools and inventory_movement_costs are never touched here.
 */

/** Explicit page ceilings — kept in the query layer so no component invents its own. */
export const SUPPLIER_LIST_LIMIT = 200;
export const RECEIPT_LIST_LIMIT = 100;
export const RECEIPT_LINE_LIMIT = 500;
export const VARIANT_PICKER_LIMIT = 60;

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
function sanitize(term: string): string {
  return term.replace(/[,()*\\%]/g, " ").trim();
}

export async function loadReceivingContext() {
  const ctx = await loadAppContext();
  return { ...ctx, caps: receivingCaps(ctx.role) };
}

// ------------------------------------------------------------------ suppliers

export type SupplierFilters = { search?: string; status?: SupplierStatus };

export async function listSuppliers(filters: SupplierFilters = {}): Promise<Supplier[]> {
  const { supabase, businessId } = await loadReceivingContext();

  let query = supabase
    .from("suppliers")
    .select("id, name, code, currency, status, contact_name, phone, email, city, country, notes")
    .eq("business_id", businessId);

  const search = sanitize(filters.search ?? "");
  if (search) query = query.or(`name.ilike.%${search}%,code.ilike.%${search}%`);
  if (filters.status) query = query.eq("status", filters.status);

  const { data, error } = await query.order("name", { ascending: true }).limit(SUPPLIER_LIST_LIMIT);
  if (error) throw new Error(`Tedarikçiler okunamadı: ${error.message}`);

  return (data ?? []).map((row) => ({
    id: row.id as string,
    name: row.name as string,
    code: (row.code as string | null) ?? null,
    currency: row.currency as Currency,
    status: row.status as SupplierStatus,
    contact_name: (row.contact_name as string | null) ?? null,
    phone: (row.phone as string | null) ?? null,
    email: (row.email as string | null) ?? null,
    city: (row.city as string | null) ?? null,
    country: row.country as string,
    notes: (row.notes as string | null) ?? null,
  }));
}

/** Active branches of the tenant — the receipt header needs a real branch id. */
export async function listBranches(): Promise<Array<{ id: string; name: string; code: string }>> {
  const { supabase, businessId } = await loadReceivingContext();
  const { data, error } = await supabase
    .from("branches")
    .select("id, name, code")
    .eq("business_id", businessId)
    .eq("status", "active")
    .order("is_default", { ascending: false })
    .order("name", { ascending: true });

  if (error) throw new Error(`Şubeler okunamadı: ${error.message}`);
  return (data ?? []).map((row) => ({
    id: row.id as string,
    name: row.name as string,
    code: row.code as string,
  }));
}

// ------------------------------------------------------------------ receipts

export type ReceiptFilters = {
  status?: ReceiptStatus;
  supplierId?: string;
  from?: string;
  to?: string;
  search?: string;
};

export async function listReceipts(filters: ReceiptFilters = {}): Promise<ReceiptListRow[]> {
  const { supabase, businessId } = await loadReceivingContext();

  let query = supabase
    .from("goods_receipts")
    .select(
      "id, receipt_number, received_at, status, invoice_currency, exchange_rate, document_ref, supplier_id, branch_id, posted_at, created_at",
    )
    .eq("business_id", businessId);

  if (filters.status) query = query.eq("status", filters.status);
  if (filters.supplierId) query = query.eq("supplier_id", filters.supplierId);
  if (filters.from) query = query.gte("received_at", filters.from);
  if (filters.to) query = query.lte("received_at", filters.to);

  const search = sanitize(filters.search ?? "");
  if (search) query = query.or(`receipt_number.ilike.%${search}%,document_ref.ilike.%${search}%`);

  const { data: receiptRows, error } = await query
    .order("received_at", { ascending: false })
    .order("receipt_number", { ascending: false })
    .limit(RECEIPT_LIST_LIMIT);

  if (error) throw new Error(`Mal kabul belgeleri okunamadı: ${error.message}`);

  const receipts = receiptRows ?? [];
  if (receipts.length === 0) return [];

  const ids = receipts.map((row) => row.id as string);

  // Totals are summed here: the schema has no aggregate view for receipts and adding one
  // would mean a migration. Bounded by RECEIPT_LIST_LIMIT above.
  const [{ data: lineRows, error: lineError }, suppliers, branches] = await Promise.all([
    supabase
      .from("goods_receipt_items")
      .select("goods_receipt_id, quantity, unit_cost")
      .eq("business_id", businessId)
      .in("goods_receipt_id", ids),
    listSuppliers(),
    listBranches(),
  ]);

  if (lineError) throw new Error(`Belge satırları okunamadı: ${lineError.message}`);

  return receipts.map((row) => {
    const id = row.id as string;
    const own = (lineRows ?? []).filter((line) => line.goods_receipt_id === id);
    return {
      id,
      receipt_number: row.receipt_number as string,
      received_at: row.received_at as string,
      status: row.status as ReceiptStatus,
      invoice_currency: row.invoice_currency as Currency,
      exchange_rate: num(row.exchange_rate),
      document_ref: (row.document_ref as string | null) ?? null,
      supplier_name: suppliers.find((s) => s.id === row.supplier_id)?.name ?? "—",
      branch_name: branches.find((b) => b.id === row.branch_id)?.name ?? "—",
      line_count: own.length,
      total_quantity: own.reduce((sum, line) => sum + num(line.quantity), 0),
      total_original: own.reduce((sum, line) => sum + num(line.quantity) * num(line.unit_cost), 0),
      posted_at: (row.posted_at as string | null) ?? null,
      created_at: row.created_at as string,
    };
  });
}

type VariantMeta = {
  variant_id: string;
  product_id: string;
  product_name: string;
  sku: string;
  options: string;
  primary_barcode: string | null;
};

/** Resolves display metadata (product, option combination, primary barcode) for variants. */
async function loadVariantMeta(variantIds: string[]): Promise<Map<string, VariantMeta>> {
  const out = new Map<string, VariantMeta>();
  if (variantIds.length === 0) return out;

  const { supabase, businessId } = await loadReceivingContext();

  const { data: variantRows, error: variantError } = await supabase
    .from("product_variants")
    .select("id, product_id, sku")
    .eq("business_id", businessId)
    .in("id", variantIds);
  if (variantError) throw new Error(`Varyantlar okunamadı: ${variantError.message}`);

  const variants = variantRows ?? [];
  const productIds = Array.from(new Set(variants.map((v) => v.product_id as string)));

  const [productResult, vovResult, valueResult, optionResult, barcodeResult] = await Promise.all([
    supabase.from("products").select("id, name").eq("business_id", businessId).in("id", productIds),
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
  ]);

  for (const r of [productResult, vovResult, valueResult, optionResult, barcodeResult]) {
    if (r.error) throw new Error(`Varyant bilgisi okunamadı: ${r.error.message}`);
  }

  const products = productResult.data ?? [];
  const vov = vovResult.data ?? [];
  const values = valueResult.data ?? [];
  const options = optionResult.data ?? [];
  const barcodes = barcodeResult.data ?? [];

  for (const variant of variants) {
    const variantId = variant.id as string;
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

    out.set(variantId, {
      variant_id: variantId,
      product_id: variant.product_id as string,
      product_name: (products.find((p) => p.id === variant.product_id)?.name as string) ?? "—",
      sku: variant.sku as string,
      options: pairs.length > 0 ? pairs.map((p) => p.text).join(" · ") : "Seçeneksiz",
      primary_barcode: (barcodes.find((b) => b.variant_id === variantId)?.barcode as string) ?? null,
    });
  }

  return out;
}

export async function getReceipt(receiptId: string): Promise<ReceiptDetail | null> {
  const { supabase, businessId } = await loadReceivingContext();

  const { data: receipt, error } = await supabase
    .from("goods_receipts")
    .select(
      "id, receipt_number, received_at, status, invoice_currency, exchange_rate, document_ref, note, supplier_id, branch_id, posted_at, created_at",
    )
    .eq("business_id", businessId)
    .eq("id", receiptId)
    .maybeSingle();

  if (error) throw new Error(`Belge okunamadı: ${error.message}`);
  if (!receipt) return null;

  const { data: itemRows, error: itemError } = await supabase
    .from("goods_receipt_items")
    .select("id, variant_id, quantity, unit_cost, fx_rate_snapshot, unit_cost_base, total_cost_base")
    .eq("business_id", businessId)
    .eq("goods_receipt_id", receiptId)
    .limit(RECEIPT_LINE_LIMIT);

  if (itemError) throw new Error(`Belge satırları okunamadı: ${itemError.message}`);

  const items = itemRows ?? [];
  const meta = await loadVariantMeta(items.map((row) => row.variant_id as string));

  const [suppliers, branches] = await Promise.all([listSuppliers(), listBranches()]);

  const lines: ReceiptLine[] = items
    .map((row) => {
      const variantId = row.variant_id as string;
      const info = meta.get(variantId);
      return {
        id: row.id as string,
        variant_id: variantId,
        product_name: info?.product_name ?? "—",
        sku: info?.sku ?? "—",
        options: info?.options ?? "—",
        primary_barcode: info?.primary_barcode ?? null,
        quantity: num(row.quantity),
        unit_cost: num(row.unit_cost),
        fx_rate_snapshot: numOrNull(row.fx_rate_snapshot),
        unit_cost_base: numOrNull(row.unit_cost_base),
        total_cost_base: numOrNull(row.total_cost_base),
      };
    })
    .sort((a, b) => a.product_name.localeCompare(b.product_name, "tr") || a.sku.localeCompare(b.sku, "tr"));

  return {
    id: receipt.id as string,
    receipt_number: receipt.receipt_number as string,
    received_at: receipt.received_at as string,
    status: receipt.status as ReceiptStatus,
    invoice_currency: receipt.invoice_currency as Currency,
    exchange_rate: num(receipt.exchange_rate),
    document_ref: (receipt.document_ref as string | null) ?? null,
    note: (receipt.note as string | null) ?? null,
    supplier_id: receipt.supplier_id as string,
    supplier_name: suppliers.find((s) => s.id === receipt.supplier_id)?.name ?? "—",
    branch_id: receipt.branch_id as string,
    branch_name: branches.find((b) => b.id === receipt.branch_id)?.name ?? "—",
    posted_at: (receipt.posted_at as string | null) ?? null,
    created_at: receipt.created_at as string,
    lines,
  };
}

// ------------------------------------------------------------------ variant picker

/**
 * Finds variants by product name, SKU or barcode. A product-name hit returns every active
 * variant of that product, so a whole S/M/L run can be entered in one pass.
 */
export async function searchVariants(term: string): Promise<PickableVariant[]> {
  const search = sanitize(term);
  if (search.length < 2) return [];

  const { supabase, businessId } = await loadReceivingContext();

  const [barcodeResult, skuResult, productResult] = await Promise.all([
    supabase
      .from("barcodes")
      .select("variant_id")
      .eq("business_id", businessId)
      .ilike("barcode", `%${search}%`)
      .limit(VARIANT_PICKER_LIMIT),
    supabase
      .from("product_variants")
      .select("id")
      .eq("business_id", businessId)
      .eq("status", "active")
      .ilike("sku", `%${search}%`)
      .limit(VARIANT_PICKER_LIMIT),
    supabase
      .from("products")
      .select("id")
      .eq("business_id", businessId)
      .ilike("name", `%${search}%`)
      .limit(VARIANT_PICKER_LIMIT),
  ]);

  for (const r of [barcodeResult, skuResult, productResult]) {
    if (r.error) throw new Error(`Varyant araması başarısız: ${r.error.message}`);
  }

  const ids = new Set<string>();
  for (const row of barcodeResult.data ?? []) ids.add(row.variant_id as string);
  for (const row of skuResult.data ?? []) ids.add(row.id as string);

  const productIds = (productResult.data ?? []).map((row) => row.id as string);
  if (productIds.length > 0) {
    const { data: siblings, error: siblingError } = await supabase
      .from("product_variants")
      .select("id")
      .eq("business_id", businessId)
      .eq("status", "active")
      .in("product_id", productIds)
      .limit(VARIANT_PICKER_LIMIT);
    if (siblingError) throw new Error(`Varyant araması başarısız: ${siblingError.message}`);
    for (const row of siblings ?? []) ids.add(row.id as string);
  }

  const meta = await loadVariantMeta(Array.from(ids).slice(0, VARIANT_PICKER_LIMIT));

  return Array.from(meta.values()).sort(
    (a, b) => a.product_name.localeCompare(b.product_name, "tr") || a.sku.localeCompare(b.sku, "tr"),
  );
}

// ------------------------------------------------------------------ fx prefill

export type FxHint = { currency: Currency; rate: number | null };

/**
 * Daily rates offered as a prefill for the receipt header.
 *
 * This is a convenience only. goods_receipts.exchange_rate is the authoritative snapshot,
 * and rpc_post_goods_receipt never consults fx_rates — so the UI must present these as a
 * suggestion, never as a guarantee. A missing rate is not an error here; the user types one.
 */
export async function loadFxHints(date: string): Promise<FxHint[]> {
  const { supabase, businessId } = await loadReceivingContext();
  const hints: FxHint[] = [];

  for (const currency of CURRENCIES) {
    if (currency === "TRY") {
      hints.push({ currency, rate: 1 });
      continue;
    }
    const { data, error } = await supabase.rpc("rpc_get_fx_rate", {
      p_business_id: businessId,
      p_currency: currency,
      p_date: date,
    });
    // FX_RATE_MISSING is expected whenever the day has no rate yet.
    const row = Array.isArray(data) ? data[0] : null;
    hints.push({ currency, rate: error || !row ? null : num(row.rate) });
  }

  return hints;
}
