"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { PasswordInput } from "@/components/ui/password-input";
import { FormAlert } from "@/components/auth/auth-status";
import { setPasswordAction, type SetPasswordState } from "@/app/auth/actions";

const initialState: SetPasswordState = { error: null };

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="lg" className="w-full" disabled={pending}>
      {pending ? "Kaydediliyor…" : "Parolayı kaydet"}
    </Button>
  );
}

/**
 * The requirement is stated before anything is typed and echoed live as a hint; the
 * server action remains the authority (length, match, recovery gate) and its messages
 * are what the alert shows.
 */
export function SetPasswordForm({ minLength }: { minLength: number }) {
  const [state, formAction] = useActionState(setPasswordAction, initialState);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");

  const errorId = state.error ? "password-error" : undefined;
  const longEnough = password.length >= minLength;
  const matches = confirm.length > 0 && confirm === password;

  return (
    <form action={formAction} className="mt-8 space-y-5" noValidate>
      <div className="space-y-2">
        <Label htmlFor="password">Yeni parola</Label>
        <PasswordInput
          id="password"
          name="password"
          autoComplete="new-password"
          minLength={minLength}
          autoFocus
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          aria-describedby={["password-hint", errorId].filter(Boolean).join(" ")}
          aria-invalid={state.error ? true : undefined}
        />
        <p id="password-hint" className="text-2xs leading-relaxed text-text-muted">
          En az {minLength} karakter.
          {password.length > 0 ? (
            <span className={longEnough ? "ml-1 text-success" : "ml-1"}>
              {longEnough ? "Uzunluk uygun." : `${minLength - password.length} karakter daha.`}
            </span>
          ) : null}
        </p>
      </div>

      <div className="space-y-2">
        <Label htmlFor="password_confirm">Yeni parola (tekrar)</Label>
        <PasswordInput
          id="password_confirm"
          name="password_confirm"
          autoComplete="new-password"
          minLength={minLength}
          required
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          aria-describedby={["confirm-hint", errorId].filter(Boolean).join(" ")}
          aria-invalid={state.error ? true : undefined}
        />
        <p id="confirm-hint" className="text-2xs leading-relaxed text-text-muted">
          {confirm.length === 0 ? "Aynı parolayı bir kez daha yazın." : matches ? (
            <span className="text-success">Parolalar eşleşiyor.</span>
          ) : (
            "Parolalar henüz eşleşmiyor."
          )}
        </p>
      </div>

      {state.error ? <FormAlert id="password-error">{state.error}</FormAlert> : null}

      <SubmitButton />
    </form>
  );
}
