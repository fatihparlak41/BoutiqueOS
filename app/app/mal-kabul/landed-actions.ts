"use server";

import { revalidatePath } from "next/cache";
import { loadReceivingContext } from "@/lib/receiving/queries";
import { CURRENCIES, type AllocationMethod, type ChargeKind, type ChargeLiabilityMode, type Currency } from "@/lib/receiving/model";
import { reportDbError } from "@/lib/db-errors";
import type { ActionState } from "@/lib/catalog/action-state";

/**
 * Phase 8A write side: additional charges, allocation method, review, reversal.
 * Draft charges and the allocation method are ordinary RLS-guarded writes (procurement,
 * active business, draft document — the posted-document trigger refuses the rest).
 * Review, POST and reversal are RPCs and re-prove everything themselves.
 */

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";
const UUID = /^[0-9a-fA-F-]{36}$/;
const KINDS: ChargeKind[] = ["freight", "customs", "insurance", "handling", "other"];
const MODES: ChargeLiabilityMode[] = ["add_to_invoice", "separate_supplier", "no_liability"];
const METHODS: AllocationMethod[] = ["invoice_value_proportional", "quantity_proportional", "equal_per_line", "manual"];

function fail(error: string): ActionState {
  return { error, ok: false };
}
const DONE: ActionState = { error: null, ok: true };

function text(fd: FormData, key: string): string {
  const v = fd.get(key);
  return typeof v === "string" ? v.trim() : "";
}
function parseDecimal(input: string): number | null {
  const t = input.trim();
  if (!t) return null;
  const n = Number(t.includes(",") ? t.replace(/\./g, "").replace(",", ".") : t);
  return Number.isFinite(n) ? n : null;
}

export async function addChargeAction(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);
  const receiptId = text(fd, "receipt_id");
  if (!UUID.test(receiptId)) return fail("Belge bulunamadı.");

  const kind = text(fd, "kind") as ChargeKind;
  if (!KINDS.includes(kind)) return fail("Masraf türü geçersiz.");
  const amount = parseDecimal(text(fd, "amount"));
  if (amount === null || amount <= 0) return fail("Masraf tutarı sıfırdan büyük olmalı.");
  const currency = text(fd, "currency") as Currency;
  if (!CURRENCIES.includes(currency)) return fail("Para birimi geçersiz.");
  const rate = currency === "TRY" ? 1 : parseDecimal(text(fd, "exchange_rate"));
  if (rate === null || rate <= 0) return fail("Kur sıfırdan büyük olmalı.");
  const mode = text(fd, "liability_mode") as ChargeLiabilityMode;
  if (!MODES.includes(mode)) return fail("Borç seçeneği geçersiz.");
  const payee = text(fd, "payee_supplier_id");
  if (mode === "separate_supplier" && !UUID.test(payee)) return fail("Masrafı kesen tedarikçiyi seçin.");
  const description = text(fd, "description").slice(0, 120) || null;

  // The parent trigger sets business_id from the receipt; the value is sent for the RLS
  // predicate only and cannot point anywhere else.
  const { error } = await supabase.from("goods_receipt_charges").insert({
    business_id: businessId,
    goods_receipt_id: receiptId,
    kind,
    description,
    amount,
    currency,
    exchange_rate: rate,
    include_in_landed: fd.get("include_in_landed") === "on",
    liability_mode: mode,
    payee_supplier_id: mode === "separate_supplier" ? payee : null,
  });
  if (error) return fail(reportDbError("addCharge", error));
  revalidatePath(`/app/mal-kabul/${receiptId}`);
  return DONE;
}

export async function deleteChargeAction(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);
  const receiptId = text(fd, "receipt_id");
  const chargeId = text(fd, "charge_id");
  if (!UUID.test(receiptId) || !UUID.test(chargeId)) return fail("Masraf bulunamadı.");
  const { error } = await supabase.from("goods_receipt_charges").delete().eq("business_id", businessId).eq("id", chargeId).eq("goods_receipt_id", receiptId);
  if (error) return fail(reportDbError("deleteCharge", error));
  revalidatePath(`/app/mal-kabul/${receiptId}`);
  return DONE;
}

export async function setAllocationMethodAction(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);
  const receiptId = text(fd, "receipt_id");
  if (!UUID.test(receiptId)) return fail("Belge bulunamadı.");
  const method = text(fd, "allocation_method") as AllocationMethod;
  if (!METHODS.includes(method)) return fail("Dağıtım yöntemi geçersiz.");
  const { error } = await supabase
    .from("goods_receipts")
    .update({ allocation_method: method })
    .eq("business_id", businessId)
    .eq("id", receiptId)
    .eq("status", "draft");
  if (error) return fail(reportDbError("setAllocationMethod", error));
  revalidatePath(`/app/mal-kabul/${receiptId}`);
  return DONE;
}

/** Validates like POST would and stamps the review. Stock, cost and liabilities are untouched. */
export async function reviewReceiptAction(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadReceivingContext();
  if (!caps.canWriteReceipt) return fail(NO_PERMISSION);
  const receiptId = text(fd, "receipt_id");
  if (!UUID.test(receiptId)) return fail("Belge bulunamadı.");
  const { error } = await supabase.rpc("rpc_goods_receipt_review", { p_goods_receipt_id: receiptId });
  if (error) return fail(reportDbError("reviewReceipt", error));
  revalidatePath(`/app/mal-kabul/${receiptId}`);
  return DONE;
}

/** Manager+: reversal document for a posted receipt. Refused when the goods already left. */
export async function reverseReceiptAction(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const { supabase, caps } = await loadReceivingContext();
  if (!caps.canReverse) return fail(NO_PERMISSION);
  const receiptId = text(fd, "receipt_id");
  if (!UUID.test(receiptId)) return fail("Belge bulunamadı.");
  const reason = text(fd, "reason");
  if (reason.length < 3) return fail("Ters kayıt nedeni en az 3 karakter olmalı.");
  if (fd.get("confirm") !== "on") return fail("Onay kutusunu işaretleyin.");
  const { error } = await supabase.rpc("rpc_reverse_goods_receipt", { p_goods_receipt_id: receiptId, p_reason: reason.slice(0, 500) });
  if (error) return fail(reportDbError("reverseReceipt", error));
  revalidatePath(`/app/mal-kabul/${receiptId}`);
  revalidatePath("/app/mal-kabul");
  revalidatePath("/app/stok");
  return DONE;
}
