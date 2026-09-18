"use client";

import { useActionState } from "react";
import { Button } from "@/components/ui/button";
import { resendConfirmationAction } from "@/app/basvuru/actions";
import { APPLY_IDLE } from "@/lib/saas/model";

export function ResendConfirmation() {
  const [state, formAction, pending] = useActionState(resendConfirmationAction, APPLY_IDLE);
  return (
    <form action={formAction} className="space-y-2">
      <Button type="submit" variant="outline" size="md" disabled={pending}>
        {pending ? "Gönderiliyor…" : "Bağlantıyı yeniden gönder"}
      </Button>
      {state.error ? <p className="text-xs text-danger" role="alert">{state.error}</p> : null}
    </form>
  );
}
