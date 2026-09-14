"use client";

import Link from "next/link";
import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { PasswordInput } from "@/components/ui/password-input";
import { FormAlert } from "@/components/auth/auth-status";
import { signInAction, type SignInState } from "@/app/auth/actions";

const initialState: SignInState = { error: null };

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="lg" className="w-full" disabled={pending}>
      {pending ? "Giriş yapılıyor…" : "Giriş yap"}
    </Button>
  );
}

export function LoginForm() {
  const [state, formAction] = useActionState(signInAction, initialState);
  const errorId = state.error ? "login-error" : undefined;

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

      <div className="space-y-2">
        <div className="flex items-baseline justify-between">
          <Label htmlFor="password">Parola</Label>
          <Link
            href="/sifre-sifirla"
            className="text-xs text-text-muted underline-offset-4 hover:text-text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            Parolamı unuttum
          </Link>
        </div>
        <PasswordInput
          id="password"
          name="password"
          autoComplete="current-password"
          required
          aria-describedby={errorId}
          aria-invalid={state.error ? true : undefined}
        />
      </div>

      {state.error ? <FormAlert id="login-error">{state.error}</FormAlert> : null}

      <SubmitButton />
    </form>
  );
}
