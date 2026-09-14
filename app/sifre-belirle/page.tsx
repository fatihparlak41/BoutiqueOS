import { redirect } from "next/navigation";
import { loadRecoveryGate } from "@/lib/auth/recovery-session-server";
import { Wordmark } from "@/components/brand";
import { PASSWORD_MIN_LENGTH } from "@/lib/auth/password";
import { SetPasswordForm } from "./set-password-form";

export const metadata = { title: "Yeni parola · BoutiqueOS" };

/**
 * Reached through /auth/confirm, which has already exchanged the emailed recovery
 * credential for a session. The form is shown only to a session that the gate in
 * lib/auth/recovery-session.ts recognises as password recovery: no session at all
 * means the link was invalid or has expired, so the visitor goes back to ask for a new
 * one; any other signed-in session (password login, an old magic link) is sent to the
 * app instead of a password form it never asked for. setPasswordAction re-checks the
 * same gate, so rendering this page is never what authorises the change.
 */
export default async function SetPasswordPage() {
  const { gate, email } = await loadRecoveryGate();

  if (!gate.allowed) {
    redirect(gate.reason === "unauthenticated" ? "/sifre-sifirla?durum=gecersiz" : "/app");
  }

  return (
    <main className="flex min-h-dvh flex-col justify-center px-6 py-16 sm:px-12">
      <div className="w-full max-w-sm sm:mx-auto">
        <Wordmark className="mb-10 block text-lg" />

        <h1 className="text-xl font-medium tracking-tightish">Yeni parolanızı belirleyin</h1>
        <p className="mt-2 text-sm leading-relaxed text-muted">
          {email} hesabı için geçerli olacak. Parolanızı yalnız siz belirlersiniz; işletme
          yöneticiniz de göremez.
        </p>

        <p className="mt-4 text-xs text-muted">En az {PASSWORD_MIN_LENGTH} karakter.</p>

        <SetPasswordForm />
      </div>
    </main>
  );
}
