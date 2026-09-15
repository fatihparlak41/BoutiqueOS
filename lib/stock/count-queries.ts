import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { loadAppContext } from "@/lib/app-context";
import { signImagePaths } from "@/lib/catalog/images";
import type { Bucket } from "@/lib/stock/model";
import type { CountLine, CountVariant, StockCount, StockCountListRow, StockCountStatus, StockCountType } from "@/lib/stock/count-model";

/**
 * Read side of stock counts. RLS scopes every table to procurement roles of the tenant;
 * the business_id filter is defence in depth. No cost column is read anywhere here —
 * inventory_movement_costs is manager+ and belongs to the ledger, not to the count.
 */

function num(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? n : null;
}

async function profileNames(supabase: SupabaseClient, ids: Array<string | null>): Promise<Map<string, string | null>> {
  const out = new Map<string, string | null>();
  const wanted = [...new Set(ids.filter((x): x is string => !!x))];
  if (wanted.length === 0) return out;
  // Profiles of other members may be hidden by RLS; a missing name is shown as "—".
  const { data } = await supabase.from("profiles").select("id, full_name").in("id", wanted);
  for (const r of data ?? []) out.set(r.id as string, (r.full_name as string | null) ?? null);
  return out;
}

/** Product name, colour/size, barcode and thumbnail for a set of variants — one round trip per table. */
export async function describeVariants(variantIds: string[]): Promise<Map<string, CountVariant>> {
  const out = new Map<string, CountVariant>();
  const ids = [...new Set(variantIds)];
  if (ids.length === 0) return out;
  const { supabase, businessId } = await loadAppContext();

  const { data: variants, error } = await supabase
    .from("product_variants")
    .select("id, sku, product_id")
    .eq("business_id", businessId)
    .in("id", ids);
  if (error) throw new Error(`Varyantlar okunamadı: ${error.message}`);
  const productIds = [...new Set((variants ?? []).map((v) => v.product_id as string))];

  const [{ data: products }, { data: vov }, { data: barcodes }, { data: images }] = await Promise.all([
    supabase.from("products").select("id, name").eq("business_id", businessId).in("id", productIds),
    supabase
      .from("variant_option_values")
      .select("variant_id, product_option_id, option_value_id")
      .eq("business_id", businessId)
      .in("variant_id", ids),
    supabase.from("barcodes").select("variant_id, barcode, is_primary").eq("business_id", businessId).in("variant_id", ids),
    supabase
      .from("product_images")
      .select("product_id, storage_path, url")
      .eq("business_id", businessId)
      .eq("role", "product_main")
      .in("product_id", productIds),
  ]);

  const valueIds = [...new Set((vov ?? []).map((r) => r.option_value_id as string))];
  const optionIds = [...new Set((vov ?? []).map((r) => r.product_option_id as string))];
  const [{ data: values }, { data: options }] = await Promise.all([
    valueIds.length > 0 ? supabase.from("option_values").select("id, value, sort_order").in("id", valueIds) : Promise.resolve({ data: [] as Array<Record<string, unknown>> }),
    optionIds.length > 0 ? supabase.from("product_options").select("id, kind").in("id", optionIds) : Promise.resolve({ data: [] as Array<Record<string, unknown>> }),
  ]);
  const valueById = new Map((values ?? []).map((v) => [v.id as string, v.value as string]));
  const kindById = new Map((options ?? []).map((o) => [o.id as string, o.kind as string]));

  const mains = (images ?? []) as Array<{ product_id: string; storage_path: string | null; url: string | null }>;
  const signed = await signImagePaths(supabase, mains.map((m) => m.storage_path).filter((x): x is string => !!x));

  for (const v of variants ?? []) {
    const vid = v.id as string;
    const pairs = (vov ?? [])
      .filter((r) => r.variant_id === vid)
      .map((r) => ({ kind: kindById.get(r.product_option_id as string) ?? "other", value: valueById.get(r.option_value_id as string) ?? "—" }))
      .sort((a, b) => rank(a.kind) - rank(b.kind));
    const color = pairs.find((p) => p.kind === "color")?.value ?? null;
    const size = pairs.find((p) => p.kind === "size")?.value ?? null;
    const bcs = (barcodes ?? []).filter((b) => b.variant_id === vid);
    const primary = bcs.find((b) => b.is_primary) ?? bcs[0];
    const main = mains.find((m) => m.product_id === v.product_id);
    out.set(vid, {
      variant_id: vid,
      product_id: v.product_id as string,
      product_name: ((products ?? []).find((p) => p.id === v.product_id)?.name as string | undefined) ?? "—",
      sku: v.sku as string,
      options: pairs.map((p) => p.value).join(" / "),
      color,
      size,
      primary_barcode: (primary?.barcode as string | undefined) ?? null,
      thumbnail_url: main ? (main.storage_path ? (signed.get(main.storage_path) ?? null) : main.url) : null,
    });
  }
  return out;
}

