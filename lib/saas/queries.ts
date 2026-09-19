import "server-only";

import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { withFreshJwtRetry } from "@/lib/auth/jwt-skew";
import { tenantReadOutcome } from "@/lib/auth/session-ready";
import { readApplicationDraft, type ApplicationDraft, type MyBilling, type MyOnboarding, type PublicPlan } from "@/lib/saas/model";

/**
 * Read side of onboarding. Every call is one RPC that authorises itself: the public
 * catalogue is readable by anyone, the applicant summary answers only about the caller,
 * and the platform console (lib/platform/queries.ts) requires the platform role.
 */

/** Active plans, for the registration page (anon) and the applicant pages. */
export const getPublicPlans = cache(async (): Promise<PublicPlan[]> => {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_saas_plans");
  if (error) throw new Error(`Planlar okunamadı: ${error.message}`);
  return (data ?? []) as PublicPlan[];
});

/**
 * The signed-in visitor's onboarding picture — application, inactive memberships,
 * platform flag — plus the draft the registration stored in the signup metadata.
 * A freshly minted token (right after the confirmation link) may be refused for a
 * moment; that one condition retries and then parks on /auth/session-ready.
 */
export const getMyOnboarding = cache(async (): Promise<{ userId: string; email: string | null; confirmed: boolean; onboarding: MyOnboarding; draft: ApplicationDraft | null; fullName: string | null }> => {
  const supabase = await createClient();
  const { data: claimsData } = await supabase.auth.getClaims();
  if (!claimsData?.claims?.sub) redirect("/login");
  const userId = String(claimsData.claims.sub);
  const email = typeof claimsData.claims.email === "string" ? claimsData.claims.email : null;

  const { user, onboarding } = await withFreshJwtRetry(async () => {
    const [userRes, rpc] = await Promise.all([supabase.auth.getUser(), supabase.rpc("rpc_my_onboarding")]);
    return { user: userRes.data.user, onboarding: rpc.data as MyOnboarding | null, error: rpc.error };
  }).then((r) => {
    if (r.error) {
      const outcome = tenantReadOutcome("Başvuru durumu okunamadı", r.error, "/basvuru");
      if (outcome.kind === "redirect") redirect(outcome.to);
      throw new Error(outcome.kind === "throw" ? outcome.message : r.error.message);
    }
    return r;
  });

  const meta = (user?.user_metadata ?? {}) as Record<string, unknown>;
  return {
    userId,
    email: user?.email ?? email,
    confirmed: Boolean(user?.email_confirmed_at),
    onboarding: onboarding ?? { platform_admin: false, application: null, inactive_businesses: [] },
    draft: readApplicationDraft(meta),
    fullName: typeof meta.full_name === "string" ? meta.full_name : null,
  };
});

/**
 * Where a signed-in visitor with no active membership belongs. Called by requireTenant
 * only in that branch, so the normal bootstrap costs nothing extra.
 */
export async function noTenantDestination(): Promise<string> {
  const { onboarding, draft } = await getMyOnboarding();
  if (onboarding.platform_admin) return "/platform";
  if (onboarding.application?.status === "pending") return "/basvuru-bekliyor";
  if (onboarding.inactive_businesses.length > 0) return "/hesap-durumu";
  // registered, confirmed, never submitted: the draft from /kayit is waiting to be sent
  if (!onboarding.application && draft) return "/basvuru";
  return "/no-access";
}

/**
 * The owner's own commercial record (Phase 13B). One RPC that proves the owner role in
 * the database; managers and staff get FORBIDDEN, which the page never reaches because
 * it checks the role first. Nothing here can mutate anything.
 */
export async function getMyBilling(businessId: string): Promise<MyBilling> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_my_billing", { p_business_id: businessId });
  if (error) throw new Error(`Abonelik bilgisi okunamadı: ${error.message}`);
  return data as MyBilling;
}
