"use server";

import { revalidatePath } from "next/cache";
import { loadAppContext } from "@/lib/app-context";
import { reportDbError } from "@/lib/db-errors";
import { resolveBarcode } from "@/lib/catalog/queries";
import { listStock } from "@/lib/stock/queries";
import { describeVariants } from "@/lib/stock/count-queries";
import { countCaps, type CountCostSource, type CountLine, type CountVariant, type PostSummary, type StockCountType } from "@/lib/stock/count-model";
import type { Bucket } from "@/lib/stock/model";
import type { Result } from "@/lib/catalog/intake";

/**
 * Write side of stock counts. Every write is one RPC; the RPCs prove membership, role,
 * business status, branch and document state themselves. business_id comes from the
 * session (requireTenant), never from the client. The only path that touches the ledger
 * is postAction → rpc_stock_count_post.
 */

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";
const UUID = /^[0-9a-fA-F-]{36}$/;
const BUCKETS: Bucket[] = ["sellable", "quarantine", "damaged"];

function fail<T>(error: string): Result<T> {
  return { ok: false, error };
}

/** Event envelope the client sends with every counting action (offline-ready fields). */
export type CountEvent = { client_tx: string; device_id?: string | null; client_at?: string | null };

function eventArgs(ev: CountEvent) {
  if (!UUID.test(ev.client_tx)) throw new Error("INVALID_EVENT");
  return {
    p_client_tx: ev.client_tx,
    p_device_id: ev.device_id ? ev.device_id.slice(0, 120) : null,
    p_client_at: ev.client_at ?? null,
  };
}

type LineRow = { id: string; variant_id: string; bucket: Bucket; expected_quantity: number | null; counted_quantity: number | null; zero_confirmed: boolean; counted_at: string | null; posted_delta: number | null; cost_required?: boolean | null };

async function toLine(row: LineRow): Promise<CountLine> {
  const d = (await describeVariants([row.variant_id])).get(row.variant_id);
  return {
    ...(d ?? { variant_id: row.variant_id, product_id: "", product_name: "—", sku: "—", options: "", color: null, size: null, primary_barcode: null, thumbnail_url: null }),
    id: row.id,
    bucket: row.bucket,
    expected_quantity: row.expected_quantity,
    counted_quantity: row.counted_quantity,
    zero_confirmed: row.zero_confirmed,
    counted_at: row.counted_at,
    posted_delta: row.posted_delta,
    cost_required: Boolean(row.cost_required),
    cost: null,
  };
}

// ------------------------------------------------------------------ lifecycle

export async function createCountAction(input: { branch_id: string; count_type: StockCountType; note: string }): Promise<Result<string>> {
  const { supabase, businessId, role } = await loadAppContext();
  if (!countCaps(role).canCount) return fail(NO_PERMISSION);
  if (!UUID.test(input.branch_id)) return fail("Şube seçin.");
  const type: StockCountType = input.count_type === "cycle" ? "cycle" : "full";

  const { data, error } = await supabase.rpc("rpc_stock_count_create", {
    p_business_id: businessId,
    p_branch_id: input.branch_id,
    p_count_type: type,
    p_note: input.note.trim() || null,
  });
  if (error) return fail(reportDbError("stockCountCreate", error));
  revalidatePath("/app/stok/sayim");
  return { ok: true, data: data as string };
}

export async function reviewAction(countId: string): Promise<Result<null>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canCount) return fail(NO_PERMISSION);
  if (!UUID.test(countId)) return fail("Sayım bulunamadı.");
  const { error } = await supabase.rpc("rpc_stock_count_review", { p_count_id: countId });
  if (error) return fail(reportDbError("stockCountReview", error));
  revalidatePath(`/app/stok/sayim/${countId}`);
  revalidatePath("/app/stok/sayim");
  return { ok: true, data: null };
}

export async function reopenAction(countId: string): Promise<Result<null>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canCount) return fail(NO_PERMISSION);
  if (!UUID.test(countId)) return fail("Sayım bulunamadı.");
  const { error } = await supabase.rpc("rpc_stock_count_reopen", { p_count_id: countId });
  if (error) return fail(reportDbError("stockCountReopen", error));
  revalidatePath(`/app/stok/sayim/${countId}`);
  return { ok: true, data: null };
}

export async function cancelAction(countId: string, reason: string): Promise<Result<null>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canPost) return fail(NO_PERMISSION);
  if (!UUID.test(countId)) return fail("Sayım bulunamadı.");
  const { error } = await supabase.rpc("rpc_stock_count_cancel", { p_count_id: countId, p_reason: reason.trim() || null });
  if (error) return fail(reportDbError("stockCountCancel", error));
  revalidatePath(`/app/stok/sayim/${countId}`);
  revalidatePath("/app/stok/sayim");
  return { ok: true, data: null };
}

/**
 * The only ledger write. One RPC, one transaction; a stale snapshot, a document changed
 * since the review the client rendered (review_hash), or a double submit is refused by
 * the database.
 */
