"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { loadPoContext } from "@/lib/po/queries";
import { CURRENCIES, type Currency } from "@/lib/receiving/model";
import { reportDbError } from "@/lib/db-errors";
import type { ActionState } from "@/lib/catalog/action-state";

/**
 * Purchase order actions. Every write is an RPC that proves the caller's rank in the
 * database (owner / manager for the document, procurement roles for creating a receipt
 * from it); the tenant is the one the shell resolved. Nothing here posts stock: creating a
 * receipt from a PO yields a DRAFT that goes through the Phase 8A workbench.
 */

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";
const DONE: ActionState = { error: null, ok: true };
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-fA-F-]{36}$/;

function fail(error: string): ActionState {
  return { error, ok: false };
}
function text(formData: FormData, key: string): string {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}
function optionalText(formData: FormData, key: string): string | null {
  const v = text(formData, key);
  return v ? v : null;
}
function uuidOrNull(formData: FormData, key: string): string | null {
  const v = text(formData, key);
  return UUID.test(v) ? v : null;
}
function isCurrency(value: string): value is Currency {
  return (CURRENCIES as readonly string[]).includes(value);
}
function parseDecimal(input: string): number | null {
  const trimmed = input.trim();
  if (!trimmed) return null;
  const normalised = trimmed.includes(",") ? trimmed.replace(/\./g, "").replace(",", ".") : trimmed;
  const value = Number(normalised);
  return Number.isFinite(value) && value >= 0 ? value : null;
}
function parseQuantity(input: string): number | null {
  const value = Number(input.trim());
  return Number.isInteger(value) && value > 0 ? value : null;
}

export async function createPoAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadPoContext();
  if (!caps.canManage) return fail(NO_PERMISSION);
  const branchId = uuidOrNull(formData, "branch_id");
  const supplierId = uuidOrNull(formData, "supplier_id");
  if (!branchId) return fail("Şube seçin.");
  if (!supplierId) return fail("Tedarikçi seçin.");
  const currency = text(formData, "currency") || "TRY";
  if (!isCurrency(currency)) return fail("Para birimi geçersiz.");
  const fxRaw = text(formData, "fx_rate");
  const fx = fxRaw ? parseDecimal(fxRaw) : null;
  if (fxRaw && (fx === null || fx <= 0)) return fail("Kur sıfırdan büyük bir sayı olmalı.");
  if (currency === "TRY" && fx !== null && fx !== 1) return fail("TRY siparişte kur 1 olmalı.");
  const orderDate = text(formData, "order_date");
  if (!ISO_DATE.test(orderDate)) return fail("Sipariş tarihi gerekli.");
  const expected = text(formData, "expected_date");
  if (expected && !ISO_DATE.test(expected)) return fail("Beklenen tarih geçersiz.");
  const prefillVariant = uuidOrNull(formData, "prefill_variant");
  const prefillWhy = optionalText(formData, "prefill_why");

  const { data, error } = await supabase.rpc("rpc_po_create", {
    p_branch_id: branchId, p_supplier_id: supplierId, p_currency: currency, p_fx_rate: currency === "TRY" ? null : fx,
    p_order_date: orderDate, p_expected_date: expected || null,
    p_supplier_reference: optionalText(formData, "supplier_reference"), p_note: optionalText(formData, "note"),
  });
  if (error) return fail(reportDbError("createPo", error));
  revalidatePath("/app/satin-alma");
  const q = prefillVariant ? `?ekle=${prefillVariant}${prefillWhy ? `&neden=${encodeURIComponent(prefillWhy.slice(0, 200))}` : ""}` : "";
  redirect(`/app/satin-alma/${data as string}${q}`);
}

export async function updatePoHeaderAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadPoContext();
  if (!caps.canManage) return fail(NO_PERMISSION);
  const poId = uuidOrNull(formData, "po_id");
  if (!poId) return fail("Sipariş bulunamadı.");
  const expected = text(formData, "expected_date");
  if (expected && !ISO_DATE.test(expected)) return fail("Beklenen tarih geçersiz.");
  const { error } = await supabase.rpc("rpc_po_update", {
    p_po_id: poId, p_expected_date: expected || null, p_supplier_reference: optionalText(formData, "supplier_reference"), p_note: optionalText(formData, "note"),
  });
  if (error) return fail(reportDbError("updatePo", error));
  revalidatePath(`/app/satin-alma/${poId}`);
  return DONE;
}

