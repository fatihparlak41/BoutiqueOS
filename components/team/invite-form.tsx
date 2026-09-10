"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { ROLE_LABELS } from "@/lib/roles";
import { TEAM_IDLE } from "@/lib/team/action-state";
import type { UserRole } from "@/lib/team/model";
import { inviteMemberAction } from "@/app/app/ayarlar/ekip/actions";
import { TeamMessage } from "./team-message";

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" disabled={pending}>
      {pending ? "Gönderiliyor…" : "Davet Gönder"}
    </Button>
  );
}

/**
 * Invitation form.
 *
 * The role list is the set this user may actually grant (fn_can_grant_role), so a
 * manager never sees "owner" as an option — and the database refuses it regardless.
 * The discount field appears only for sales_staff, the one role J-4 consults it for.
 */
export function InviteForm({
  branches,
  grantableRoles,
  maxGrantableDiscount,
}: {
  branches: { id: string; name: string }[];
  grantableRoles: UserRole[];
  maxGrantableDiscount: number;
}) {
  const [state, formAction] = useActionState(inviteMemberAction, TEAM_IDLE);
  const [open, setOpen] = useState(false);
  const [role, setRole] = useState<UserRole>(grantableRoles[0] ?? "sales_staff");

  if (!open) {
    return (
      <Button onClick={() => setOpen(true)} size="sm">
        Kullanıcı Ekle
      </Button>
    );
  }

  return (
    <form action={formAction} className="space-y-4 border border-line bg-panel/40 p-4" noValidate>
      <div className="flex items-center justify-between gap-3">
        <h3 className="text-sm font-medium tracking-tightish">Kullanıcı ekle</h3>
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>
          Kapat
        </Button>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="display_name">Ad soyad</Label>
          <Input id="display_name" name="display_name" maxLength={80} autoFocus />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="email">E-posta</Label>
          <Input id="email" name="email" type="email" required spellCheck={false} />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="role">Rol</Label>
          <Select id="role" name="role" value={role} onChange={(e) => setRole(e.target.value as UserRole)}>
            {grantableRoles.map((value) => (
              <option key={value} value={value}>
                {ROLE_LABELS[value]}
              </option>
            ))}
          </Select>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="branch_id">Şube</Label>
          <Select id="branch_id" name="branch_id" defaultValue="">
            <option value="">Şube atanmadı</option>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </Select>
        </div>

        {role === "sales_staff" ? (
          <div className="space-y-1.5">
            <Label htmlFor="max_discount_pct">İndirim yetkisi (%)</Label>
            <Input id="max_discount_pct" name="max_discount_pct" inputMode="decimal" defaultValue="0" />
            <p className="text-2xs text-muted">
              {maxGrantableDiscount > 0
                ? `En fazla %${maxGrantableDiscount}.`
                : "Kendi indirim yetkiniz tanımlı olmadığı için yalnız %0 verebilirsiniz."}
            </p>
          </div>
        ) : null}
      </div>

      <p className="text-2xs leading-relaxed text-muted">
        Davet e-postası doğrudan bu adrese gider. Parolayı çalışan kendisi belirler; siz de dahil
        hiç kimse göremez.
      </p>

      <TeamMessage state={state} successText="Davet gönderildi." />
      <SubmitButton />
    </form>
  );
}
