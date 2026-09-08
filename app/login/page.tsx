import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Wordmark } from "@/components/brand";
import { LoginForm } from "./login-form";

export const metadata = { title: "Giriş · BoutiqueOS" };

export default async function LoginPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (user) redirect("/app");

  return (
    <main className="grid min-h-dvh lg:grid-cols-[1.05fr_1fr]">
      {/* Brand panel: the one dark surface in the product. */}
      <section className="relative hidden flex-col justify-between bg-ink px-12 py-14 text-paper lg:flex">
        <Wordmark className="text-xl" />

        <div className="max-w-[26rem]">
          <p className="font-serif text-[2.75rem] leading-[1.1] tracking-tightish">
            Mağazanın günlük işleyişi, tek yerde.
          </p>
          <p className="mt-6 text-sm leading-relaxed text-paper/65">
            Mal kabul, stok, kasa, değişim ve tedarikçi cari hesabı — hepsi aynı kayıt üzerinde
            çalışır. Sayımla defter arasındaki fark burada kapanır.
          </p>
        </div>

        <p className="text-xs text-paper/45">Davetle açılan hesaplar. Kayıt formu yok.</p>
      </section>

      <section className="flex flex-col justify-center px-6 py-16 sm:px-12 lg:px-16">
        <div className="w-full max-w-sm">
          <Wordmark className="mb-10 block text-lg lg:hidden" />

          <h1 className="text-xl font-medium tracking-tightish">Oturum açın</h1>
          <p className="mt-2 text-sm text-muted">
            Hesabınız işletme yöneticiniz tarafından tanımlanır.
          </p>

          <LoginForm />
        </div>
      </section>
    </main>
  );
}
