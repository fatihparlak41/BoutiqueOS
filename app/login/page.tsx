import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
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
      description="Hesabınız işletmeniz tarafından tanımlanır; davetle açılır."
    >
      <LoginForm />
    </AuthShell>
  );
}
