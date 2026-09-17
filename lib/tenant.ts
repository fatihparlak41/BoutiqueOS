import "server-only";

import { cache } from "react";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { withFreshJwtRetry } from "@/lib/auth/jwt-skew";
import { tenantReadOutcome } from "@/lib/auth/session-ready";
import type { UserRole } from "@/lib/roles";

export const ACTIVE_BUSINESS_COOKIE = "bos_active_business";

/**
 * One exit for every failed tenant read. A token PostgREST is not yet willing to
 * accept (PGRST303 "JWT issued at future", seen live right after a password update)
 * is not a fault of this page: the visitor is parked on /auth/session-ready, which
 * renders no tenant data and polls a read-only probe until the token is accepted. Every
 * other error is thrown with its message intact.
 */
function failTenantRead(label: string, error: { message: string; code?: string | null }): never {
  const outcome = tenantReadOutcome(label, error);
  if (outcome.kind === "redirect") redirect(outcome.to);
  throw new Error(outcome.kind === "throw" ? outcome.message : `${label}: ${error.message}`);
}

export type { UserRole } from "@/lib/roles";

export type Branch = {
  id: string;
  name: string;
  code: string;
  is_default: boolean;
};

export type Membership = {
  business_id: string;
  business_name: string;
  business_code: string;
  role: UserRole;
  /** Branch pinned on the membership row, or null when the member is not branch-scoped. */
  membership_branch_id: string | null;
  branches: Branch[];
};

export type TenantContext = {
  user: { id: string; email: string | null };
  profile: { full_name: string | null };
  memberships: Membership[];
  active: Membership;
  /** Branch shown in the shell: the pinned branch, else the default branch, else the first one. */
  branch: Branch | null;
};

/**
 * Reads every active membership of the signed-in user straight from PostgreSQL.
 *
 * Trust model: the queries below are filtered by user_id AND additionally constrained by
 * RLS (fn_is_member / pol_bm_select), so a client cannot widen them. Nothing about the
 * tenant — business, branch or role — is ever taken from client state; the cookie only
 * expresses a *preference* between memberships that were proven server-side.
 */
type EmbeddedBranch = { id: string; name: string; code: string; is_default: boolean; status: string };
type EmbeddedBusiness = { id: string; name: string; code: string; status: string; branches: EmbeddedBranch[] | null };
type MemberRow = { business_id: string; role: UserRole; branch_id: string | null; businesses: EmbeddedBusiness | null };

export const loadMemberships = cache(async () => {
  const supabase = await createClient();

  // The identity comes from the verified JWT (getClaims: signature checked against the
  // project's signing keys, no round trip to Auth when the project signs asymmetrically).
  // The middleware already refreshed the session for this request; a missing or invalid
  // token means sign in again. Authorisation itself is never taken from the token: every
  // read below is a PostgreSQL row the membership policies allow the user to see.
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  const claims = claimsData?.claims;
  if (claimsError || !claims?.sub) redirect("/login");
  const userId = String(claims.sub);
  const email = typeof claims.email === "string" ? claims.email : null;

  // One round trip for the whole tenant picture: memberships with their business and the
  // business's active branches embedded (PostgREST resource embedding over the existing
  // foreign keys), plus the profile in parallel. A token minted by Auth in the same second
  // can be "issued at future" for PostgREST's clock; that one condition is retried once
  // after a short pause (lib/auth/jwt-skew.ts) and, if it persists, handed to
  // /auth/session-ready by failTenantRead. Every other error goes straight through.
  const {
    profile: { data: profileRow },
    members: { data: memberRows, error: memberError },
  } = await withFreshJwtRetry(async () => {
    const [profile, members] = await Promise.all([
      supabase.from("profiles").select("full_name").eq("id", userId).maybeSingle(),
      supabase
        .from("business_members")
        .select("business_id, role, branch_id, businesses!inner(id, name, code, status, branches(id, name, code, is_default, status))")
        .eq("user_id", userId)
        .eq("is_active", true)
        .eq("businesses.status", "active")
        .eq("businesses.branches.status", "active"),
    ]);
    return { profile, members, error: members.error ?? profile.error };
  });

  if (memberError) failTenantRead("Üyelikler okunamadı", memberError);

  const memberships: Membership[] = ((memberRows ?? []) as unknown as MemberRow[])
    .map((m) => {
      const business = m.businesses;
      if (!business || business.status !== "active") return null; // suspended or cancelled business: no access
      return {
        business_id: business.id,
        business_name: business.name,
        business_code: business.code,
        role: m.role,
        membership_branch_id: m.branch_id ?? null,
        branches: (business.branches ?? [])
          .filter((br) => br.status === "active")
          .sort((a, b) => Number(b.is_default) - Number(a.is_default) || a.name.localeCompare(b.name, "tr"))
          .map((br) => ({ id: br.id, name: br.name, code: br.code, is_default: br.is_default })),
      } satisfies Membership;
    })
    .filter((m): m is Membership => m !== null)
    .sort((a, b) => a.business_name.localeCompare(b.business_name, "tr"));

  return {
    user: { id: userId, email },
    profile: { full_name: (profileRow?.full_name as string | null) ?? null },
    memberships,
  };
});

function resolveBranch(membership: Membership): Branch | null {
  if (membership.membership_branch_id) {
    const pinned = membership.branches.find((b) => b.id === membership.membership_branch_id);
    if (pinned) return pinned;
  }
  return membership.branches.find((b) => b.is_default) ?? membership.branches[0] ?? null;
}

/**
 * Full tenant entry for protected pages.
 *   0 memberships  -> /no-access
 *   1 membership   -> entered automatically
 *   many           -> the cookie must name one of them, otherwise /select-business
 */
export async function requireTenant(): Promise<TenantContext> {
  const { user, profile, memberships } = await loadMemberships();

  if (memberships.length === 0) redirect("/no-access");

  let active: Membership;

  if (memberships.length === 1) {
    active = memberships[0];
  } else {
    const cookieStore = await cookies();
    const preferred = cookieStore.get(ACTIVE_BUSINESS_COOKIE)?.value;
    const match = memberships.find((m) => m.business_id === preferred);
    if (!match) redirect("/select-business");
    active = match;
  }

  return { user, profile, memberships, active, branch: resolveBranch(active) };
}

export { ROLE_LABELS } from "@/lib/roles";
