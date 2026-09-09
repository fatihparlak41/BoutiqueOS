"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { loadReceivingContext, searchVariants } from "@/lib/receiving/queries";
import { CURRENCIES, VARIANT_SEARCH_IDLE, type Currency, type VariantSearchState } from "@/lib/receiving/model";
import { reportDbError } from "@/lib/db-errors";
import type { ActionState } from "@/lib/catalog/action-state";

/**
 * Receiving writes.
 *
 * A draft is created only through rpc_create_goods_receipt: it derives the tenant from the
 * branch, generates receipt_number server-side with fn_next_sequence, and hard-codes
 * status='draft'. No receipt number is ever produced here, no business_id is read from a
 * form, and no status is submitted.
 *
 * Posting goes only through rpc_post_goods_receipt. There is no reversal action: the
 * reversal RPC is an explicit NOT_IMPLEMENTED stub (ADR-10) and this module does not
 * work around it.
 */

function fail(error: string): ActionState {
  return { error, ok: false };
}

const DONE: ActionState = { error: null, ok: true };
const NO_PERMISSION = "Bu işlem için yetkiniz yok.";

function text(formData: FormData, key: string): string {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function optionalText(formData: FormData, key: string): string | null {
  const value = text(formData, key);
  return value.length > 0 ? value : null;
}

function uuidOrNull(formData: FormData, key: string): string | null {
  const value = text(formData, key);
  return /^[0-9a-fA-F-]{36}$/.test(value) ? value : null;
}

function isCurrency(value: string): value is Currency {
  return (CURRENCIES as string[]).includes(value);
}

/** Accepts "1.234,56" and "1234.56"; returns null when the input is not a usable number. */
function parseDecimal(input: string): number | null {
  const trimmed = input.trim();
  if (!trimmed) return null;
  const normalised = trimmed.includes(",") ? trimmed.replace(/\./g, "").replace(",", ".") : trimmed;
  if (!/^\d+(\.\d{1,6})?$/.test(normalised)) return null;
  const value = Number(normalised);
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function parseQuantity(input: string): number | null {
  if (!/^\d{1,7}$/.test(input.trim())) return null;
  const value = Number(input.trim());
  return value > 0 ? value : null;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

// ------------------------------------------------------------------ draft create

export async function createReceiptAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);

  const branchId = uuidOrNull(formData, "branch_id");
  const supplierId = uuidOrNull(formData, "supplier_id");
  if (!branchId) return fail("Şube seçilmedi.");
  if (!supplierId) return fail("Tedarikçi seçilmedi.");

  const currency = text(formData, "invoice_currency");
  if (!isCurrency(currency)) return fail("Desteklenmeyen para birimi.");

  const receivedAt = text(formData, "received_at");
  if (!ISO_DATE.test(receivedAt)) return fail("Alım tarihi geçersiz.");

  let rate = 1;
  if (currency === "TRY") {
    // The schema constraint and the posting RPC both require exactly 1 for TRY.
    rate = 1;
  } else {
    const parsed = parseDecimal(text(formData, "exchange_rate"));
    if (parsed === null || parsed <= 0) return fail("Kur sıfırdan büyük olmalı.");
    rate = parsed;
  }

  const { data, error } = await supabase.rpc("rpc_create_goods_receipt", {
    p_branch_id: branchId,
    p_supplier_id: supplierId,
    p_invoice_currency: currency,
    p_exchange_rate: rate,
    p_received_at: receivedAt,
    p_document_ref: optionalText(formData, "document_ref"),
    p_note: optionalText(formData, "note"),
  });

  if (error) return fail(reportDbError("createReceipt", error));

  revalidatePath("/app/mal-kabul");
  redirect(`/app/mal-kabul/${data as string}`);
}

// ------------------------------------------------------------------ draft header

export async function updateReceiptHeaderAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);

  const receiptId = uuidOrNull(formData, "receipt_id");
  if (!receiptId) return fail("Belge bulunamadı.");

  const receivedAt = text(formData, "received_at");
  if (!ISO_DATE.test(receivedAt)) return fail("Alım tarihi geçersiz.");

  const currency = text(formData, "invoice_currency");
  if (!isCurrency(currency)) return fail("Desteklenmeyen para birimi.");

  let rate = 1;
  if (currency !== "TRY") {
    const parsed = parseDecimal(text(formData, "exchange_rate"));
    if (parsed === null || parsed <= 0) return fail("Kur sıfırdan büyük olmalı.");
    rate = parsed;
  }

  // pol_gr_update only allows this while the receipt is a draft; the posted guard trigger
  // refuses it afterwards regardless of role.
  const { error } = await supabase
    .from("goods_receipts")
    .update({
      received_at: receivedAt,
      exchange_rate: rate,
      document_ref: optionalText(formData, "document_ref"),
      note: optionalText(formData, "note"),
    })
    .eq("business_id", businessId)
    .eq("id", receiptId)
    .eq("status", "draft");

  if (error) return fail(reportDbError("updateReceiptHeader", error));

  revalidatePath(`/app/mal-kabul/${receiptId}`);
  revalidatePath("/app/mal-kabul");
  return DONE;
}

