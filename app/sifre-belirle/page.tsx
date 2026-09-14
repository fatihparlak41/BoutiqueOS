import { redirect } from "next/navigation";
import { loadRecoveryGate } from "@/lib/auth/recovery-session-server";
import { PASSWORD_MIN_LENGTH } from "@/lib/auth/password";
import { AuthShell } from "@/components/auth/auth-shell";
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
    <AuthShell
      title="Yeni parolanızı belirleyin"
      description={
        <>
          <span className="text-text-primary">{email}</span> hesabı için geçerli olacak. Parolanızı yalnız
          siz belirlersiniz; işletme yöneticiniz de göremez.
        </>
      }
    >
      <SetPasswordForm minLength={PASSWORD_MIN_LENGTH} />
    </AuthShell>
  );
}
