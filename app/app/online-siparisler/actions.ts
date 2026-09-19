"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";
import { reportDbError } from "@/lib/db-errors";
import { orderCaps, type OrderActionState } from "@/lib/orders/model";

/**
 * Merchant order transitions. Each one is a single RPC that re-proves the role in the
 * database; the actions only shape the form input. Nothing here touches stock or money:
 * the hold lives in the reservation engine and the sale happens at the POS.
 */
const UUID = /^[0-9a-f-]{36}$/i;

async function ctx() {
  const { active } = await requireTenant();
  const supabase = await createClient();
  return { active, supabase, caps: orderCaps(active.role) };
}

function done() {
  revalidatePath("/app/online-siparisler", "layout");
  revalidatePath("/app/rezervasyonlar");
  return { error: null, ok: true } as OrderActionState;
}

export async function confirmOrderAction(_prev: OrderActionState, formData: FormData): Promise<OrderActionState> {
  const { active, supabase, caps } = await ctx();
  if (!caps.canConfirm) return { error: "Siparişi yalnız sahip ve yöneticiler onaylar.", ok: false };
  const id = String(formData.get("order_id") ?? "");
  if (!UUID.test(id)) return { error: "Sipariş bulunamadı.", ok: false };
  const { error } = await supabase.rpc("rpc_online_order_confirm", { p_business_id: active.business_id, p_order_id: id });
  if (error) return { error: reportDbError("confirm online order", error), ok: false };
  return done();
}

export async function readyOrderAction(_prev: OrderActionState, formData: FormData): Promise<OrderActionState> {
  const { active, supabase, caps } = await ctx();
  if (!caps.canReady) return { error: "Bu işlem için yetkiniz yok.", ok: false };
  const id = String(formData.get("order_id") ?? "");
  if (!UUID.test(id)) return { error: "Sipariş bulunamadı.", ok: false };
  const { error } = await supabase.rpc("rpc_online_order_ready", { p_business_id: active.business_id, p_order_id: id });
  if (error) return { error: reportDbError("ready online order", error), ok: false };
  return done();
}

export async function cancelOrderAction(_prev: OrderActionState, formData: FormData): Promise<OrderActionState> {
  const { active, supabase, caps } = await ctx();
  if (!caps.canCancel) return { error: "Siparişi yalnız sahip ve yöneticiler iptal eder.", ok: false };
  const id = String(formData.get("order_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  if (!UUID.test(id)) return { error: "Sipariş bulunamadı.", ok: false };
  if (reason.length < 3) return { error: "Bir neden yazın (en az 3 karakter).", ok: false };
  const { error } = await supabase.rpc("rpc_online_order_cancel", { p_business_id: active.business_id, p_order_id: id, p_reason: reason });
  if (error) return { error: reportDbError("cancel online order", error), ok: false };
  return done();
}

export async function rereserveOrderAction(_prev: OrderActionState, formData: FormData): Promise<OrderActionState> {
  const { active, supabase, caps } = await ctx();
  if (!caps.canRereserve) return { error: "Yeniden ayırmayı yalnız sahip ve yöneticiler yapar.", ok: false };
  const id = String(formData.get("order_id") ?? "");
  if (!UUID.test(id)) return { error: "Sipariş bulunamadı.", ok: false };
  const { error } = await supabase.rpc("rpc_online_order_rereserve", { p_business_id: active.business_id, p_order_id: id });
  if (error) return { error: reportDbError("re-reserve online order", error), ok: false };
  return done();
}
