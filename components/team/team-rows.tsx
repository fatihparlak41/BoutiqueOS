import { ROLE_LABELS } from "@/lib/roles";
import { INVITE_STATUS_LABELS, canManage, type TeamInvite, type TeamMember, type UserRole } from "@/lib/team/model";
import { Badge, type BadgeProps } from "@/components/ui/badge";
import { Card, CardBody } from "@/components/ui/card";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell } from "@/components/ui/table";
import { MemberActions } from "./member-actions";
import { InviteActions } from "./invite-actions";

/**
 * Two presentations of the same arrays. The page fetches once and hands the identical
 * data to both; nothing is queried or recomputed here.
 *
 * Actions are rendered only where the acting role may actually use them — a manager
 * looking at an owner sees the row and no action menu, because the database would
 * refuse the write anyway and a button that always fails is worse than no button.
 */

function StatusPill({ active }: { active: boolean }) {
  return <Badge tone={active ? "success" : "neutral"}>{active ? "Aktif" : "Pasif"}</Badge>;
}

const INVITE_TONE: Record<TeamInvite["status"], BadgeProps["tone"]> = {
  pending: "accent",
  expired: "warning",
  accepted: "success",
  revoked: "quiet",
};

function InvitePill({ status }: { status: TeamInvite["status"] }) {
  return <Badge tone={INVITE_TONE[status] ?? "neutral"}>{INVITE_STATUS_LABELS[status]}</Badge>;
}

function Identity({ member }: { member: TeamMember }) {
  return (
    <CellTitle sub={member.email} subNumeric>
      {member.full_name?.trim() || member.email}
      {member.is_self ? <span className="ml-1.5 text-2xs font-normal text-text-muted">(siz)</span> : null}
    </CellTitle>
  );
}

type Shared = {
  members: TeamMember[];
  actorRole: UserRole;
  branches: { id: string; name: string }[];
  grantableRoles: UserRole[];
  maxGrantableDiscount: number;
};

export function TeamCards({ members, actorRole, branches, grantableRoles, maxGrantableDiscount }: Shared) {
  return (
    <ul className="space-y-2 lg:hidden">
      {members.map((member) => (
        <li key={member.user_id}>
          <Card>
            <CardBody>
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <Identity member={member} />
                </div>
                <StatusPill active={member.is_active} />
              </div>
              <p className="mt-2 text-xs text-text-secondary">
                {ROLE_LABELS[member.role]}
                {", "}
                <span className="text-text-muted">{member.branch_name ?? "şube atanmadı"}</span>
              </p>
              {member.role === "sales_staff" ? (
                <p className="mt-1 text-2xs text-text-muted">
                  İndirim yetkisi <span data-numeric>%{member.max_discount_pct}</span>
                </p>
              ) : null}
              {canManage(actorRole, member.role) ? (
                <div className="mt-3 border-t border-border pt-3">
                  <MemberActions
                    member={member}
                    branches={branches}
                    grantableRoles={grantableRoles}
                    maxGrantableDiscount={maxGrantableDiscount}
                  />
                </div>
              ) : null}
            </CardBody>
          </Card>
        </li>
      ))}
    </ul>
  );
}

export function TeamTable({ members, actorRole, branches, grantableRoles, maxGrantableDiscount }: Shared) {
  return (
    <div className="hidden lg:block">
      <TableShell minWidth="56rem">
        <THead>
          <TH>Ad / e-posta</TH>
          <TH>Rol</TH>
          <TH>Şube</TH>
          <TH align="right">İndirim</TH>
          <TH>Durum</TH>
          <TH>İşlem</TH>
        </THead>
        <TBody>
          {members.map((member) => (
            <TR key={member.user_id}>
              <TD>
                <Identity member={member} />
              </TD>
              <TD muted>{ROLE_LABELS[member.role]}</TD>
              <TD muted>{member.branch_name ?? "—"}</TD>
              <TD muted numeric align="right">
                {member.role === "sales_staff" ? `%${member.max_discount_pct}` : "—"}
              </TD>
              <TD>
                <StatusPill active={member.is_active} />
              </TD>
              <TD>
                {canManage(actorRole, member.role) ? (
                  <MemberActions
                    member={member}
                    branches={branches}
                    grantableRoles={grantableRoles}
                    maxGrantableDiscount={maxGrantableDiscount}
                  />
                ) : (
                  <span className="text-2xs text-text-muted">—</span>
                )}
              </TD>
            </TR>
          ))}
        </TBody>
      </TableShell>
    </div>
  );
}

export function InviteList({ invites }: { invites: TeamInvite[] }) {
  if (invites.length === 0) return null;

  return (
    <ul className="divide-y divide-border border-y border-border">
      {invites.map((invite) => (
        <li key={invite.invite_id} className="flex flex-wrap items-start justify-between gap-3 py-3">
          <div className="min-w-[14rem] flex-1">
            <CellTitle sub={invite.email} subNumeric>
              {invite.display_name?.trim() || invite.email}
            </CellTitle>
            <p className="mt-1.5 flex flex-wrap items-center gap-2 text-xs text-text-secondary">
              <span>
                {ROLE_LABELS[invite.role]}
                {", "}
                <span className="text-text-muted">{invite.branch_name ?? "şube atanmadı"}</span>
              </span>
              <InvitePill status={invite.status} />
            </p>
          </div>
          {invite.can_manage && (invite.status === "pending" || invite.status === "expired") ? (
            <InviteActions invite={invite} />
          ) : null}
        </li>
      ))}
    </ul>
  );
}
