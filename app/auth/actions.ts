"use server";

import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { authDestinationUrl } from "@/lib/url";
import { PASSWORD_MIN_LENGTH } from "@/lib/auth/password";
import { ACTIVE_BUSINESS_COOKIE, loadMemberships } from "@/lib/tenant";

export type SignInState = { error: string | null };

/** Email + password sign-in. V1 has no public registration; accounts are created by invitation. */
export async function signInAction(_prev: SignInState, formData: FormData): Promise<SignInState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");

  if (!email || !password) {
    return { error: "E-posta ve parola gerekli." };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    // Do not leak whether the address exists.
    const message =
      error.status === 400 || error.status === 401
        ? "E-posta veya parola hatalı."
        : "Giriş yapılamadı. Lütfen tekrar deneyin.";
    return { error: message };
  }

  revalidatePath("/", "layout");
  redirect("/app");
}

export async function signOutAction() {
  const supabase = await createClient();
  await supabase.auth.signOut();

  const cookieStore = await cookies();
  cookieStore.delete(ACTIVE_BUSINESS_COOKIE);

  revalidatePath("/", "layout");
  redirect("/login");
}

/**
 * Stores which business the user is working in. The value is only accepted after the
 * membership has been re-proved against PostgreSQL, and every protected page re-checks
 * it again — the cookie can never grant access on its own.
 */
export type SelectBusinessState = { error: string | null };

export async function selectBusinessAction(
  _prev: SelectBusinessState,
  formData: FormData,
): Promise<SelectBusinessState> {
  const businessId = String(formData.get("business_id") ?? "");
  const { memberships } = await loadMemberships();

  if (!memberships.some((m) => m.business_id === businessId)) {
    return { error: "Bu işletmede aktif bir üyeliğiniz yok." };
  }

  const cookieStore = await cookies();
  cookieStore.set(ACTIVE_BUSINESS_COOKIE, businessId, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });

  redirect("/app");
}

// ------------------------------------------------------------------ password recovery

export type ResetRequestState = { done: boolean; error: string | null };
export type SetPasswordState = { error: string | null };

/** Canonical origin for auth links: configuration first, request host only as a fallback. */
async function currentOrigin(): Promise<string | undefined> {
  const h = await headers();
  const host = h.get("x-forwarded-host") ?? h.get("host");
  if (!host) return undefined;
  const proto = h.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  return `${proto}://${host}`;
}

/**
 * "Şifremi unuttum". The answer never depends on whether the address exists: an
 * enumeration oracle here would leak the tenant's staff list one guess at a time.
 */
export async function requestPasswordResetAction(
  _prev: ResetRequestState,
  formData: FormData,
): Promise<ResetRequestState> {
  const email = String(formData.get("email") ?? "").trim().toLowerCase();

  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return { done: false, error: "Geçerli bir e-posta adresi girin." };
  }

  const supabase = await createClient();
  await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: authDestinationUrl("/sifre-belirle", await currentOrigin()),
  });

  // The result of the call above is deliberately not inspected.
  return { done: true, error: null };
}

/**
 * Sets a new password for whoever holds the recovery session. The old password is not
 * required because the mailbox proved possession; no administrator ever sees either.
 */
export async function setPasswordAction(
  _prev: SetPasswordState,
  formData: FormData,
): Promise<SetPasswordState> {
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("password_confirm") ?? "");

  if (password.length < PASSWORD_MIN_LENGTH) {
    return { error: `Parola en az ${PASSWORD_MIN_LENGTH} karakter olmalı.` };
  }
  if (password !== confirm) {
    return { error: "Parolalar eşleşmiyor." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return { error: "Bağlantının süresi dolmuş. Yeni bir sıfırlama bağlantısı isteyin." };
  }

  const { error } = await supabase.auth.updateUser({ password });
  if (error) {
    return { error: "Parola güncellenemedi. Farklı bir parola deneyin." };
  }

  revalidatePath("/", "layout");
  redirect("/app");
}
