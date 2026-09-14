"use client";

import Link from "next/link";
import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button, buttonVariants } from "@/components/ui/button";
import { AuthStatus, FormAlert } from "@/components/auth/auth-status";
import { TEAM_IDLE } from "@/lib/team/action-state";
import { acceptInviteAction } from "@/app/davet/actions";

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="lg" className="w-full" disabled={pending}>
      {pending ? "Katılınıyor…" : "Daveti kabul et"}
    </Button>
  );
}

export function AcceptInviteForm({ inviteId }: { inviteId: string }) {
  const [state, formAction] = useActionState(acceptInviteAction, TEAM_IDLE);

  if (state.ok) {
    return (
      <AuthStatus
        live
        tone="success"
        className="mt-8"
        title="Ekibe katıldınız"
        description="İşletmeniz ve rolünüz panelde hazır."
        action={
          <Link href="/app" className={buttonVariants({ size: "lg", className: "w-full" })}>
            Panele git
          </Link>
        }
      />
    );
  }

  return (
    <form action={formAction} className="mt-8 space-y-5">
      <input type="hidden" name="invite_id" value={inviteId} />

      {state.error ? <FormAlert>{state.error}</FormAlert> : null}

      <SubmitButton />

      <p className="text-xs leading-relaxed text-text-muted">
        Davet başka bir adrese gönderildiyse o adresle oturum açmanız gerekir.
      </p>
    </form>
  );
}
