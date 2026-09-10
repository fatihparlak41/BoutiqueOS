"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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
      <p
        role="status"
        className="mt-8 border-l-2 border-accent bg-accent-soft px-3 py-3 text-sm leading-relaxed text-accent"
      >
        Bu adres kayıtlıysa sıfırlama bağlantısı gönderildi. Gelen kutunuzu kontrol edin.
      </p>
    );
  }

  return (
    <form action={formAction} className="mt-8 space-y-5" noValidate>
      <div className="space-y-2">
        <Label htmlFor="email">E-posta</Label>
        <Input
          id="email"
          name="email"
          type="email"
          autoComplete="email"
          autoFocus
          required
          spellCheck={false}
          aria-describedby={state.error ? "reset-error" : undefined}
        />
      </div>

      {state.error ? (
        <p
          id="reset-error"
          role="alert"
          className="border-l-2 border-danger bg-panel px-3 py-2 text-sm text-danger"
        >
          {state.error}
        </p>
      ) : null}

      <SubmitButton />
    </form>
  );
}
