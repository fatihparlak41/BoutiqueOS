"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";
import { reportDbError } from "@/lib/db-errors";
import { authDestinationUrl, siteOrigin } from "@/lib/url";
import { DeliveryError, isAdminAuthConfigured, sendInviteEmail } from "@/lib/supabase/admin";
import type { TeamActionState } from "@/lib/team/action-state";
import type { UserRole } from "@/lib/team/model";

/**
 * Team management actions.
 *
 * Authorisation is never decided here. Membership edits go through the table under the
 * Phase 3.5D policies; invitations and password resets go through RPCs that prove the
 * caller's rank in the database. This module resolves the tenant server-side and passes
 * ids only — it never accepts a business_id, a target address or a role from the
 * browser as an authorisation input.
 */

const ROLES: readonly UserRole[] = ["owner", "manager", "sales_staff", "stock_staff"];

function fail(message: string): TeamActionState {
  return { error: message, ok: false };
}

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? "").trim();
}

function uuidOrNull(formData: FormData, key: string): string | null {
  const value = text(formData, key);
  return /^[0-9a-fA-F-]{36}$/.test(value) ? value : null;
}

function parsePercent(formData: FormData): number | null {
  const raw = text(formData, "max_discount_pct").replace(",", ".");
  if (raw === "") return 0;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0 || value > 100) return null;
  return value;
}

async function requestOrigin(): Promise<string | undefined> {
  const h = await headers();
  const host = h.get("x-forwarded-host") ?? h.get("host");
  if (!host) return undefined;
  const proto = h.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  return `${proto}://${host}`;
}

/** Absolute /davet/<id> link, built from configuration rather than a request parameter. */
async function inviteLink(inviteId: string): Promise<string> {
  return new URL(`/davet/${inviteId}`, siteOrigin(await requestOrigin())).toString();
}

// ------------------------------------------------------------------ invitations

export async function inviteMemberAction(
  _prev: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const { active } = await requireTenant();
  const supabase = await createClient();

  const email = text(formData, "email");
  const displayName = text(formData, "display_name");
  const role = text(formData, "role") as UserRole;
  const branchId = uuidOrNull(formData, "branch_id");
  const discount = parsePercent(formData);

  if (!email) return fail("E-posta adresi gerekli.");
  if (!ROLES.includes(role)) return fail("Geçerli bir rol seçin.");
  if (discount === null) return fail("İndirim yetkisi 0 ile 100 arasında olmalı.");

  // The database decides whether this caller may grant this role in this business.
  const { data: inviteId, error } = await supabase.rpc("rpc_create_invite", {
    p_business_id: active.business_id,
    p_email: email,
    p_display_name: displayName || null,
    p_role: role,
    p_branch_id: branchId,
    p_max_discount_pct: discount,
  });

  if (error) return fail(reportDbError("createInvite", error));

  const delivery = await deliverInvite(inviteId as string);
  revalidatePath("/app/ayarlar/ekip");
  return delivery;
}

export async function resendInviteAction(
  _prev: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const inviteId = uuidOrNull(formData, "invite_id");
  if (!inviteId) return fail("Davet bulunamadı.");

  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_resend_invite", { p_invite_id: inviteId });
  if (error) return fail(reportDbError("resendInvite", error));

  const delivery = await deliverInvite(inviteId);
  revalidatePath("/app/ayarlar/ekip");
  return delivery;
}

export async function revokeInviteAction(
  _prev: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const inviteId = uuidOrNull(formData, "invite_id");
  if (!inviteId) return fail("Davet bulunamadı.");

  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_revoke_invite", { p_invite_id: inviteId });
  if (error) return fail(reportDbError("revokeInvite", error));

  revalidatePath("/app/ayarlar/ekip");
  return { error: null, ok: true };
}

/**
 * Sends (or re-sends) the one email the invitee receives.
 *
 * The address is read back from rpc_invite_delivery_target, which re-checks that the
 * caller may manage this invitation. Nothing from the form reaches the mailer, so this
 * cannot be turned into a relay pointed at an arbitrary address.
 */
