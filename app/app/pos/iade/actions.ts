"use server";

import { revalidatePath } from "next/cache";
import { loadPosContext } from "@/lib/pos/queries";
import { findSales, getEligibility } from "@/lib/pos/returns-queries";
import { PAYMENT_METHODS } from "@/lib/pos/model";
import { CONDITIONS, type Eligibility, type ExchangePayload, type ExchangeResult, type FoundSale, type LookupMode, type ReturnPayload, type ReturnResult, type ReturnSelection } from "@/lib/pos/returns-model";
import { reportDbError } from "@/lib/db-errors";
import type { Result } from "@/lib/catalog/intake";

/**
 * Returns / exchange writes. Lookup and eligibility are open to every selling role
 * (sales_staff prepares the case at the counter); completing a return or an exchange is
 * an owner/manager act — the UI hides the button for others and the database refuses
 * them regardless. Every rule (window, exclusions, remaining quantity, condition,
 * refund policy, downgrade treatment, session, tenant) is decided by rpc_pos_return /
 * rpc_pos_exchange in one transaction; this file only validates shape.
 */

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";
const UUID = /^[0-9a-fA-F-]{36}$/;
const MODES: LookupMode[] = ["sale_number", "barcode", "customer"];

function validSelection(items: unknown): items is ReturnSelection[] {
  if (!Array.isArray(items) || items.length === 0 || items.length > 100) return false;
  return items.every((i) => i && UUID.test(String(i.sale_item_id)) && Number.isInteger(i.quantity) && i.quantity > 0 && i.quantity <= 9999 && CONDITIONS.includes(i.condition));
}
function toItems(items: ReturnSelection[]) {
  return items.map((i) => ({ sale_item_id: i.sale_item_id, quantity: i.quantity, disposition: i.condition }));
}
function num(v: unknown): number {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

export async function findSalesAction(mode: LookupMode, query: string): Promise<Result<FoundSale[]>> {
  const { caps } = await loadPosContext();
  if (!caps.canSell) return { ok: false, error: NO_PERMISSION };
  if (!MODES.includes(mode)) return { ok: false, error: "Arama türü geçersiz." };
  try {
    return { ok: true, data: await findSales(mode, query ?? "") };
  } catch {
    return { ok: false, error: "Satış aranamadı. Tekrar deneyin." };
  }
}

export async function eligibilityAction(saleId: string): Promise<Result<Eligibility | null>> {
  const { caps } = await loadPosContext();
  if (!caps.canSell) return { ok: false, error: NO_PERMISSION };
  if (!UUID.test(saleId ?? "")) return { ok: false, error: "Satış bulunamadı." };
  try {
    return { ok: true, data: await getEligibility(saleId) };
  } catch {
    return { ok: false, error: "Uygunluk okunamadı. Tekrar deneyin." };
  }
}

export async function completeReturnAction(payload: ReturnPayload): Promise<Result<ReturnResult>> {
  const { supabase, caps } = await loadPosContext();
  if (!caps.canCompleteReturns) return { ok: false, error: NO_PERMISSION };
  if (!payload || !UUID.test(payload.sale_id) || !UUID.test(payload.client_transaction_id)) return { ok: false, error: "İade bilgisi eksik. Sayfayı yenileyin." };
  if (!validSelection(payload.items)) return { ok: false, error: "İade satırı geçersiz." };
  if (payload.refund_method !== null && !PAYMENT_METHODS.includes(payload.refund_method)) return { ok: false, error: "İade yöntemi geçersiz." };
  const session = payload.register_session_id && UUID.test(payload.register_session_id) ? payload.register_session_id : null;

  const { data, error } = await supabase.rpc("rpc_pos_return", {
    p_sale_id: payload.sale_id,
    p_items: toItems(payload.items),
    p_return_type: "refund",
    p_client_transaction_id: payload.client_transaction_id,
    p_reason_code: payload.reason_code?.trim() || null,
    p_note: payload.note?.trim().slice(0, 300) || null,
    p_register_session_id: session,
    p_refund_method: payload.refund_method,
  });
  if (error) return { ok: false, error: reportDbError("completeReturn", error) };
  const r = (data ?? {}) as Record<string, unknown>;
  revalidatePath("/app/pos");
  revalidatePath("/app/stok");
  return { ok: true, data: { return_id: String(r.return_id), return_number: String(r.return_number), credit_value_base: num(r.credit_value_base), refund_amount_base: num(r.refund_amount_base), replayed: Boolean(r.replayed) } };
}

export async function completeExchangeAction(payload: ExchangePayload): Promise<Result<ExchangeResult>> {
  const { supabase, caps } = await loadPosContext();
  if (!caps.canCompleteReturns) return { ok: false, error: NO_PERMISSION };
  if (!payload || !UUID.test(payload.sale_id) || !UUID.test(payload.register_session_id) || !UUID.test(payload.client_transaction_id)) {
    return { ok: false, error: "Değişim bilgisi eksik. Sayfayı yenileyin." };
  }
  if (!validSelection(payload.return_items)) return { ok: false, error: "İade satırı geçersiz." };
  if (!Array.isArray(payload.new_lines) || payload.new_lines.length === 0 || payload.new_lines.length > 200) return { ok: false, error: "Yeni ürün seçilmedi." };
  for (const l of payload.new_lines) {
    if (!UUID.test(l.variant_id) || !Number.isInteger(l.quantity) || l.quantity <= 0 || l.quantity > 9999) return { ok: false, error: "Sepet satırı geçersiz." };
    if (!Number.isFinite(l.unit_price) || l.unit_price < 0 || !Number.isFinite(l.expected_list_price)) return { ok: false, error: "Satır fiyatı geçersiz." };
  }
  if (!Array.isArray(payload.payments)) return { ok: false, error: "Ödeme bilgisi geçersiz." };
  for (const p of payload.payments) {
    if (!PAYMENT_METHODS.includes(p.method) || !Number.isFinite(p.amount) || p.amount <= 0) return { ok: false, error: "Ödeme satırı geçersiz." };
  }
  const customerId = payload.customer_id && UUID.test(payload.customer_id) ? payload.customer_id : null;
  const salespersonId = payload.salesperson_id && UUID.test(payload.salesperson_id) ? payload.salesperson_id : null;

  const { data, error } = await supabase.rpc("rpc_pos_exchange", {
    p_register_session_id: payload.register_session_id,
    p_original_sale_id: payload.sale_id,
    p_return_items: toItems(payload.return_items),
    p_new_items: payload.new_lines.map((l) => ({
      variant_id: l.variant_id,
      quantity: l.quantity,
      unit_price: Math.round(l.unit_price * 100) / 100,
      expected_list_price: Math.round(l.expected_list_price * 100) / 100,
    })),
    p_payments: payload.payments.map((p) => ({ method: p.method, currency: "TRY", amount: Math.round(p.amount * 100) / 100 })),
    p_client_transaction_id: payload.client_transaction_id,
    p_reason_code: payload.reason_code?.trim() || null,
    p_note: payload.note?.trim().slice(0, 300) || null,
    p_customer_id: customerId,
    p_salesperson_id: salespersonId,
    p_device_id: null,
  });
  if (error) return { ok: false, error: reportDbError("completeExchange", error) };
  const r = (data ?? {}) as Record<string, unknown>;
  const ret = (r.return ?? {}) as Record<string, unknown>;
  revalidatePath("/app/pos");
  revalidatePath("/app/stok");
  return {
    ok: true,
    data: {
      sale_id: String(r.sale_id), sale_number: String(r.sale_number), total: num(r.total), amount_due: num(r.amount_due), change_given: num(r.change_given),
      credit_applied: num(r.credit_applied ?? ret.credit_value_base), replayed: Boolean(r.replayed),
      return_id: String(ret.return_id), return_number: String(ret.return_number), credit_value_base: num(ret.credit_value_base), refund_amount_base: num(ret.refund_amount_base ?? r.refund_amount_base),
    },
  };
}
