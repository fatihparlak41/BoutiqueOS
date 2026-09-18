import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import Link from "next/link";
import { AuthShell } from "@/components/auth/auth-shell";
import { LoginForm } from "./login-form";

export const metadata = { title: "Giriş · BoutiqueOS" };

export default async function LoginPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (user) redirect("/app");

  return (
    <AuthShell
      title="Mağazanıza giriş yapın"
      description="Ekip hesabınız işletmeniz tarafından davetle açılır."
      footer={
        <>
          İşletmenizi BoutiqueOS&apos;a taşımak mı istiyorsunuz?{" "}
          <Link
            href="/kayit"
            className="underline-offset-4 hover:text-text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            Başvurun
          </Link>
        </>
      }
    >
      <LoginForm />
    </AuthShell>
  );
}