export async function postAction(countId: string, reviewHash: string | null = null): Promise<Result<PostSummary>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canPost) return fail(NO_PERMISSION);
  if (!UUID.test(countId)) return fail("Sayım bulunamadı.");
  const { data, error } = await supabase.rpc("rpc_stock_count_post", { p_count_id: countId, p_review_hash: reviewHash && /^[0-9a-f]{32}$/.test(reviewHash) ? reviewHash : null });
  if (error) return fail(reportDbError("stockCountPost", error));
  const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | undefined;
  if (!row) return fail("İşleme sonucu okunamadı.");
  revalidatePath(`/app/stok/sayim/${countId}`);
  revalidatePath("/app/stok/sayim");
  revalidatePath("/app/stok");
  return {
    ok: true,
    data: {
      count_id: String(row.count_id),
      count_number: String(row.count_number),
      lines: Number(row.lines ?? 0),
      adjustments: Number(row.adjustments ?? 0),
      shortage_units: Number(row.shortage_units ?? 0),
      surplus_units: Number(row.surplus_units ?? 0),
    },
  };
}

// ------------------------------------------------------------------ counting

/**
 * A scanned or typed code: exact, tenant-safe resolution (rpc_resolve_barcode), then +1
 * on the line for the chosen condition. An unknown code creates nothing.
 */
export async function scanCodeAction(input: { count_id: string; code: string; bucket: Bucket } & CountEvent): Promise<Result<CountLine>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canCount) return fail(NO_PERMISSION);
  if (!UUID.test(input.count_id)) return fail("Sayım bulunamadı.");
  if (!BUCKETS.includes(input.bucket)) return fail("Geçersiz durum.");
  const code = input.code.trim();
  if (code.length < 3 || code.length > 64) return fail("Barkod 3 ile 64 karakter arasında olmalı.");

  let hit;
  try {
    hit = await resolveBarcode(code);
  } catch {
    return fail("Barkod sorgulanamadı. Tekrar deneyin.");
  }
  if (!hit) return fail(`${code} bu işletmede tanınmadı. Ürün oluşturulmadı; etiketi kontrol edin ya da ürünü arayın.`);

  const { data, error } = await supabase.rpc("rpc_stock_count_scan", {
    p_count_id: input.count_id,
    p_variant_id: hit.variant_id,
    p_bucket: input.bucket,
    p_delta: 1,
    ...eventArgs(input),
  });
  if (error) return fail(reportDbError("stockCountScan", error));
  revalidatePath(`/app/stok/sayim/${input.count_id}`);
  return { ok: true, data: await toLine(data as LineRow) };
}

/** +n / −n on a known variant (the +1 button, the undo). */
export async function adjustLineAction(input: { count_id: string; variant_id: string; bucket: Bucket; delta: number } & CountEvent): Promise<Result<CountLine>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canCount) return fail(NO_PERMISSION);
  if (!UUID.test(input.count_id) || !UUID.test(input.variant_id)) return fail("Sayım ya da varyant bulunamadı.");
  if (!BUCKETS.includes(input.bucket)) return fail("Geçersiz durum.");
  if (!Number.isInteger(input.delta) || input.delta === 0 || Math.abs(input.delta) > 999) return fail("Geçersiz miktar.");

  const { data, error } = await supabase.rpc("rpc_stock_count_scan", {
    p_count_id: input.count_id,
    p_variant_id: input.variant_id,
    p_bucket: input.bucket,
    p_delta: input.delta,
    ...eventArgs(input),
  });
  if (error) return fail(reportDbError("stockCountScan", error));
  revalidatePath(`/app/stok/sayim/${input.count_id}`);
  return { ok: true, data: await toLine(data as LineRow) };
}

/** Exact quantity; 0 is the explicit "0 adet olarak doğrula". */
export async function setQuantityAction(input: { count_id: string; variant_id: string; bucket: Bucket; quantity: number } & CountEvent): Promise<Result<CountLine>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canCount) return fail(NO_PERMISSION);
  if (!UUID.test(input.count_id) || !UUID.test(input.variant_id)) return fail("Sayım ya da varyant bulunamadı.");
  if (!BUCKETS.includes(input.bucket)) return fail("Geçersiz durum.");
  if (!Number.isInteger(input.quantity) || input.quantity < 0 || input.quantity > 99999) return fail("Miktar 0 ya da daha büyük bir tam sayı olmalı.");

  const { data, error } = await supabase.rpc("rpc_stock_count_set_quantity", {
    p_count_id: input.count_id,
    p_variant_id: input.variant_id,
    p_bucket: input.bucket,
    p_quantity: input.quantity,
    ...eventArgs(input),
  });
  if (error) return fail(reportDbError("stockCountSet", error));
  revalidatePath(`/app/stok/sayim/${input.count_id}`);
  return { ok: true, data: await toLine(data as LineRow) };
}

/**
 * Resolving a line from the review screen: the count is reopened, the quantity written,
 * and the review snapshot taken again. Three RPCs, each guarded; the ledger is not touched.
 */