/** Draft-only. A posted receipt cannot be cancelled — that would be a reversal. */
export async function cancelReceiptAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);

  const receiptId = uuidOrNull(formData, "receipt_id");
  if (!receiptId) return fail("Belge bulunamadı.");

  const { error } = await supabase
    .from("goods_receipts")
    .update({ status: "cancelled" })
    .eq("business_id", businessId)
    .eq("id", receiptId)
    .eq("status", "draft");

  if (error) return fail(reportDbError("cancelReceipt", error));

  revalidatePath(`/app/mal-kabul/${receiptId}`);
  revalidatePath("/app/mal-kabul");
  return DONE;
}

// ------------------------------------------------------------------ draft lines

/**
 * One line per variant is a database rule: UNIQUE (goods_receipt_id, variant_id). Selecting
 * the same variant again updates the existing line instead of trying to add a duplicate.
 */
export async function upsertReceiptLineAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);

  const receiptId = uuidOrNull(formData, "receipt_id");
  const variantId = uuidOrNull(formData, "variant_id");
  if (!receiptId || !variantId) return fail("Satır bilgisi eksik.");

  const quantity = parseQuantity(text(formData, "quantity"));
  if (quantity === null) return fail("Adet sıfırdan büyük bir tam sayı olmalı.");

  const unitCost = parseDecimal(text(formData, "unit_cost"));
  if (unitCost === null) return fail("Birim maliyet geçerli bir tutar olmalı (örn. 400,00).");

  const { data: existing, error: lookupError } = await supabase
    .from("goods_receipt_items")
    .select("id")
    .eq("business_id", businessId)
    .eq("goods_receipt_id", receiptId)
    .eq("variant_id", variantId)
    .maybeSingle();

  if (lookupError) return fail(reportDbError("lookupReceiptLine", lookupError));

  if (existing) {
    const { error } = await supabase
      .from("goods_receipt_items")
      .update({ quantity, unit_cost: unitCost })
      .eq("business_id", businessId)
      .eq("id", existing.id as string);
    if (error) return fail(reportDbError("updateReceiptLine", error));
  } else {
    // business_id is filled by trg_bid_gri from the parent receipt.
    const { error } = await supabase
      .from("goods_receipt_items")
      .insert({ goods_receipt_id: receiptId, variant_id: variantId, quantity, unit_cost: unitCost });
    if (error) return fail(reportDbError("insertReceiptLine", error));
  }

  revalidatePath(`/app/mal-kabul/${receiptId}`);
  return DONE;
}

export async function deleteReceiptLineAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);

  const receiptId = uuidOrNull(formData, "receipt_id");
  const lineId = uuidOrNull(formData, "line_id");
  if (!receiptId || !lineId) return fail("Satır bulunamadı.");

  const { error } = await supabase
    .from("goods_receipt_items")
    .delete()
    .eq("business_id", businessId)
    .eq("id", lineId);

  if (error) return fail(reportDbError("deleteReceiptLine", error));

  revalidatePath(`/app/mal-kabul/${receiptId}`);
  return DONE;
}

