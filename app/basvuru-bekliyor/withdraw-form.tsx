"use client";

import { useActionState, useState } from "react";
import { Button } from "@/components/ui/button";
import { withdrawApplicationAction } from "@/app/basvuru/actions";
import { APPLY_IDLE } from "@/lib/saas/model";

/** Two clicks to withdraw: the first reveals the confirmation, the second posts. */
export function WithdrawForm({ applicationId }: { applicationId: string }) {
  const [state, formAction, pending] = useActionState(withdrawApplicationAction, APPLY_IDLE);
  const [arm, setArm] = useState(false);
  if (!arm) {
    return (
      <Button type="button" variant="ghost" size="sm" onClick={() => setArm(true)}>
        Başvuruyu geri çek
      </Button>
    );
  }
  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="application_id" value={applicationId} />
      <p className="text-xs text-text-muted">Başvuru geri çekilir; dilediğinizde yeniden başvurabilirsiniz.</p>
      <div className="flex items-center gap-2">
        <Button type="submit" variant="outline" size="sm" disabled={pending}>
          {pending ? "Geri çekiliyor…" : "Evet, geri çek"}
        </Button>
        <Button type="button" variant="ghost" size="sm" onClick={() => setArm(false)}>
          Vazgeç
        </Button>
      </div>
      {state.error ? <p className="text-xs text-danger" role="alert">{state.error}</p> : null}
    </form>
  );
}
