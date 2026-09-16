"use server";

import { revalidatePath } from "next/cache";
import { loadPosContext, lookupBarcode, searchCustomers, searchItems } from "@/lib/pos/queries";
import { PAYMENT_METHODS, type PosCustomer, type PosItem, type SalePayload, type SaleResult } from "@/lib/pos/model";
import { reportDbError } from "@/lib/db-errors";
import type { ActionState } from "@/lib/catalog/action-state";
import type { Result } from "@/lib/catalog/intake";

/**
 * POS writes. Registers are ordinary RLS-guarded rows (manager+). Sessions open and close
 * through the Rev 3 RPCs. A sale goes through rpc_pos_complete_sale only: the server
 * takes the business and branch from the session, resolves every price itself, checks
 * discount authority, stock and payments, and writes everything in one transaction.
 * Nothing financial is trusted from the browser — the cart is a proposal.
 */

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";
const UUID = /^[0-9a-fA-F-]{36}$/;
const DONE: ActionState = { error: null, ok: true };
function fail(error: string): ActionState {
  return { error, ok: false };
}
function text(fd: FormData, key: string): string {
  const v = fd.get(key);
  return typeof v === "string" ? v.trim() : "";
}
function parseMoney(input: string): number | null {
  const t = input.trim();
  if (!t) return null;
  const n = Number(t.includes(",") ? t.replace(/\./g, "").replace(",", ".") : t);
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : null;
}

// ------------------------------------------------------------------ registers / sessions

export async function createRegisterAction(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, businessId, branchId, caps } = await loadPosContext();
  if (!caps.canManageRegisters) return fail(NO_PERMISSION);
  if (!branchId) return fail("Aktif şube yok.");
  const name = text(fd, "name").slice(0, 60);
  if (name.length < 2) return fail("Kasa adı en az 2 karakter olmalı.");
  const deviceRef = text(fd, "device_ref").slice(0, 80) || null;
  const { error } = await supabase.from("cash_registers").insert({ business_id: businessId, branch_id: branchId, name, device_ref: deviceRef });
  if (error) return fail(reportDbError("createRegister", error));
  revalidatePath("/app/pos");
  return DONE;
}

export async function openSessionAction(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadPosContext();
  if (!caps.canSell) return fail(NO_PERMISSION);
  const registerId = text(fd, "register_id");
  if (!UUID.test(registerId)) return fail("Kasa seçilmedi.");
  const opening = parseMoney(text(fd, "opening_cash") || "0");
  if (opening === null) return fail("Açılış nakdi geçerli bir tutar olmalı.");
  const { error } = await supabase.rpc("rpc_open_register_session", {
    p_cash_register_id: registerId,
    p_opening_counts: [{ currency: "TRY", amount: opening }],
  });
  if (error) return fail(reportDbError("openSession", error));
  revalidatePath("/app/pos");
  return DONE;
}

export async function closeSessionAction(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadPosContext();
  if (!caps.canSell) return fail(NO_PERMISSION);
  const sessionId = text(fd, "session_id");
  if (!UUID.test(sessionId)) return fail("Oturum bulunamadı.");
  const counted = parseMoney(text(fd, "counted_cash"));
  if (counted === null) return fail("Sayılan nakit geçerli bir tutar olmalı.");
  const { error } = await supabase.rpc("rpc_close_register_session", {
    p_register_session_id: sessionId,
    p_counts: [{ currency: "TRY", counted_amount: counted }],
    p_closing_note: text(fd, "note").slice(0, 200) || null,
  });
  if (error) return fail(reportDbError("closeSession", error));
  revalidatePath("/app/pos");
  return DONE;
}

// ------------------------------------------------------------------ lookups

export async function lookupBarcodeAction(code: string): Promise<Result<PosItem | null>> {
  const { caps } = await loadPosContext();
  if (!caps.canSell) return { ok: false, error: NO_PERMISSION };
  const trimmed = (code ?? "").trim();
  if (!trimmed || trimmed.length > 64) return { ok: false, error: "Barkod geçersiz." };
  try {
    return { ok: true, data: await lookupBarcode(trimmed) };
  } catch {
    return { ok: false, error: "Barkod aranamadı. Tekrar deneyin." };
  }
}

