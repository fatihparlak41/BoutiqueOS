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
  if (!["pending", "active", "past_due", "cancelled", "expired"].includes(status)) return { error: "Durum tanınmadı.", ok: false };
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
