import { ROLE_LABELS } from "@/lib/roles";
import { INVITE_STATUS_LABELS, canManage, type TeamInvite, type TeamMember, type UserRole } from "@/lib/team/model";
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
  return (
    <span
      className={
        active
          ? "inline-block rounded-sm border border-accent/30 bg-accent-soft px-1.5 py-0.5 text-2xs text-accent"
          : "inline-block rounded-sm border border-line-strong bg-panel px-1.5 py-0.5 text-2xs text-ink-70"
      }
    >
      {active ? "Aktif" : "Pasif"}
    </span>
  );
}

function InvitePill({ status }: { status: TeamInvite["status"] }) {
  const tone =
    status === "pending"
      ? "border-accent/30 bg-accent-soft text-accent"
      : status === "expired"
        ? "border-danger/30 bg-panel text-danger"
        : "border-line-strong bg-panel text-ink-70";
  return (
    <span className={`inline-block rounded-sm border px-1.5 py-0.5 text-2xs ${tone}`}>
      {INVITE_STATUS_LABELS[status]}
    </span>
  );
}

function Identity({ member }: { member: TeamMember }) {
  return (
    <>
      <span className="font-medium text-ink">
        {member.full_name?.trim() || member.email}
        {member.is_self ? <span className="ml-1.5 text-2xs text-muted">(siz)</span> : null}
      </span>
      <span className="mt-0.5 block text-2xs text-muted" data-numeric>
        {member.email}
      </span>
    </>
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
    <ul className="space-y-3 lg:hidden">
      {members.map((member) => (
        <li key={member.user_id} className="border border-line p-4">
          <Identity member={member} />
          <p className="mt-2 flex flex-wrap items-center gap-2 text-2xs text-muted">
            <span className="text-ink-70">{ROLE_LABELS[member.role]}</span>
            <span aria-hidden>·</span>
            <span>{member.branch_name ?? "Şube atanmadı"}</span>
            <StatusPill active={member.is_active} />
          </p>
          {member.role === "sales_staff" ? (
            <p className="mt-1 text-2xs text-muted">
              İndirim yetkisi: <span data-numeric>%{member.max_discount_pct}</span>
            </p>
          ) : null}
          {canManage(actorRole, member.role) ? (
            <div className="mt-3 border-t border-line pt-3">
              <MemberActions
                member={member}
                branches={branches}
                grantableRoles={grantableRoles}
                maxGrantableDiscount={maxGrantableDiscount}
              />
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  );
}

export function TeamTable({ members, actorRole, branches, grantableRoles, maxGrantableDiscount }: Shared) {
  return (
    <div className="relative hidden overflow-x-auto lg:block">
      <table className="w-full min-w-[56rem] border-collapse text-sm">
        <thead>
          <tr className="border-y border-line text-left text-xs text-muted">
            <th scope="col" className="py-2 pr-4 font-medium">Ad / e-posta</th>
            <th scope="col" className="py-2 pr-4 font-medium">Rol</th>
            <th scope="col" className="py-2 pr-4 font-medium">Şube</th>
            <th scope="col" className="py-2 pr-4 text-right font-medium">İndirim</th>
            <th scope="col" className="py-2 pr-4 font-medium">Durum</th>
            <th scope="col" className="py-2 font-medium">İşlem</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-line">
          {members.map((member) => (
            <tr key={member.user_id} className="align-top transition-colors hover:bg-panel/60">
              <td className="py-2.5 pr-4">
                <Identity member={member} />
              </td>
              <td className="py-2.5 pr-4 text-ink-70">{ROLE_LABELS[member.role]}</td>
              <td className="py-2.5 pr-4 text-ink-70">{member.branch_name ?? "—"}</td>
              <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                {member.role === "sales_staff" ? `%${member.max_discount_pct}` : "—"}
              </td>
              <td className="py-2.5 pr-4">
                <StatusPill active={member.is_active} />
              </td>
              <td className="py-2.5">
                {canManage(actorRole, member.role) ? (
                  <MemberActions
                    member={member}
                    branches={branches}
                    grantableRoles={grantableRoles}
                    maxGrantableDiscount={maxGrantableDiscount}
                  />
                ) : (
                  <span className="text-2xs text-muted">—</span>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function InviteList({ invites }: { invites: TeamInvite[] }) {
  if (invites.length === 0) return null;

  return (
    <ul className="divide-y divide-line border-y border-line">
      {invites.map((invite) => (
        <li key={invite.invite_id} className="flex flex-wrap items-start justify-between gap-3 py-3">
          <div className="min-w-[14rem] flex-1">
            <span className="text-sm font-medium">{invite.display_name?.trim() || invite.email}</span>
            <span className="mt-0.5 block text-2xs text-muted" data-numeric>
              {invite.email}
            </span>
            <p className="mt-1 flex flex-wrap items-center gap-2 text-2xs text-muted">
              <span className="text-ink-70">{ROLE_LABELS[invite.role]}</span>
              <span aria-hidden>·</span>
              <span>{invite.branch_name ?? "Şube atanmadı"}</span>
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
