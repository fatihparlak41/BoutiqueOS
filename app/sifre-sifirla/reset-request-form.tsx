"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { AuthStatus, FormAlert } from "@/components/auth/auth-status";
import { requestPasswordResetAction, type ResetRequestState } from "@/app/auth/actions";

const initialState: ResetRequestState = { done: false, error: null };

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="lg" className="w-full" disabled={pending}>
      {pending ? "Gönderiliyor…" : "Sıfırlama bağlantısı gönder"}
    </Button>
  );
}

export function ResetRequestForm() {
  const [state, formAction] = useActionState(requestPasswordResetAction, initialState);

  // The confirmation is identical whether or not the address is registered. Anything
  // else would turn this form into a staff-list oracle.
  if (state.done) {
    return (
      <AuthStatus
        live
        tone="success"
        className="mt-8"
        title="İsteğiniz alındı"
        description="Eğer bu adresle kayıtlı bir hesap varsa, parola sıfırlama bağlantısını gönderdik. Gelen kutunuzu ve gereksiz posta klasörünü kontrol edin."
      />
    );
  }

  const errorId = state.error ? "reset-error" : undefined;

  return (
    <form action={formAction} className="mt-8 space-y-5" noValidate>
      <div className="space-y-2">
        <Label htmlFor="email">E-posta</Label>
        <Input
          id="email"
          name="email"
          type="email"
          inputMode="email"
          autoComplete="email"
          autoCapitalize="none"
          autoFocus
          required
          spellCheck={false}
          aria-describedby={errorId}
          aria-invalid={state.error ? true : undefined}
        />
      </div>

      {state.error ? <FormAlert id="reset-error">{state.error}</FormAlert> : null}

      <SubmitButton />
    </form>
  );
}
