"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { reportDbError } from "@/lib/db-errors";
import { requirePlatformAdmin } from "@/lib/platform/queries";
import type { PlatformActionState } from "@/lib/saas/model";

/**
 * Platform console writes. Each one is a single audited RPC that re-proves the platform
 * role in the database; the console never touches a tenant table directly.
 */

const UUID = /^[0-9a-f-]{36}$/i;

export async function approveApplicationAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const id = String(formData.get("application_id") ?? "");
  const note = String(formData.get("note") ?? "").trim();
  if (!UUID.test(id)) return { error: "Başvuru bulunamadı.", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_approve_application", { p_application_id: id, p_note: note || null });
  if (error) return { error: reportDbError("approve application", error), ok: false };
  const result = data as { business_id: string };
  revalidatePath("/platform", "layout");
  redirect(`/platform/isletmeler/${result.business_id}`);
}

export async function rejectApplicationAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const id = String(formData.get("application_id") ?? "");
  const note = String(formData.get("note") ?? "").trim();
  if (!UUID.test(id)) return { error: "Başvuru bulunamadı.", ok: false };
  if (note.length < 3) return { error: "Başvuru sahibine iletilecek bir neden yazın (en az 3 karakter).", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("rpc_platform_reject_application", { p_application_id: id, p_note: note });
  if (error) return { error: reportDbError("reject application", error), ok: false };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true };
}

export async function setBusinessStatusAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const id = String(formData.get("business_id") ?? "");
  const status = String(formData.get("status") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  if (!UUID.test(id)) return { error: "İşletme bulunamadı.", ok: false };
  if (!["active", "suspended", "cancelled"].includes(status)) return { error: "Durum tanınmadı.", ok: false };
  if (reason.length < 3) return { error: "Bir neden yazın (en az 3 karakter).", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("rpc_platform_set_business_status", { p_business_id: id, p_status: status, p_reason: reason });
  if (error) return { error: reportDbError("set business status", error), ok: false };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true };
}

export async function setSubscriptionStatusAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const id = String(formData.get("subscription_id") ?? "");
  const status = String(formData.get("status") ?? "");
  const note = String(formData.get("note") ?? "").trim();
  if (!UUID.test(id)) return { error: "Abonelik bulunamadı.", ok: false };
  // "active" is not offered: a subscription becomes active only when its invoice is paid (13B)
  if (!["pending", "past_due", "cancelled", "expired"].includes(status)) return { error: "Durum tanınmadı.", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("rpc_platform_set_subscription_status", { p_subscription_id: id, p_status: status, p_note: note || null });
  if (error) return { error: reportDbError("set subscription status", error), ok: false };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true };
}

export async function upsertPlanAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const code = String(formData.get("code") ?? "").trim().toLowerCase();
  const name = String(formData.get("name") ?? "").trim();
  const description = String(formData.get("description") ?? "").trim();
  const interval = String(formData.get("billing_interval") ?? "");
  const price = Number(String(formData.get("price_amount") ?? "").replace(",", "."));
  const currency = String(formData.get("currency") ?? "");
  const isActive = formData.get("is_active") === "on";
  const sortOrder = Number.parseInt(String(formData.get("sort_order") ?? "100"), 10);
  if (!/^[a-z0-9_]{2,40}$/.test(code)) return { error: "Kod 2–40 karakter, küçük harf, rakam ve alt çizgi olmalı.", ok: false };
  if (name.length < 2 || name.length > 80) return { error: "Plan adı gerekli.", ok: false };
  if (interval !== "monthly" && interval !== "annual") return { error: "Dönem aylık ya da yıllık olmalı.", ok: false };
  if (!Number.isFinite(price) || price < 0) return { error: "Fiyat sıfır ya da pozitif olmalı.", ok: false };
  if (!["TRY", "EUR", "USD", "GBP"].includes(currency)) return { error: "Para birimini listeden seçin.", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("rpc_platform_upsert_plan", {
    p_code: code,
    p_name: name,
    p_description: description || null,
    p_billing_interval: interval,
    p_price_amount: price,
    p_currency: currency,
    p_is_active: isActive,
    p_sort_order: Number.isFinite(sortOrder) ? sortOrder : 100,
  });
  if (error) return { error: reportDbError("upsert plan", error), ok: false };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true };
}

// ---------------------------------------------------------------- billing (Phase 13B, manual billing only)

const PAYMENT_METHODS = ["bank_transfer", "cash_manual", "other_manual"];

