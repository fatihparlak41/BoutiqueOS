import "server-only";

import { cache } from "react";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { UserRole } from "@/lib/roles";

export const ACTIVE_BUSINESS_COOKIE = "bos_active_business";

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
export const loadMemberships = cache(async () => {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const [{ data: profileRow }, { data: memberRows, error: memberError }] = await Promise.all([
    supabase.from("profiles").select("full_name").eq("id", user.id).maybeSingle(),
    supabase
      .from("business_members")
      .select("business_id, role, branch_id")
      .eq("user_id", user.id)
      .eq("is_active", true),
  ]);

  if (memberError) throw new Error(`Üyelikler okunamadı: ${memberError.message}`);

  const businessIds = (memberRows ?? []).map((m) => m.business_id as string);

  let memberships: Membership[] = [];

  if (businessIds.length > 0) {
    const [{ data: businessRows, error: bizError }, { data: branchRows, error: branchError }] =
      await Promise.all([
        supabase
          .from("businesses")
          .select("id, name, code, status")
          .in("id", businessIds)
          .eq("status", "active"),
        supabase
          .from("branches")
          .select("id, business_id, name, code, is_default, status")
          .in("business_id", businessIds)
          .eq("status", "active")
          .order("is_default", { ascending: false })
          .order("name", { ascending: true }),
      ]);

    if (bizError) throw new Error(`İşletmeler okunamadı: ${bizError.message}`);
    if (branchError) throw new Error(`Şubeler okunamadı: ${branchError.message}`);

    memberships = (memberRows ?? [])
      .map((m) => {
        const business = (businessRows ?? []).find((b) => b.id === m.business_id);
        if (!business) return null; // suspended or cancelled business: no access
        return {
          business_id: business.id as string,
          business_name: business.name as string,
          business_code: business.code as string,
          role: m.role as UserRole,
          membership_branch_id: (m.branch_id as string | null) ?? null,
          branches: (branchRows ?? [])
            .filter((br) => br.business_id === business.id)
            .map((br) => ({
              id: br.id as string,
              name: br.name as string,
              code: br.code as string,
              is_default: br.is_default as boolean,
            })),
        } satisfies Membership;
      })
      .filter((m): m is Membership => m !== null)
      .sort((a, b) => a.business_name.localeCompare(b.business_name, "tr"));
  }

  return {
    user: { id: user.id, email: user.email ?? null },
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
