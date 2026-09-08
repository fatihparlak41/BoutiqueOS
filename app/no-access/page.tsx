import { redirect } from "next/navigation";
import { loadMemberships } from "@/lib/tenant";
import { signOutAction } from "@/app/auth/actions";
import { Wordmark } from "@/components/brand";
import { Button } from "@/components/ui/button";

export const metadata = { title: "Erişim yok · BoutiqueOS" };

export default async function NoAccessPage() {
  const { memberships, user } = await loadMemberships();

  // Access may have been granted since the last visit.
  if (memberships.length > 0) redirect("/app");

  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center px-6 py-16">
      <Wordmark className="text-base" />
      <h1 className="mt-10 text-xl font-medium tracking-tightish">Bağlı bir işletme yok</h1>
      <p className="mt-3 text-sm leading-relaxed text-muted">
        Oturumunuz açık, ancak {user.email ?? "bu hesap"} henüz hiçbir işletmeye aktif üye olarak
        tanımlanmamış. İşletme sahibi sizi ekledikten sonra bu sayfayı yenilemeniz yeterli.
      </p>

      <div className="mt-8 flex gap-2">
        <form action={signOutAction}>
          <Button type="submit" variant="outline" size="sm">
            Çıkış yap
          </Button>
        </form>
      </div>
    </main>
  );
}