export async function issueInvoiceAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const id = String(formData.get("subscription_id") ?? "");
  const note = String(formData.get("note") ?? "").trim();
  if (!UUID.test(id)) return { error: "Abonelik bulunamadı.", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_issue_invoice", { p_subscription_id: id, p_note: note || null });
  if (error) return { error: reportDbError("issue invoice", error), ok: false };
  const result = data as { invoice_id: string };
  revalidatePath("/platform", "layout");
  redirect(`/platform/faturalar/${result.invoice_id}`);
}

export async function recordPaymentAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const id = String(formData.get("invoice_id") ?? "");
  const amount = Number(String(formData.get("amount") ?? "").replace(",", "."));
  const currency = String(formData.get("currency") ?? "");
  const method = String(formData.get("method") ?? "");
  const reference = String(formData.get("reference") ?? "").trim();
  const paidAt = String(formData.get("paid_at") ?? "").trim();
  const note = String(formData.get("note") ?? "").trim();
  if (!UUID.test(id)) return { error: "Fatura bulunamadı.", ok: false };
  if (!Number.isFinite(amount) || amount <= 0) return { error: "Tutar sıfırdan büyük olmalı.", ok: false };
  if (Math.round(amount * 100) !== amount * 100) return { error: "Tutar en fazla iki ondalık basamak taşır.", ok: false };
  if (!["TRY", "EUR", "USD", "GBP"].includes(currency)) return { error: "Para birimini listeden seçin.", ok: false };
  if (!PAYMENT_METHODS.includes(method)) return { error: "Ödeme yöntemini listeden seçin.", ok: false };
  if (reference.length < 2) return { error: "Havale / makbuz referansı gerekli (en az 2 karakter).", ok: false };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(paidAt)) return { error: "Ödeme tarihini seçin.", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("rpc_platform_record_payment", {
    p_invoice_id: id,
    p_amount: amount,
    p_currency: currency,
    p_method: method,
    p_reference: reference,
    p_paid_at: new Date(`${paidAt}T12:00:00Z`).toISOString(),
    p_note: note || null,
  });
  if (error) return { error: reportDbError("record payment", error), ok: false };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true };
}

export async function voidInvoiceAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const id = String(formData.get("invoice_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  if (!UUID.test(id)) return { error: "Fatura bulunamadı.", ok: false };
  if (reason.length < 3) return { error: "Bir neden yazın (en az 3 karakter).", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("rpc_platform_void_invoice", { p_invoice_id: id, p_reason: reason });
  if (error) return { error: reportDbError("void invoice", error), ok: false };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true };
}

export async function cancelSubscriptionAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const id = String(formData.get("subscription_id") ?? "");
  const mode = String(formData.get("mode") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  if (!UUID.test(id)) return { error: "Abonelik bulunamadı.", ok: false };
  if (!["at_period_end", "immediate", "keep"].includes(mode)) return { error: "İptal biçimi tanınmadı.", ok: false };
  if (reason.length < 3) return { error: "Bir neden yazın (en az 3 karakter).", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("rpc_platform_cancel_subscription", { p_subscription_id: id, p_mode: mode, p_reason: reason });
  if (error) return { error: reportDbError("cancel subscription", error), ok: false };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true };
}

export async function billingSweepAction(_prev: PlatformActionState, _formData: FormData): Promise<PlatformActionState> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_billing_sweep");
  if (error) return { error: reportDbError("billing sweep", error), ok: false };
  const r = data as { marked_past_due: number; cancelled_at_period_end: number };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true, message: `${r.marked_past_due} abonelik gecikmiş işaretlendi, ${r.cancelled_at_period_end} dönem sonu iptali uygulandı.` };
}

export async function setBillingSettingAction(_prev: PlatformActionState, formData: FormData): Promise<PlatformActionState> {
  const key = String(formData.get("key") ?? "");
  const value = Number.parseInt(String(formData.get("value") ?? ""), 10);
  if (!["invoice_due_days", "billing_grace_days"].includes(key)) return { error: "Ayar tanınmadı.", ok: false };
  if (!Number.isFinite(value) || value < 0 || value > 365) return { error: "0–365 gün arasında bir değer girin.", ok: false };
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("rpc_platform_set_billing_setting", { p_key: key, p_value: value });
  if (error) return { error: reportDbError("set billing setting", error), ok: false };
  revalidatePath("/platform", "layout");
  return { error: null, ok: true };
}