export async function searchItemsAction(term: string): Promise<Result<PosItem[]>> {
  const { caps } = await loadPosContext();
  if (!caps.canSell) return { ok: false, error: NO_PERMISSION };
  try {
    return { ok: true, data: await searchItems(term ?? "") };
  } catch {
    return { ok: false, error: "Arama yapılamadı. Tekrar deneyin." };
  }
}

export async function searchCustomersAction(term: string): Promise<Result<PosCustomer[]>> {
  const { caps } = await loadPosContext();
  if (!caps.canSell) return { ok: false, error: NO_PERMISSION };
  try {
    return { ok: true, data: await searchCustomers(term ?? "") };
  } catch {
    return { ok: false, error: "Müşteri araması yapılamadı." };
  }
}

// ------------------------------------------------------------------ sale

/**
 * One call, one transaction. The payload is validated for shape here; every business
 * rule (price, discount authority, stock, payment total, session state, tenant) is
 * decided by rpc_pos_complete_sale. A repeated submit with the same
 * client_transaction_id returns the original sale (replayed = true).
 */
export async function completeSaleAction(payload: SalePayload): Promise<Result<SaleResult>> {
  const { supabase, caps } = await loadPosContext();
  if (!caps.canSell) return { ok: false, error: NO_PERMISSION };
  if (!payload || !UUID.test(payload.register_session_id) || !UUID.test(payload.client_transaction_id)) {
    return { ok: false, error: "Satış bilgisi eksik. Sayfayı yenileyin." };
  }
  if (!Array.isArray(payload.lines) || payload.lines.length === 0) return { ok: false, error: "Sepet boş." };
  if (payload.lines.length > 200) return { ok: false, error: "Sepet çok büyük." };
  for (const l of payload.lines) {
    if (!UUID.test(l.variant_id) || !Number.isInteger(l.quantity) || l.quantity <= 0 || l.quantity > 9999) return { ok: false, error: "Sepet satırı geçersiz." };
    if (!Number.isFinite(l.unit_price) || l.unit_price < 0 || !Number.isFinite(l.expected_list_price)) return { ok: false, error: "Satır fiyatı geçersiz." };
  }
  if (!Array.isArray(payload.payments) || payload.payments.length === 0) return { ok: false, error: "Ödeme girilmedi." };
  for (const p of payload.payments) {
    if (!PAYMENT_METHODS.includes(p.method) || !Number.isFinite(p.amount) || p.amount <= 0) return { ok: false, error: "Ödeme satırı geçersiz." };
  }
  const customerId = payload.customer_id && UUID.test(payload.customer_id) ? payload.customer_id : null;
  const salespersonId = payload.salesperson_id && UUID.test(payload.salesperson_id) ? payload.salesperson_id : null;

  const { data, error } = await supabase.rpc("rpc_pos_complete_sale", {
    p_register_session_id: payload.register_session_id,
    p_items: payload.lines.map((l) => ({
      variant_id: l.variant_id,
      quantity: l.quantity,
      unit_price: Math.round(l.unit_price * 100) / 100,
      expected_list_price: Math.round(l.expected_list_price * 100) / 100,
    })),
    p_payments: payload.payments.map((p) => ({ method: p.method, currency: "TRY", amount: Math.round(p.amount * 100) / 100 })),
    p_client_transaction_id: payload.client_transaction_id,
    p_customer_id: customerId,
    p_salesperson_id: salespersonId,
    // A price below list is a negotiated discount within the actor's authority (the RPC
    // enforces the limit); the reason enum has no "staff" value and this is the honest one.
    p_discount_reason: payload.lines.some((l) => l.unit_price < l.expected_list_price) ? "negotiated" : null,
    p_note: payload.note?.trim().slice(0, 300) || null,
    p_device_id: null,
  });
  if (error) return { ok: false, error: reportDbError("completeSale", error) };
  const r = (data ?? {}) as Record<string, unknown>;
  revalidatePath("/app/pos");
  revalidatePath("/app/stok");
  return {
    ok: true,
    data: {
      sale_id: String(r.sale_id),
      sale_number: String(r.sale_number),
      total: Number(r.total),
      change_given: Number(r.change_given ?? 0),
      replayed: Boolean(r.replayed),
    },
  };
}
