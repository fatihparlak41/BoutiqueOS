"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { authDestinationUrl } from "@/lib/url";
import { PASSWORD_MIN_LENGTH } from "@/lib/auth/password";
import { isBusinessType, isCountry, isCurrency, type RegisterState } from "@/lib/saas/model";

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const GENERIC = "Kayıt tamamlanamadı. Lütfen tekrar deneyin.";

async function currentOrigin(): Promise<string | undefined> {
  const h = await headers();
  const host = h.get("x-forwarded-host") ?? h.get("host");
  if (!host) return undefined;
  const proto = h.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  return `${proto}://${host}`;
}

/**
 * Public registration: creates the Auth account and keeps the business draft in the
 * signup metadata until the address is confirmed. Nothing is written to the tenant
 * schema here — the application itself is submitted on /basvuru, by a confirmed user,
 * through rpc_submit_business_application, and a business exists only after platform
 * approval.
 *
 * The answer is the same whether or not the address already has an account: Auth
 * returns an obfuscated user for a known address instead of an error, and this action
 * never says which happened.
 */
export async function registerAction(_prev: RegisterState, formData: FormData): Promise<RegisterState> {
  const fullName = String(formData.get("full_name") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  const password = String(formData.get("password") ?? "");
  const businessName = String(formData.get("business_name") ?? "").trim();
  const country = String(formData.get("country") ?? "").trim();
  const currency = String(formData.get("currency") ?? "").trim();
  const phone = String(formData.get("phone") ?? "").trim();
  const businessType = String(formData.get("business_type") ?? "").trim();
  const planId = String(formData.get("plan_id") ?? "").trim();

  if (fullName.length < 2 || fullName.length > 120) return { error: "Ad Soyad gerekli.", done: false, email: null };
  if (!EMAIL_RE.test(email)) return { error: "Geçerli bir e-posta adresi girin.", done: false, email: null };
  if (password.length < PASSWORD_MIN_LENGTH) return { error: `Parola en az ${PASSWORD_MIN_LENGTH} karakter olmalı.`, done: false, email: null };
  if (businessName.length < 2 || businessName.length > 120) return { error: "İşletme adı gerekli.", done: false, email: null };
  if (!isCountry(country)) return { error: "Ülkeyi listeden seçin.", done: false, email: null };
  if (!isCurrency(currency)) return { error: "Para birimini listeden seçin.", done: false, email: null };
  if (businessType && !isBusinessType(businessType)) return { error: "İşletme türünü listeden seçin.", done: false, email: null };
  if (phone && !/^[+0-9 ()-]{6,24}$/.test(phone)) return { error: "Telefon numarası geçersiz.", done: false, email: null };

  const supabase = await createClient();

  // The plan is validated against the live catalogue; an unknown id is dropped rather
  // than refused, the applicant picks again on /basvuru.
  let plan: string | null = null;
  if (planId) {
    const { data: plans } = await supabase.rpc("rpc_saas_plans");
    const rows = (plans ?? []) as Array<{ id: string }>;
    plan = rows.some((p) => p.id === planId) ? planId : null;
  }

  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: authDestinationUrl("/basvuru", await currentOrigin()),
      data: {
        full_name: fullName,
        application: {
          business_name: businessName,
          country,
          currency,
          phone: phone || null,
          business_type: businessType || null,
          plan_id: plan,
        },
      },
    },
  });

  if (error) {
    console.error("[auth] signup failed:", error.status, error.code);
    if (error.code === "weak_password") return { error: "Parola yeterince güçlü değil. Daha uzun ve karışık bir parola seçin.", done: false, email: null };
    if (error.code === "over_email_send_rate_limit" || error.status === 429) return { error: "Çok sık deneme yapıldı. Birkaç dakika sonra tekrar deneyin.", done: false, email: null };
    return { error: GENERIC, done: false, email: null };
  }

  // Confirmations are required on this project, so no session comes back here. If a
  // deployment ever auto-confirms, the visitor is signed in and continues directly.
  if (data.session) redirect("/basvuru");

  return { error: null, done: true, email };
}
