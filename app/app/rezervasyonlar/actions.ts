"use server";

import { revalidatePath } from "next/cache";
import { loadCrmContext } from "@/lib/crm/queries";
import type { ReservationInput } from "@/lib/crm/model";
import { reportDbError } from "@/lib/db-errors";
import type { Result } from "@/lib/catalog/intake";

/**
 * Reservation writes are RPC-only: rpc_pos_reservation_create / rpc_reservation_update
 * lock the variants' pool rows, compute available = sellable − active unexpired holds and
 * write all or nothing; rpc_reservation_cancel releases at once; rpc_reservations_expire
 * is a cleanup (availability never depends on it). Fulfilment is a POS sale carrying
 * p_reservation_id (app/app/pos/actions.ts) — never a cancel followed by a sale.
 */

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";
const UUID = /^[0-9a-fA-F-]{36}$/;
const MAX_HOLD_DAYS = 90;

function validItems(items: unknown): items is Array<{ variant_id: string; quantity: number }> {
  return Array.isArray(items) && items.length > 0 && items.length <= 50
    && items.every((i) => i && UUID.test(String(i.variant_id)) && Number.isInteger(i.quantity) && i.quantity > 0 && i.quantity <= 999);
}
function validExpiry(raw: string | null): { ok: true; value: string | null } | { ok: false; error: string } {
  if (!raw) return { ok: true, value: null };
  const d = new Date(raw);
  if (Number.isNaN(d.getTime())) return { ok: false, error: "Son tarih geçersiz." };
  if (d.getTime() <= Date.now()) return { ok: false, error: "Son tarih ileride olmalı." };
  if (d.getTime() > Date.now() + MAX_HOLD_DAYS * 86400000) return { ok: false, error: `Rezervasyon en fazla ${MAX_HOLD_DAYS} gün tutulabilir.` };
  return { ok: true, value: d.toISOString() };
}
function revalidate(id?: string) {
  revalidatePath("/app/rezervasyonlar");
  revalidatePath("/app/pos");
  revalidatePath("/app/stok");
  if (id) revalidatePath(`/app/rezervasyonlar/${id}`);
}

export async function createReservationAction(input: ReservationInput): Promise<Result<{ id: string; reservation_number: string; expires_at: string }>> {
  const { supabase, caps } = await loadCrmContext();
  if (!caps.canAccessCrm) return { ok: false, error: NO_PERMISSION };
  if (!input || !UUID.test(input.branch_id) || !UUID.test(input.customer_id)) return { ok: false, error: "Müşteri ve şube seçilmeli." };
  if (!validItems(input.items)) return { ok: false, error: "Rezervasyon satırı geçersiz." };
  const exp = validExpiry(input.expires_at);
  if (!exp.ok) return exp;
  const { data, error } = await supabase.rpc("rpc_pos_reservation_create", {
    p_branch_id: input.branch_id, p_customer_id: input.customer_id,
    p_items: input.items.map((i) => ({ variant_id: i.variant_id, quantity: i.quantity })),
    p_expires_at: exp.value, p_note: input.note?.trim().slice(0, 300) || null, p_source: input.source?.trim().slice(0, 40) || null,
  });
  if (error) return { ok: false, error: reportDbError("createReservation", error) };
  const r = (data ?? {}) as Record<string, unknown>;
  revalidate();
  return { ok: true, data: { id: String(r.reservation_id), reservation_number: String(r.reservation_number), expires_at: String(r.expires_at) } };
}

export async function updateReservationAction(id: string, input: { items: Array<{ variant_id: string; quantity: number }>; expires_at: string | null; note: string | null }): Promise<Result<{ id: string }>> {
  const { supabase, caps } = await loadCrmContext();
  if (!caps.canAccessCrm) return { ok: false, error: NO_PERMISSION };
  if (!UUID.test(id ?? "")) return { ok: false, error: "Rezervasyon bulunamadı." };
  if (!validItems(input?.items)) return { ok: false, error: "Rezervasyon satırı geçersiz." };
  const exp = validExpiry(input.expires_at);
  if (!exp.ok) return exp;
  const { error } = await supabase.rpc("rpc_reservation_update", {
    p_reservation_id: id, p_items: input.items.map((i) => ({ variant_id: i.variant_id, quantity: i.quantity })),
    p_expires_at: exp.value, p_note: input.note?.trim().slice(0, 300) || null,
  });
  if (error) return { ok: false, error: reportDbError("updateReservation", error) };
  revalidate(id);
  return { ok: true, data: { id } };
}

export async function cancelReservationAction(id: string, reason: string | null): Promise<Result<{ id: string; status: string }>> {
  const { supabase, caps } = await loadCrmContext();
  if (!caps.canAccessCrm) return { ok: false, error: NO_PERMISSION };
  if (!UUID.test(id ?? "")) return { ok: false, error: "Rezervasyon bulunamadı." };
  const { data, error } = await supabase.rpc("rpc_reservation_cancel", { p_reservation_id: id, p_reason: reason?.trim().slice(0, 200) || null });
  if (error) return { ok: false, error: reportDbError("cancelReservation", error) };
  revalidate(id);
  return { ok: true, data: { id, status: String((data as Record<string, unknown> | null)?.status ?? "cancelled") } };
}

export async function expireReservationsAction(): Promise<Result<{ count: number }>> {
  const { supabase, businessId, caps } = await loadCrmContext();
  if (!caps.canAccessCrm) return { ok: false, error: NO_PERMISSION };
  const { data, error } = await supabase.rpc("rpc_reservations_expire", { p_business_id: businessId });
  if (error) return { ok: false, error: reportDbError("expireReservations", error) };
  revalidate();
  return { ok: true, data: { count: Number(data ?? 0) } };
}