/** Lines from the picker: qty_<variant> (+ cost_<variant> for manager+). Empty quantities are skipped. */
export async function upsertPoLinesAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadPoContext();
  if (!caps.canManage) return fail(NO_PERMISSION);
  const poId = uuidOrNull(formData, "po_id");
  if (!poId) return fail("Sipariş bulunamadı.");
  const rows: Array<{ variantId: string; quantity: number; cost: number | null }> = [];
  for (const [key, value] of formData.entries()) {
    if (!key.startsWith("qty_") || typeof value !== "string") continue;
    const variantId = key.slice(4);
    if (!UUID.test(variantId)) continue;
    const raw = value.trim();
    if (!raw) continue;
    const quantity = parseQuantity(raw);
    if (quantity === null) return fail("Adet sıfırdan büyük bir tam sayı olmalı.");
    const costRaw = text(formData, `cost_${variantId}`);
    const cost = costRaw ? parseDecimal(costRaw) : null;
    if (costRaw && cost === null) return fail("Beklenen birim maliyet geçersiz.");
    rows.push({ variantId, quantity, cost });
  }
  if (rows.length === 0) return fail("Adet girilmiş satır yok.");
  for (const row of rows) {
    const { error } = await supabase.rpc("rpc_po_upsert_line", { p_po_id: poId, p_variant_id: row.variantId, p_quantity: row.quantity, p_expected_unit_cost: row.cost, p_note: null });
    if (error) return fail(reportDbError("upsertPoLines", error));
  }
  revalidatePath(`/app/satin-alma/${poId}`);
  return { ...DONE, message: `${rows.length} satır kaydedildi.` };
}

export async function removePoLineAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadPoContext();
  if (!caps.canManage) return fail(NO_PERMISSION);
  const poId = uuidOrNull(formData, "po_id");
  const variantId = uuidOrNull(formData, "variant_id");
  if (!poId || !variantId) return fail("Satır bulunamadı.");
  const { error } = await supabase.rpc("rpc_po_remove_line", { p_po_id: poId, p_variant_id: variantId });
  if (error) return fail(reportDbError("removePoLine", error));
  revalidatePath(`/app/satin-alma/${poId}`);
  return DONE;
}

async function transition(rpc: string, formData: FormData, extra: Record<string, unknown> = {}): Promise<ActionState> {
  const { supabase, caps } = await loadPoContext();
  if (!caps.canManage) return fail(NO_PERMISSION);
  const poId = uuidOrNull(formData, "po_id");
  if (!poId) return fail("Sipariş bulunamadı.");
  const { error } = await supabase.rpc(rpc, { p_po_id: poId, ...extra });
  if (error) return fail(reportDbError(rpc, error));
  revalidatePath(`/app/satin-alma/${poId}`);
  revalidatePath("/app/satin-alma");
  return DONE;
}

export async function approvePoAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  return transition("rpc_po_approve", formData);
}
export async function orderPoAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  return transition("rpc_po_mark_ordered", formData);
}
export async function cancelPoAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const reason = text(formData, "reason");
  if (reason.length < 3) return fail("İptal nedeni gerekli (en az 3 karakter).");
  return transition("rpc_po_cancel", formData, { p_reason: reason });
}
export async function closePoAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  return transition("rpc_po_close", formData, { p_reason: optionalText(formData, "reason") });
}

/** "Mal kabul oluştur": a draft receipt through the 8A engine, prefilled with the remaining quantities (no cost). */
export async function createReceiptFromPoAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadPoContext();
  if (!caps.canReceive) return fail(NO_PERMISSION);
  const poId = uuidOrNull(formData, "po_id");
  if (!poId) return fail("Sipariş bulunamadı.");
  const receivedAt = text(formData, "received_at");
  const { data, error } = await supabase.rpc("rpc_po_create_receipt", {
    p_po_id: poId, p_received_at: ISO_DATE.test(receivedAt) ? receivedAt : new Date().toISOString().slice(0, 10), p_document_ref: optionalText(formData, "document_ref"),
  });
  if (error) return fail(reportDbError("createReceiptFromPo", error));
  revalidatePath(`/app/satin-alma/${poId}`);
  revalidatePath("/app/mal-kabul");
  redirect(`/app/mal-kabul/${data as string}`);
}