function rank(kind: string): number {
  return kind === "color" ? 0 : kind === "size" ? 1 : 2;
}

type HeaderRow = {
  id: string; count_number: string; count_type: StockCountType; status: StockCountStatus; branch_id: string; note: string | null;
  created_by: string | null; created_at: string; counting_started_at: string | null; reviewed_at: string | null;
  posted_at: string | null; posted_by: string | null; cancelled_at: string | null; cancel_reason: string | null;
};

const HEADER_COLUMNS = "id, count_number, count_type, status, branch_id, note, created_by, created_at, counting_started_at, reviewed_at, posted_at, posted_by, cancelled_at, cancel_reason";

export async function listStockCounts(): Promise<StockCountListRow[]> {
  const { supabase, businessId } = await loadAppContext();
  const { data, error } = await supabase
    .from("stock_counts")
    .select(HEADER_COLUMNS)
    .eq("business_id", businessId)
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) throw new Error(`Sayımlar okunamadı: ${error.message}`);
  const headers = (data ?? []) as unknown as HeaderRow[];
  if (headers.length === 0) return [];

  const ids = headers.map((h) => h.id);
  const [{ data: branches }, { data: lines }, names] = await Promise.all([
    supabase.from("branches").select("id, name").eq("business_id", businessId),
    supabase.from("stock_count_lines").select("stock_count_id, counted_quantity").eq("business_id", businessId).in("stock_count_id", ids),
    profileNames(supabase, headers.flatMap((h) => [h.created_by, h.posted_by])),
  ]);

  return headers.map((h) => {
    const own = (lines ?? []).filter((l) => l.stock_count_id === h.id);
    return {
      ...h,
      branch_name: ((branches ?? []).find((b) => b.id === h.branch_id)?.name as string | undefined) ?? "—",
      created_by_name: h.created_by ? (names.get(h.created_by) ?? null) : null,
      posted_by_name: h.posted_by ? (names.get(h.posted_by) ?? null) : null,
      line_count: own.length,
      counted_lines: own.filter((l) => l.counted_quantity !== null).length,
    };
  });
}

export async function getStockCount(countId: string): Promise<StockCount | null> {
  const { supabase, businessId } = await loadAppContext();
  const { data, error } = await supabase
    .from("stock_counts")
    .select(HEADER_COLUMNS)
    .eq("business_id", businessId)
    .eq("id", countId)
    .maybeSingle();
  if (error) throw new Error(`Sayım okunamadı: ${error.message}`);
  if (!data) return null;
  const h = data as unknown as HeaderRow;

  const [{ data: branch }, { data: lineRows, error: lineError }, names] = await Promise.all([
    supabase.from("branches").select("name").eq("business_id", businessId).eq("id", h.branch_id).maybeSingle(),
    supabase
      .from("stock_count_lines")
      .select("id, variant_id, bucket, expected_quantity, counted_quantity, zero_confirmed, counted_at, posted_delta")
      .eq("business_id", businessId)
      .eq("stock_count_id", countId)
      .order("counted_at", { ascending: false, nullsFirst: false }),
    profileNames(supabase, [h.created_by, h.posted_by]),
  ]);
  if (lineError) throw new Error(`Sayım satırları okunamadı: ${lineError.message}`);

  const rows = lineRows ?? [];
  const described = await describeVariants(rows.map((r) => r.variant_id as string));
  const lines: CountLine[] = rows.map((r) => ({
    ...(described.get(r.variant_id as string) ?? {
      variant_id: r.variant_id as string, product_id: "", product_name: "—", sku: "—", options: "", color: null, size: null, primary_barcode: null, thumbnail_url: null,
    }),
    id: r.id as string,
    bucket: r.bucket as Bucket,
    expected_quantity: num(r.expected_quantity),
    counted_quantity: num(r.counted_quantity),
    zero_confirmed: Boolean(r.zero_confirmed),
    counted_at: (r.counted_at as string | null) ?? null,
    posted_delta: num(r.posted_delta),
  }));

  return {
    ...h,
    branch_name: (branch?.name as string | undefined) ?? "—",
    created_by_name: h.created_by ? (names.get(h.created_by) ?? null) : null,
    posted_by_name: h.posted_by ? (names.get(h.posted_by) ?? null) : null,
    lines,
  };
}
