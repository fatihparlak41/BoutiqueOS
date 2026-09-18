"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { reportDbError } from "@/lib/db-errors";
import { getMyOnboarding } from "@/lib/saas/queries";
import { isBusinessType, isCountry, isCurrency, type ApplyState } from "@/lib/saas/model";

/**
 * Submits the business application through rpc_submit_business_application. The RPC
 * proves the caller is a confirmed user, keeps one open application per person and
 * replays the existing one on a double submit; nothing tenant-side is created here.
 */
export async function submitApplicationAction(_prev: ApplyState, formData: FormData): Promise<ApplyState> {
  const businessName = String(formData.get("business_name") ?? "").trim();
  const country = String(formData.get("country") ?? "").trim();
  const currency = String(formData.get("currency") ?? "").trim();
  const phone = String(formData.get("phone") ?? "").trim();
  const businessType = String(formData.get("business_type") ?? "").trim();
  const planId = String(formData.get("plan_id") ?? "").trim();

  if (businessName.length < 2 || businessName.length > 120) return { error: "İşletme adı gerekli." };
  if (!isCountry(country)) return { error: "Ülkeyi listeden seçin." };
  if (!isCurrency(currency)) return { error: "Para birimini listeden seçin." };
  if (businessType && !isBusinessType(businessType)) return { error: "İşletme türünü listeden seçin." };
  if (phone && !/^[+0-9 ()-]{6,24}$/.test(phone)) return { error: "Telefon numarası geçersiz." };

  const { fullName } = await getMyOnboarding();
  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_submit_business_application", {
    p_business_name: businessName,
    p_country: country,
    p_currency: currency,
    p_phone: phone || null,
    p_business_type: businessType || null,
    p_branch_name: "Merkez",
    p_plan_id: planId || null,
    p_full_name: fullName,
  });
  if (error) return { error: reportDbError("submit application", error) };

  revalidatePath("/", "layout");
  redirect("/basvuru-bekliyor");
}

/** Withdraws the caller's open application (kept as history; a new one may follow). */
export async function withdrawApplicationAction(_prev: ApplyState, formData: FormData): Promise<ApplyState> {
  const id = String(formData.get("application_id") ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(id)) return { error: "Başvuru bulunamadı." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_withdraw_business_application", { p_application_id: id });
  if (error) return { error: reportDbError("withdraw application", error) };
  revalidatePath("/", "layout");
  redirect("/basvuru");
}

/** Sends the confirmation e-mail again for an account that registered but never opened its link. */
export async function resendConfirmationAction(_prev: ApplyState): Promise<ApplyState> {
  const { email, confirmed } = await getMyOnboarding();
  if (confirmed || !email) return { error: null };
  const supabase = await createClient();
  const { error } = await supabase.auth.resend({ type: "signup", email });
  if (error) {
    console.error("[auth] resend confirmation failed:", error.status, error.code);
    return { error: "Doğrulama e-postası şu anda gönderilemedi. Birkaç dakika sonra tekrar deneyin." };
  }
  return { error: null };
}
