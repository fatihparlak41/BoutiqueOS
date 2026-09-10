/**
 * Team vocabulary. Client-safe: no data access, no "server-only".
 *
 * Roles are the user_role enum from migration 20260908000001. super_admin is not part
 * of it and never will be — platform authority lives in platform_admins (Phase 3.5F).
 */

import type { UserRole } from "@/lib/roles";

export type { UserRole };

/** Effective invitation state as fn_invite_effective_status computes it. */
export type InviteStatus = "pending" | "accepted" | "revoked" | "expired";

export const INVITE_STATUS_LABELS: Record<InviteStatus, string> = {
  pending: "Davet bekliyor",
  accepted: "Kabul edildi",
  revoked: "İptal edildi",
  expired: "Süresi doldu",
};

export type TeamMember = {
  user_id: string;
  full_name: string | null;
  email: string;
  role: UserRole;
  branch_id: string | null;
  branch_name: string | null;
  is_active: boolean;
  max_discount_pct: number;
  joined_at: string;
  is_self: boolean;
};

export type TeamInvite = {
  invite_id: string;
  email: string;
  display_name: string | null;
  role: UserRole;
  branch_id: string | null;
  branch_name: string | null;
  max_discount_pct: number;
  status: InviteStatus;
  expires_at: string;
  invited_by_name: string | null;
  created_at: string;
  can_manage: boolean;
};

export type TeamAuditAction =
  | "member_added"
  | "member_updated"
  | "role_changed"
  | "branch_changed"
  | "discount_limit_changed"
  | "member_deactivated"
  | "member_reactivated"
  | "member_removed"
  | "invite_created"
  | "invite_revoked"
  | "invite_resent"
  | "invite_accepted";

export const AUDIT_ACTION_LABELS: Record<TeamAuditAction, string> = {
  member_added: "Üye eklendi",
  member_updated: "Üyelik güncellendi",
  role_changed: "Rol değişti",
  branch_changed: "Şube değişti",
  discount_limit_changed: "İndirim yetkisi değişti",
  member_deactivated: "Pasife alındı",
  member_reactivated: "Yeniden aktifleştirildi",
  member_removed: "Üyelik kaldırıldı",
  invite_created: "Davet gönderildi",
  invite_revoked: "Davet iptal edildi",
  invite_resent: "Davet yenilendi",
  invite_accepted: "Davet kabul edildi",
};

export type TeamAuditEntry = {
  id: string;
  action: TeamAuditAction;
  actor_name: string | null;
  target_name: string | null;
  target_invite_email: string | null;
  old_values: Record<string, unknown>;
  new_values: Record<string, unknown>;
  occurred_at: string;
};

/**
 * What the signed-in user may do on the team screen. Mirrors fn_can_grant_role and
 * fn_can_manage_member so the UI hides only what the database already refuses — the
 * database stays the decision, this is presentation.
 */
export type TeamCaps = {
  canRead: boolean;
  canInvite: boolean;
  /** Roles this user is allowed to hand out. */
  grantableRoles: UserRole[];
  /** Ceiling this user may grant, in percent. Only meaningful for sales_staff. */
  maxGrantableDiscount: number;
};

export function teamCaps(role: UserRole, ownDiscountCeiling: number): TeamCaps {
  if (role === "owner") {
    return {
      canRead: true,
      canInvite: true,
      grantableRoles: ["owner", "manager", "sales_staff", "stock_staff"],
      maxGrantableDiscount: 100,
    };
  }
  if (role === "manager") {
    return {
      canRead: true,
      canInvite: true,
      grantableRoles: ["sales_staff", "stock_staff"],
      maxGrantableDiscount: ownDiscountCeiling,
    };
  }
  return { canRead: false, canInvite: false, grantableRoles: [], maxGrantableDiscount: 0 };
}

/** True when this member may be acted on by a caller holding `actorRole`. */
export function canManage(actorRole: UserRole, targetRole: UserRole): boolean {
  if (actorRole === "owner") return true;
  if (actorRole === "manager") return targetRole === "sales_staff" || targetRole === "stock_staff";
  return false;
}
