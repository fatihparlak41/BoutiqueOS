import "server-only";

import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";
import { reportDbError } from "@/lib/db-errors";
import { teamCaps, type TeamAuditEntry, type TeamCaps, type TeamInvite, type TeamMember } from "./model";

/**
 * Server-only reads for the team screen.
 *
 * Nothing here queries business_members, profiles or auth.users directly: the directory
 * comes from rpc_list_team / rpc_list_invites, which are SECURITY DEFINER and enforce
 * manager+ themselves. profiles stays locked to "own row" (Phase 3.5C) and auth.users
 * stays unreadable by any client.
 */

const AUDIT_LIMIT = 200;

export async function loadTeamContext(): Promise<{ businessId: string; caps: TeamCaps }> {
  const { active } = await requireTenant();
  const supabase = await createClient();

  // A manager's own ceiling bounds what they may grant. Their own row is always
  // readable to them under pol_bm_select.
  const { data, error } = await supabase
    .from("business_members")
    .select("max_discount_pct")
    .eq("business_id", active.business_id)
    .maybeSingle();

  if (error) throw new Error(reportDbError("loadTeamContext", error));

  const ceiling = Number(data?.max_discount_pct ?? 0);
  return { businessId: active.business_id, caps: teamCaps(active.role, ceiling) };
}

export async function listTeam(businessId: string): Promise<TeamMember[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_list_team", { p_business_id: businessId });
  if (error) throw new Error(reportDbError("listTeam", error));

  return (data ?? []).map((row: Record<string, unknown>) => ({
    user_id: row.user_id as string,
    full_name: (row.full_name as string | null) ?? null,
    email: row.email as string,
    role: row.role as TeamMember["role"],
    branch_id: (row.branch_id as string | null) ?? null,
    branch_name: (row.branch_name as string | null) ?? null,
    is_active: row.is_active as boolean,
    max_discount_pct: Number(row.max_discount_pct ?? 0),
    joined_at: row.joined_at as string,
    is_self: row.is_self as boolean,
  }));
}

export async function listInvites(businessId: string): Promise<TeamInvite[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_list_invites", { p_business_id: businessId });
  if (error) throw new Error(reportDbError("listInvites", error));

  return (data ?? []).map((row: Record<string, unknown>) => ({
    invite_id: row.invite_id as string,
    email: row.email as string,
    display_name: (row.display_name as string | null) ?? null,
    role: row.role as TeamInvite["role"],
    branch_id: (row.branch_id as string | null) ?? null,
    branch_name: (row.branch_name as string | null) ?? null,
    max_discount_pct: Number(row.max_discount_pct ?? 0),
    status: row.status as TeamInvite["status"],
    expires_at: row.expires_at as string,
    invited_by_name: (row.invited_by_name as string | null) ?? null,
    created_at: row.created_at as string,
    can_manage: row.can_manage as boolean,
  }));
}

export async function listBranches(businessId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("branches")
    .select("id, name, code")
    .eq("business_id", businessId)
    .eq("status", "active")
    .order("is_default", { ascending: false })
    .order("name", { ascending: true });

  if (error) throw new Error(reportDbError("listTeamBranches", error));
  return (data ?? []).map((b) => ({ id: b.id as string, name: b.name as string, code: b.code as string }));
}

/**
 * Team history. RLS on team_audit_log already restricts this to manager+, so the read
 * is a plain select; the joins resolve display names the log stores only as ids.
 */
export async function listTeamAudit(businessId: string): Promise<TeamAuditEntry[]> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("team_audit_log")
    .select("id, action, actor_user_id, target_user_id, target_invite_id, old_values, new_values, occurred_at")
    .eq("business_id", businessId)
    .order("occurred_at", { ascending: false })
    .limit(AUDIT_LIMIT);

  if (error) throw new Error(reportDbError("listTeamAudit", error));
  const rows = data ?? [];
  if (rows.length === 0) return [];

  // Names come from the directory rather than from profiles, which is still "own row".
  const members = await listTeam(businessId);
  const nameOf = new Map(members.map((m) => [m.user_id, m.full_name ?? m.email]));

  const inviteIds = Array.from(
    new Set(rows.map((r) => r.target_invite_id as string | null).filter((v): v is string => !!v)),
  );
  const inviteEmail = new Map<string, string>();
  if (inviteIds.length > 0) {
    const { data: invites, error: inviteError } = await supabase
      .from("business_invites")
      .select("id, email_normalized")
      .in("id", inviteIds);
    if (inviteError) throw new Error(reportDbError("listTeamAuditInvites", inviteError));
    (invites ?? []).forEach((i) => inviteEmail.set(i.id as string, i.email_normalized as string));
  }

  return rows.map((row) => ({
    id: row.id as string,
    action: row.action as TeamAuditEntry["action"],
    actor_name: row.actor_user_id ? (nameOf.get(row.actor_user_id as string) ?? null) : null,
    target_name: row.target_user_id ? (nameOf.get(row.target_user_id as string) ?? null) : null,
    target_invite_email: row.target_invite_id
      ? (inviteEmail.get(row.target_invite_id as string) ?? null)
      : null,
    old_values: (row.old_values as Record<string, unknown>) ?? {},
    new_values: (row.new_values as Record<string, unknown>) ?? {},
    occurred_at: row.occurred_at as string,
  }));
}
