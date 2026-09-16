"use server";

import { revalidatePath } from "next/cache";
import { loadCrmContext, probeDuplicates, searchCustomers } from "@/lib/crm/queries";
import type { CustomerHit, CustomerInput, DuplicateHit } from "@/lib/crm/model";
import { reportDbError } from "@/lib/db-errors";
import type { Result } from "@/lib/catalog/intake";

/**
 * Customer writes go through RLS-guarded rows (owner / manager / sales_staff, active
 * tenant); the database normalises contact data, validates the source and stamps
 * created_by. Duplicates are never merged: the server probes the normalised phone /
 * email / instagram and refuses to save a match unless a manager confirmed it is a
 * different person. Nothing here is logged with customer data in it.
 */

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";
const UUID = /^[0-9a-fA-F-]{36}$/;
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function clean(v: unknown, max: number): string | null {
  const t = typeof v === "string" ? v.trim().slice(0, max) : "";
  return t ? t : null;
}
function validate(input: CustomerInput): { ok: true; data: Omit<CustomerInput, "confirm_duplicate"> } | { ok: false; error: string } {
  const full_name = clean(input.full_name, 120);
  if (!full_name) return { ok: false, error: "Ad Soyad gerekli." };
  const email = clean(input.email, 120);
  if (email && !EMAIL.test(email)) return { ok: false, error: "E-posta biçimi geçersiz." };
  const phone = clean(input.phone, 32);
  if (phone && phone.replace(/\D/g, "").length < 7) return { ok: false, error: "Telefon en az 7 rakam içermeli." };
  return { ok: true, data: { full_name, phone, email, instagram: clean(input.instagram, 60)?.replace(/^@+/, "") ?? null, source: clean(input.source, 40), notes: clean(input.notes, 500) } };
}

export async function searchCustomersAction(query: string): Promise<Result<CustomerHit[]>> {
  const { caps } = await loadCrmContext();
  if (!caps.canAccessCrm) return { ok: false, error: NO_PERMISSION };
  try {
    return { ok: true, data: await searchCustomers(query ?? "") };
  } catch {
    return { ok: false, error: "Arama yapılamadı. Tekrar deneyin." };
  }
}

export async function duplicateProbeAction(input: { phone: string | null; email: string | null; instagram: string | null; excludeId?: string | null }): Promise<Result<DuplicateHit[]>> {
  const { caps } = await loadCrmContext();
  if (!caps.canAccessCrm) return { ok: false, error: NO_PERMISSION };
  try {
    return { ok: true, data: await probeDuplicates({ phone: clean(input.phone, 32), email: clean(input.email, 120), instagram: clean(input.instagram, 60), excludeId: input.excludeId && UUID.test(input.excludeId) ? input.excludeId : null }) };
  } catch {
    return { ok: false, error: "Benzer kayıt kontrolü yapılamadı." };
  }
}

export async function createCustomerAction(input: CustomerInput): Promise<Result<{ id: string; duplicates?: DuplicateHit[] }>> {
  const { supabase, businessId, caps } = await loadCrmContext();
  if (!caps.canAccessCrm) return { ok: false, error: NO_PERMISSION };
  const v = validate(input);
  if (!v.ok) return v;
  const dups = await probeDuplicates({ phone: v.data.phone, email: v.data.email, instagram: v.data.instagram });
  if (dups.length > 0 && !(input.confirm_duplicate && caps.canManage)) {
    return { ok: false, error: caps.canManage ? "Aynı telefon/e-posta/Instagram ile kayıtlı müşteri var. Farklı bir kişiyse onaylayıp kaydedin." : "Aynı telefon/e-posta/Instagram ile kayıtlı müşteri var. Mevcut kaydı kullanın; ayrı kayıt yönetici onayı ister." };
  }
  const { data, error } = await supabase.from("customers").insert({ business_id: businessId, ...v.data }).select("id").single();
  if (error) return { ok: false, error: reportDbError("createCustomer", error) };
  revalidatePath("/app/musteriler");
  return { ok: true, data: { id: data.id as string } };
}

export async function updateCustomerAction(id: string, input: CustomerInput): Promise<Result<{ id: string }>> {
  const { supabase, businessId, caps } = await loadCrmContext();
  if (!caps.canAccessCrm) return { ok: false, error: NO_PERMISSION };
  if (!UUID.test(id ?? "")) return { ok: false, error: "Müşteri bulunamadı." };
  const v = validate(input);
  if (!v.ok) return v;
  const dups = await probeDuplicates({ phone: v.data.phone, email: v.data.email, instagram: v.data.instagram, excludeId: id });
  if (dups.length > 0 && !(input.confirm_duplicate && caps.canManage)) {
    return { ok: false, error: caps.canManage ? "Bu iletişim bilgisi başka bir müşteride kayıtlı. Farklı bir kişiyse onaylayıp kaydedin." : "Bu iletişim bilgisi başka bir müşteride kayıtlı; ayrı kayıt yönetici onayı ister." };
  }
  const { data, error } = await supabase.from("customers").update(v.data).eq("business_id", businessId).eq("id", id).select("id").maybeSingle();
  if (error) return { ok: false, error: reportDbError("updateCustomer", error) };
  if (!data) return { ok: false, error: "Müşteri bulunamadı." };
  revalidatePath("/app/musteriler");
  revalidatePath(`/app/musteriler/${id}`);
  return { ok: true, data: { id } };
}

export async function setCustomerActiveAction(id: string, active: boolean): Promise<Result<{ id: string }>> {
  const { supabase, businessId, caps } = await loadCrmContext();
  if (!caps.canManage) return { ok: false, error: NO_PERMISSION };
  if (!UUID.test(id ?? "")) return { ok: false, error: "Müşteri bulunamadı." };
  const { error } = await supabase.from("customers").update({ is_active: active }).eq("business_id", businessId).eq("id", id);
  if (error) return { ok: false, error: reportDbError("setCustomerActive", error) };
  revalidatePath("/app/musteriler");
  revalidatePath(`/app/musteriler/${id}`);
  return { ok: true, data: { id } };
}