/**
 * Adds or updates several lines in one submit, so a whole size run can be entered without
 * a round trip per variant.
 *
 * Every row is parsed and validated BEFORE anything is written, so a typo in the third row
 * cannot leave the first two applied. The writes themselves are still ordinary per-row
 * upserts under the same RLS and the same UNIQUE (goods_receipt_id, variant_id) rule — no
 * new posting path, no change to what a receipt means. Nothing is written until the user
 * submits: there is no autosave.
 */
export async function addReceiptLinesAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);

  const receiptId = uuidOrNull(formData, "receipt_id");
  if (!receiptId) return fail("Belge bulunamadı.");

  const rows: Array<{ variantId: string; quantity: number; unitCost: number }> = [];

  for (const [key, value] of formData.entries()) {
    if (!key.startsWith("qty_") || typeof value !== "string") continue;
    const variantId = key.slice(4);
    if (!/^[0-9a-fA-F-]{36}$/.test(variantId)) continue;

    const rawQty = value.trim();
    if (!rawQty) continue; // adet girilmemis satir sessizce atlanir

    const quantity = parseQuantity(rawQty);
    if (quantity === null) return fail("Adet sıfırdan büyük bir tam sayı olmalı.");

    const rawCost = formData.get(`cost_${variantId}`);
    const unitCost = parseDecimal(typeof rawCost === "string" ? rawCost : "");
    if (unitCost === null) return fail("Birim maliyet geçerli bir tutar olmalı (örn. 400,00).");

    rows.push({ variantId, quantity, unitCost });
  }

  if (rows.length === 0) return fail("Adet girilmiş satır yok.");

  const { data: existing, error: lookupError } = await supabase
    .from("goods_receipt_items")
    .select("id, variant_id")
    .eq("business_id", businessId)
    .eq("goods_receipt_id", receiptId);

  if (lookupError) return fail(reportDbError("lookupReceiptLines", lookupError));

  for (const row of rows) {
    const match = (existing ?? []).find((line) => line.variant_id === row.variantId);
    if (match) {
      const { error } = await supabase
        .from("goods_receipt_items")
        .update({ quantity: row.quantity, unit_cost: row.unitCost })
        .eq("business_id", businessId)
        .eq("id", match.id as string);
      if (error) return fail(reportDbError("updateReceiptLines", error));
    } else {
      const { error } = await supabase
        .from("goods_receipt_items")
        .insert({ goods_receipt_id: receiptId, variant_id: row.variantId, quantity: row.quantity, unit_cost: row.unitCost });
      if (error) return fail(reportDbError("insertReceiptLines", error));
    }
  }

  revalidatePath(`/app/mal-kabul/${receiptId}`);
  return DONE;
}

// ------------------------------------------------------------------ posting

export async function postReceiptAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);

  const receiptId = uuidOrNull(formData, "receipt_id");
  if (!receiptId) return fail("Belge bulunamadı.");

  // One call, one transaction: ledger rows, cost pool and the supplier liability are
  // written together or not at all. A second call is refused with INVALID_STATE.
  const { error } = await supabase.rpc("rpc_post_goods_receipt", { p_goods_receipt_id: receiptId });

  if (error) return fail(reportDbError("postReceipt", error));

  revalidatePath(`/app/mal-kabul/${receiptId}`);
  revalidatePath("/app/mal-kabul");
  revalidatePath("/app/stok");
  return DONE;
}

// ------------------------------------------------------------------ line picker

/**
 * Server-side variant lookup for the line picker. A product-name hit returns every active
 * variant of that product, so a full S/M/L run can be entered without searching each size.
 */
export async function searchVariantsAction(
  _prev: VariantSearchState,
  formData: FormData,
): Promise<VariantSearchState> {
  const { caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return { ...VARIANT_SEARCH_IDLE, error: NO_PERMISSION };

  const term = text(formData, "term");
  if (term.length < 2) return { error: "En az 2 karakter yazın.", term, results: [] };

  try {
    const results = await searchVariants(term);
    return { error: results.length === 0 ? "Eşleşen varyant yok." : null, term, results };
  } catch {
    return { error: "Arama yapılamadı. Tekrar deneyin.", term, results: [] };
  }
}
