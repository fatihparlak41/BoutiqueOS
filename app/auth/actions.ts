"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
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
export async function selectBusinessAction(formData: FormData) {
  const businessId = String(formData.get("business_id") ?? "");
  const { memberships } = await loadMemberships();

  if (!memberships.some((m) => m.business_id === businessId)) {
    redirect("/select-business?error=not-a-member");
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