export async function resolveFromReviewAction(input: { count_id: string; variant_id: string; bucket: Bucket; quantity: number } & CountEvent): Promise<Result<null>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canCount) return fail(NO_PERMISSION);
  if (!UUID.test(input.count_id) || !UUID.test(input.variant_id)) return fail("Sayım ya da varyant bulunamadı.");
  if (!Number.isInteger(input.quantity) || input.quantity < 0) return fail("Geçersiz miktar.");

  const reopened = await supabase.rpc("rpc_stock_count_reopen", { p_count_id: input.count_id });
  if (reopened.error) return fail(reportDbError("stockCountReopen", reopened.error));
  const set = await supabase.rpc("rpc_stock_count_set_quantity", {
    p_count_id: input.count_id, p_variant_id: input.variant_id, p_bucket: input.bucket, p_quantity: input.quantity, ...eventArgs(input),
  });
  if (set.error) return fail(reportDbError("stockCountSet", set.error));
  const reviewed = await supabase.rpc("rpc_stock_count_review", { p_count_id: input.count_id });
  if (reviewed.error) return fail(reportDbError("stockCountReview", reviewed.error));
  revalidatePath(`/app/stok/sayim/${input.count_id}`);
  return { ok: true, data: null };
}

/** Manual search when there is no label: name, style code, SKU, barcode, colour or size. No cost. */
export async function searchVariantsAction(term: string): Promise<Result<CountVariant[]>> {
  const { role } = await loadAppContext();
  if (!countCaps(role).canCount) return fail(NO_PERMISSION);
  const q = term.trim();
  if (q.length < 2) return { ok: true, data: [] };
  try {
    const rows = await listStock({ search: q });
    const ids = rows.slice(0, 40).map((r) => r.variant_id);
    const described = await describeVariants(ids);
    const lower = q.toLocaleLowerCase("tr-TR");
    const list = ids.map((id) => described.get(id)).filter((v): v is CountVariant => !!v);
    // listStock matches name / SKU / barcode; colour and size are matched here on the description.
    const byOption = list.filter((v) => v.options.toLocaleLowerCase("tr-TR").includes(lower));
    return { ok: true, data: byOption.length > 0 && byOption.length < list.length ? [...byOption, ...list.filter((v) => !byOption.includes(v))] : list };
  } catch (error) {
    console.error("[count] search failed:", error instanceof Error ? error.message : error);
    return fail("Arama yapılamadı. Tekrar deneyin.");
  }
}

// ------------------------------------------------------------------ opening cost (Phase 15B-0)

const COST_SOURCES: CountCostSource[] = ["documented_purchase", "owner_declared_opening_cost"];

/**
 * Owner/manager records the explicit unit cost of a surplus the ledger cannot price
 * (rpc_stock_count_set_line_cost, base currency, > 0, source required), then the review is
 * repeated so the fingerprint covers the new cost: a POST against the older review would be
 * refused (STALE_REVIEW). stock_staff never reaches this action; the RPC refuses it anyway.
 */
export async function setLineCostAction(input: { count_id: string; line_id: string; unit_cost: number; source: CountCostSource; note: string }): Promise<Result<null>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canCost) return fail(NO_PERMISSION);
  if (!UUID.test(input.count_id) || !UUID.test(input.line_id)) return fail("Sayım satırı bulunamadı.");
  if (!Number.isFinite(input.unit_cost) || input.unit_cost <= 0) return fail("Birim maliyet sıfırdan büyük olmalı.");
  if (!COST_SOURCES.includes(input.source)) return fail("Maliyet kaynağını seçin.");
  const { error } = await supabase.rpc("rpc_stock_count_set_line_cost", {
    p_line_id: input.line_id,
    p_unit_cost: Math.round(input.unit_cost * 1_000_000) / 1_000_000,
    p_source: input.source,
    p_note: input.note.trim().slice(0, 500) || null,
  });
  if (error) return fail(reportDbError("stockCountSetLineCost", error));
  const reviewed = await supabase.rpc("rpc_stock_count_review", { p_count_id: input.count_id });
  if (reviewed.error) return fail(reportDbError("stockCountReview", reviewed.error));
  revalidatePath(`/app/stok/sayim/${input.count_id}`);
  return { ok: true, data: null };
}

/** Removes an entered cost (NULL clears); the review is repeated for the same reason. */
export async function clearLineCostAction(input: { count_id: string; line_id: string }): Promise<Result<null>> {
  const { supabase, role } = await loadAppContext();
  if (!countCaps(role).canCost) return fail(NO_PERMISSION);
  if (!UUID.test(input.count_id) || !UUID.test(input.line_id)) return fail("Sayım satırı bulunamadı.");
  const { error } = await supabase.rpc("rpc_stock_count_set_line_cost", { p_line_id: input.line_id, p_unit_cost: null, p_source: null, p_note: null });
  if (error) return fail(reportDbError("stockCountClearLineCost", error));
  const reviewed = await supabase.rpc("rpc_stock_count_review", { p_count_id: input.count_id });
  if (reviewed.error) return fail(reportDbError("stockCountReview", reviewed.error));
  revalidatePath(`/app/stok/sayim/${input.count_id}`);
  return { ok: true, data: null };
}

