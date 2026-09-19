import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { loadAppContext } from "@/lib/app-context";
import { signImagePaths } from "@/lib/catalog/images";
import type { Bucket } from "@/lib/stock/model";
import { countCaps, type CountCostSource, type CountLine, type CountLineCost, type CountVariant, type StockCount, type StockCountListRow, type StockCountStatus, type StockCountType } from "@/lib/stock/count-model";

/**
 * Read side of stock counts. RLS scopes every table to procurement roles of the tenant;
 * the business_id filter is defence in depth. The only cost read here is the Phase 15B-0
 * bridge table (stock_count_line_costs), and only for owner/manager: other roles never
 * receive the query, and RLS would return nothing to them anyway.
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

  // One read: the variants with their product (name + main image), option pairs (value +
  // kind) and barcodes embedded over the existing foreign keys — then one signing call for
  // the thumbnails. Same RLS-scoped rows as the four sequential reads this replaces.
  const { data: variants, error } = await supabase
    .from("product_variants")
    .select(
      "id, sku, product_id, products(name, product_images(storage_path, url, role)), " +
        "variant_option_values(option_values(value, sort_order), product_options(kind)), barcodes(barcode, is_primary)",
    )
    .eq("business_id", businessId)
    .in("id", ids)
    .eq("products.product_images.role", "product_main");
  if (error) throw new Error(`Varyantlar okunamadı: ${error.message}`);

  type Row = {
    id: string; sku: string; product_id: string;
    products: { name: string; product_images: Array<{ storage_path: string | null; url: string | null; role: string }> | null } | null;
    variant_option_values: Array<{ option_values: { value: string; sort_order: number } | null; product_options: { kind: string } | null }> | null;
    barcodes: Array<{ barcode: string; is_primary: boolean }> | null;
  };
  const rows = (variants ?? []) as unknown as Row[];
  const mainOf = (r: Row) => (r.products?.product_images ?? []).find((i) => i.role === "product_main") ?? null;
  const signed = await signImagePaths(
    supabase,
    rows.map((r) => mainOf(r)?.storage_path ?? null).filter((x): x is string => !!x),
  );

  for (const v of rows) {
    const pairs = (v.variant_option_values ?? [])
      .map((r) => ({ kind: r.product_options?.kind ?? "other", value: r.option_values?.value ?? "—" }))
      .sort((a, b) => rank(a.kind) - rank(b.kind));
    const color = pairs.find((p) => p.kind === "color")?.value ?? null;
    const size = pairs.find((p) => p.kind === "size")?.value ?? null;
    const bcs = v.barcodes ?? [];
    const primary = bcs.find((b) => b.is_primary) ?? bcs[0];
    const main = mainOf(v);
    out.set(v.id, {
      variant_id: v.id,
      product_id: v.product_id,
      product_name: v.products?.name ?? "—",
      sku: v.sku,
      options: pairs.map((p) => p.value).join(" / "),
      color,
      size,
      primary_barcode: primary?.barcode ?? null,
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
  posted_at: string | null; posted_by: string | null; cancelled_at: string | null; cancel_reason: string | null; review_hash: string | null;
};

const HEADER_COLUMNS = "id, count_number, count_type, status, branch_id, note, created_by, created_at, counting_started_at, reviewed_at, posted_at, posted_by, cancelled_at, cancel_reason, review_hash";

type CostRow = { line_id: string; unit_cost_base: number | string; cost_source: CountCostSource; note: string | null; entered_at: string; applied: boolean | null; applied_quantity: number | null; applied_value_base: number | string | null };

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
  const { supabase, businessId, role } = await loadAppContext();
  const managerPlus = countCaps(role).canCost;
  const { data, error } = await supabase
    .from("stock_counts")
    .select(HEADER_COLUMNS)
    .eq("business_id", businessId)
    .eq("id", countId)
    .maybeSingle();
  if (error) throw new Error(`Sayım okunamadı: ${error.message}`);
  if (!data) return null;
  const h = data as unknown as HeaderRow;

  const [{ data: branch }, { data: business }, { data: lineRows, error: lineError }, names, costRows] = await Promise.all([
    supabase.from("branches").select("name").eq("business_id", businessId).eq("id", h.branch_id).maybeSingle(),
    supabase.from("businesses").select("base_currency").eq("id", businessId).maybeSingle(),
    supabase
      .from("stock_count_lines")
      .select("id, variant_id, bucket, expected_quantity, counted_quantity, zero_confirmed, counted_at, posted_delta, cost_required")
      .eq("business_id", businessId)
      .eq("stock_count_id", countId)
      .order("counted_at", { ascending: false, nullsFirst: false }),
    profileNames(supabase, [h.created_by, h.posted_by]),
    // the cost side exists for owner/manager only; nobody else is sent the query
    managerPlus
      ? supabase
          .from("stock_count_line_costs")
          .select("line_id, unit_cost_base, cost_source, note, entered_at, applied, applied_quantity, applied_value_base")
          .eq("business_id", businessId)
          .eq("stock_count_id", countId)
          .then(({ data, error }) => {
            if (error) throw new Error(`Sayım maliyetleri okunamadı: ${error.message}`);
            return (data ?? []) as unknown as CostRow[];
          })
      : Promise.resolve([] as CostRow[]),
  ]);
  if (lineError) throw new Error(`Sayım satırları okunamadı: ${lineError.message}`);

  const costs = new Map<string, CountLineCost>();
  for (const c of costRows) {
    costs.set(c.line_id, {
      unit_cost_base: Number(c.unit_cost_base),
      cost_source: c.cost_source,
      note: c.note ?? null,
      entered_at: c.entered_at,
      applied: c.applied ?? null,
      applied_quantity: num(c.applied_quantity),
      applied_value_base: c.applied_value_base === null ? null : Number(c.applied_value_base),
    });
  }

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
    cost_required: Boolean(r.cost_required),
    cost: managerPlus ? (costs.get(r.id as string) ?? null) : null,
  }));

  return {
    ...h,
    branch_name: (branch?.name as string | undefined) ?? "—",
    base_currency: (business?.base_currency as string | undefined) ?? "TRY",
    created_by_name: h.created_by ? (names.get(h.created_by) ?? null) : null,
    posted_by_name: h.posted_by ? (names.get(h.posted_by) ?? null) : null,
    lines,
  };
}
