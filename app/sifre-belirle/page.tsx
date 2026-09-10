import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Wordmark } from "@/components/brand";
import { PASSWORD_MIN_LENGTH } from "@/lib/auth/password";
import { SetPasswordForm } from "./set-password-form";

export const metadata = { title: "Yeni parola · BoutiqueOS" };

/**
 * Reached only through /auth/confirm, which has already exchanged the emailed
 * credential for a session. No session means the link was invalid or has expired, so
 * the visitor goes back to ask for a new one rather than seeing a dead form.
 */
export default async function SetPasswordPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/sifre-sifirla?durum=gecersiz");

  return (
    <main className="flex min-h-dvh flex-col justify-center px-6 py-16 sm:px-12">
      <div className="w-full max-w-sm sm:mx-auto">
        <Wordmark className="mb-10 block text-lg" />

        <h1 className="text-xl font-medium tracking-tightish">Yeni parolanızı belirleyin</h1>
        <p className="mt-2 text-sm leading-relaxed text-muted">
          {user.email} hesabı için geçerli olacak. Parolanızı yalnız siz belirlersiniz; işletme
          yöneticiniz de göremez.
        </p>

        <p className="mt-4 text-xs text-muted">En az {PASSWORD_MIN_LENGTH} karakter.</p>

        <SetPasswordForm />
      </div>
    </main>
  );
}
