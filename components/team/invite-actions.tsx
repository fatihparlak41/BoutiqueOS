"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { TEAM_IDLE } from "@/lib/team/action-state";
import type { TeamInvite } from "@/lib/team/model";
import { resendInviteAction, revokeInviteAction } from "@/app/app/ayarlar/ekip/actions";
import { TeamMessage } from "./team-message";

function Pending({ label, pendingLabel }: { label: string; pendingLabel: string }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" variant="ghost" disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

/** Only shown for invitations the acting role could have created (rpc_list_invites.can_manage). */
export function InviteActions({ invite }: { invite: TeamInvite }) {
  const [resendState, resendAction] = useActionState(resendInviteAction, TEAM_IDLE);
  const [revokeState, revokeAction] = useActionState(revokeInviteAction, TEAM_IDLE);

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2">
        <form action={resendAction}>
          <input type="hidden" name="invite_id" value={invite.invite_id} />
          <Pending label="Daveti Tekrar Gönder" pendingLabel="Gönderiliyor…" />
        </form>
        <form action={revokeAction}>
          <input type="hidden" name="invite_id" value={invite.invite_id} />
          <Pending label="Daveti İptal Et" pendingLabel="İptal ediliyor…" />
        </form>
      </div>
      <TeamMessage state={resendState} successText="Davet yeniden gönderildi." />
      <TeamMessage state={revokeState} successText="Davet iptal edildi." />
    </div>
  );
}