async function deliverInvite(inviteId: string): Promise<TeamActionState> {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc("rpc_invite_delivery_target", {
    p_invite_id: inviteId,
  });
  if (error) return fail(reportDbError("inviteDeliveryTarget", error));

  const target = Array.isArray(data) ? data[0] : data;
  const email = (target as { email?: string } | null)?.email;
  if (!email) return fail("Davet adresi çözümlenemedi.");

  const link = await inviteLink(inviteId);

  if (!isAdminAuthConfigured()) {
    // The invitation is real and usable; only the mailer is missing. Reporting this as
    // success would leave a colleague waiting for an email that will never arrive.
    return { error: null, ok: true, configurationRequired: true, inviteUrl: link };
  }

  try {
    // The destination is the invitation page itself; Supabase carries it into the
    // template as {{ .RedirectTo }} so the per-invite id survives the round trip.
    await sendInviteEmail(email, authDestinationUrl(`/davet/${inviteId}`, await requestOrigin()));
  } catch (cause) {
    console.error("[team] davet e-postası gönderilemedi:", cause);
    const detail =
      cause instanceof DeliveryError
        ? cause.message
        : "Davet kaydedildi ama e-posta gönderilemedi.";
    return {
      error: `${detail} Bağlantıyı elden iletebilirsiniz.`,
      ok: false,
      inviteUrl: link,
    };
  }

  return { error: null, ok: true };
}

// ------------------------------------------------------------------ membership

export async function updateMemberAction(
  _prev: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const { active } = await requireTenant();
  const userId = uuidOrNull(formData, "user_id");
  if (!userId) return fail("Üye bulunamadı.");

  const role = text(formData, "role") as UserRole;
  if (!ROLES.includes(role)) return fail("Geçerli bir rol seçin.");

  const branchId = uuidOrNull(formData, "branch_id");
  const discount = parsePercent(formData);
  if (discount === null) return fail("İndirim yetkisi 0 ile 100 arasında olmalı.");

  const supabase = await createClient();
  // One statement, so the audit trigger records the whole change as a single event
  // with every changed field preserved.
  const { error } = await supabase
    .from("business_members")
    .update({ role, branch_id: branchId, max_discount_pct: discount })
    .eq("business_id", active.business_id)
    .eq("user_id", userId);

  if (error) return fail(reportDbError("updateMember", error));

  revalidatePath("/app/ayarlar/ekip");
  return { error: null, ok: true };
}

export async function setMemberActiveAction(
  _prev: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const { active } = await requireTenant();
  const userId = uuidOrNull(formData, "user_id");
  if (!userId) return fail("Üye bulunamadı.");

  const nextActive = text(formData, "is_active") === "true";

  const supabase = await createClient();
  const { error } = await supabase
    .from("business_members")
    .update({ is_active: nextActive })
    .eq("business_id", active.business_id)
    .eq("user_id", userId);

  if (error) return fail(reportDbError("setMemberActive", error));

  revalidatePath("/app/ayarlar/ekip");
  return { error: null, ok: true };
}

/**
 * "Şifre Sıfırlama Bağlantısı Gönder".
 *
 * The target address is resolved by rpc_reset_target_email, which enforces the same
 * subordinate rule as the rest of team management: a manager may do this for
 * sales_staff and stock_staff only, never for an owner or another manager, and never
 * across tenants. The client supplies a member id, never an address.
 */
export async function sendMemberResetLinkAction(
  _prev: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const { active } = await requireTenant();
  const userId = uuidOrNull(formData, "user_id");
  if (!userId) return fail("Üye bulunamadı.");

  const supabase = await createClient();
  const { data: email, error } = await supabase.rpc("rpc_reset_target_email", {
    p_business_id: active.business_id,
    p_target_user_id: userId,
  });

  if (error) return fail(reportDbError("resetTargetEmail", error));
  if (!email) return fail("Üyenin hesabı bulunamadı.");

  const { error: mailError } = await supabase.auth.resetPasswordForEmail(email as string, {
    redirectTo: authDestinationUrl("/sifre-belirle", await requestOrigin()),
  });

  if (mailError) {
    console.error("[team] sıfırlama e-postası gönderilemedi:", mailError);
    return fail("Sıfırlama bağlantısı gönderilemedi. Biraz sonra tekrar deneyin.");
  }

  return { error: null, ok: true };
}
