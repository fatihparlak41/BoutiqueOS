"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { ROLE_LABELS } from "@/lib/roles";
import { TEAM_IDLE } from "@/lib/team/action-state";
import type { TeamMember, UserRole } from "@/lib/team/model";
import {
  sendMemberResetLinkAction,
  setMemberActiveAction,
  updateMemberAction,
} from "@/app/app/ayarlar/ekip/actions";
import { TeamMessage } from "./team-message";

function Pending({ label, pendingLabel, variant = "outline" }: {
  label: string;
  pendingLabel: string;
  variant?: "solid" | "outline" | "ghost";
}) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

/**
 * Row actions. Rendered only for members the acting role may manage, so nothing here
 * is a button that the database will refuse.
 *
 * Deactivation is the standard offboarding step, not deletion: sales history, goods
 * receipts, register sessions and returns all point at the membership and must keep
 * pointing at it. There is deliberately no "delete user" action.
 */
export function MemberActions({
  member,
  branches,
  grantableRoles,
  maxGrantableDiscount,
}: {
  member: TeamMember;
  branches: { id: string; name: string }[];
  grantableRoles: UserRole[];
  maxGrantableDiscount: number;
}) {
  const [open, setOpen] = useState(false);
  const [editState, editAction] = useActionState(updateMemberAction, TEAM_IDLE);
  const [activeState, activeAction] = useActionState(setMemberActiveAction, TEAM_IDLE);
  const [resetState, resetAction] = useActionState(sendMemberResetLinkAction, TEAM_IDLE);
  const [confirmed, setConfirmed] = useState(false);

  // Acting on an owner is a high-consequence change, so it asks for an explicit tick.
  const needsConfirm = member.role === "owner";

  return (
    <div className="space-y-3">
      <Button size="sm" variant="ghost" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        {open ? "Kapat" : "Düzenle"}
      </Button>

      {open ? (
        <div className="space-y-4 border border-line bg-panel/40 p-3">
          <form action={editAction} className="space-y-3">
            <input type="hidden" name="user_id" value={member.user_id} />

            <div className="space-y-1.5">
              <Label htmlFor={`role-${member.user_id}`}>Rol</Label>
              <Select id={`role-${member.user_id}`} name="role" defaultValue={member.role}>
                {grantableRoles.map((role) => (
                  <option key={role} value={role}>
                    {ROLE_LABELS[role]}
                  </option>
                ))}
              </Select>
            </div>

            <div className="space-y-1.5">
              <Label htmlFor={`branch-${member.user_id}`}>Şube</Label>
              <Select id={`branch-${member.user_id}`} name="branch_id" defaultValue={member.branch_id ?? ""}>
                <option value="">Şube atanmadı</option>
                {branches.map((branch) => (
                  <option key={branch.id} value={branch.id}>
                    {branch.name}
                  </option>
                ))}
              </Select>
            </div>

            <div className="space-y-1.5">
              <Label htmlFor={`discount-${member.user_id}`}>İndirim yetkisi (%)</Label>
              <Input
                id={`discount-${member.user_id}`}
                name="max_discount_pct"
                inputMode="decimal"
                defaultValue={String(member.max_discount_pct)}
              />
              <p className="text-2xs text-muted">
                En fazla %{maxGrantableDiscount}. Yalnız satış personeli için geçerlidir.
              </p>
            </div>

            {needsConfirm ? (
              <label className="flex items-start gap-2 text-2xs leading-relaxed text-ink-70">
                <input
                  type="checkbox"
                  checked={confirmed}
                  onChange={(e) => setConfirmed(e.target.checked)}
                  className="mt-0.5 h-3.5 w-3.5 rounded-sm border-line-strong text-accent focus-visible:ring-2 focus-visible:ring-accent"
                />
                <span>Bu bir işletme sahibi. Değişikliği onaylıyorum.</span>
              </label>
            ) : null}

            <TeamMessage state={editState} successText="Üyelik güncellendi." />
            <SaveButton disabled={needsConfirm && !confirmed} />
          </form>

          <form action={activeAction} className="border-t border-line pt-3">
            <input type="hidden" name="user_id" value={member.user_id} />
            <input type="hidden" name="is_active" value={member.is_active ? "false" : "true"} />
            <Pending
              label={member.is_active ? "Pasife Al" : "Yeniden Aktifleştir"}
              pendingLabel="…"
              variant="ghost"
            />
            <p className="mt-1 text-2xs leading-relaxed text-muted">
              Pasif üye oturum açsa bile işletme verisine erişemez. Geçmiş satış ve mal kabul
              kayıtları korunur.
            </p>
            <TeamMessage state={activeState} successText="Üyelik durumu güncellendi." />
          </form>

          <form action={resetAction} className="border-t border-line pt-3">
            <input type="hidden" name="user_id" value={member.user_id} />
            <Pending label="Şifre Sıfırlama Bağlantısı Gönder" pendingLabel="Gönderiliyor…" variant="ghost" />
            <p className="mt-1 text-2xs leading-relaxed text-muted">
              Bağlantı doğrudan çalışanın adresine gider. Yeni parolayı yalnız kendisi belirler.
            </p>
            <TeamMessage state={resetState} successText="Sıfırlama bağlantısı gönderildi." />
          </form>
        </div>
      ) : null}
    </div>
  );
}

function SaveButton({ disabled }: { disabled: boolean }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" disabled={disabled || pending}>
      {pending ? "Kaydediliyor…" : "Kaydet"}
    </Button>
  );
}
