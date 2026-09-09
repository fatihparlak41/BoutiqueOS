"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { loadReceivingContext } from "@/lib/receiving/queries";
import { CURRENCIES, type Currency, type SupplierStatus } from "@/lib/receiving/model";
import { reportDbError } from "@/lib/db-errors";
import type { ActionState } from "@/lib/catalog/action-state";

/**
 * Supplier writes. business_id comes from the tenant context, never from the form, and
 * pol_suppliers_write (fn_is_manager_plus) re-checks it on the row.
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

function isStatus(value: string): value is SupplierStatus {
  return value === "active" || value === "inactive";
}

type ParsedFields =
  | { ok: false; error: string }
  | { ok: true; values: Record<string, string | null> };

function readFields(formData: FormData): ParsedFields {
  const name = text(formData, "name");
  const currency = text(formData, "currency");
  const status = text(formData, "status");

  if (name.length < 2) return { ok: false, error: "Tedarikçi adı en az 2 karakter olmalı." };
  if (name.length > 120) return { ok: false, error: "Tedarikçi adı en fazla 120 karakter olabilir." };
  if (!isCurrency(currency)) return { ok: false, error: "Desteklenmeyen para birimi." };
  if (!isStatus(status)) return { ok: false, error: "Geçersiz durum." };

  return {
    ok: true,
    values: {
      name,
      currency,
      status,
      code: optionalText(formData, "code"),
      contact_name: optionalText(formData, "contact_name"),
      phone: optionalText(formData, "phone"),
      email: optionalText(formData, "email"),
      city: optionalText(formData, "city"),
      country: text(formData, "country") || "TR",
      notes: optionalText(formData, "notes"),
    },
  };
}

export async function createSupplierAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteSupplier) return fail(NO_PERMISSION);

  const parsed = readFields(formData);
  if (!parsed.ok) return fail(parsed.error);

  const { error } = await supabase
    .from("suppliers")
    .insert({ business_id: businessId, ...parsed.values });

  if (error) return fail(reportDbError("createSupplier", error));

  revalidatePath("/app/tedarikciler");
  redirect("/app/tedarikciler");
}

export async function updateSupplierAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadReceivingContext();
  if (!caps.canWriteSupplier) return fail(NO_PERMISSION);

  const supplierId = uuidOrNull(formData, "supplier_id");
  if (!supplierId) return fail("Tedarikçi bulunamadı.");

  const parsed = readFields(formData);
  if (!parsed.ok) return fail(parsed.error);

  const { error } = await supabase
    .from("suppliers")
    .update({ ...parsed.values, updated_at: new Date().toISOString() })
    .eq("business_id", businessId)
    .eq("id", supplierId);

  if (error) return fail(reportDbError("updateSupplier", error));

  revalidatePath("/app/tedarikciler");
  return DONE;
}
