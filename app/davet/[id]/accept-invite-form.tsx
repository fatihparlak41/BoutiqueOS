"use client";

import Link from "next/link";
import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
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
      <div className="mt-8 space-y-5">
        <p
          role="status"
          className="border-l-2 border-accent bg-accent-soft px-3 py-3 text-sm leading-relaxed text-accent"
        >
          Ekibe katıldınız.
        </p>
        <Link
          href="/app"
          className="inline-flex min-h-11 w-full items-center justify-center rounded border border-line-strong bg-ink px-5 text-sm text-paper transition-colors hover:bg-ink/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
        >
          Panele git
        </Link>
      </div>
    );
  }

  return (
    <form action={formAction} className="mt-8 space-y-5">
      <input type="hidden" name="invite_id" value={inviteId} />

      {state.error ? (
        <p role="alert" className="border-l-2 border-danger bg-panel px-3 py-2 text-sm leading-relaxed text-danger">
          {state.error}
        </p>
      ) : null}

      <SubmitButton />

      <p className="text-xs leading-relaxed text-muted">
        Davet başka bir adrese gönderildiyse o adresle oturum açmanız gerekir.
      </p>
    </form>
  );
}
