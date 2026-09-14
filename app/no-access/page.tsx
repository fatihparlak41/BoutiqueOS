import { redirect } from "next/navigation";
import { loadMemberships } from "@/lib/tenant";
import { signOutAction } from "@/app/auth/actions";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthStatus } from "@/components/auth/auth-status";
import { Button } from "@/components/ui/button";

export const metadata = { title: "Erişim yok · BoutiqueOS" };

export default async function NoAccessPage() {
  const { memberships, user } = await loadMemberships();

  // Access may have been granted since the last visit.
  if (memberships.length > 0) redirect("/app");

  return (
    <AuthShell
      title="Bağlı bir işletme yok"
      description={
        <>
          Oturumunuz açık, ancak <span className="text-text-primary">{user.email ?? "bu hesap"}</span> henüz
          hiçbir işletmeye aktif üye olarak tanımlanmamış.
        </>
      }
      wide
    >
      <AuthStatus
        className="mt-8"
        title="Bir davet bekliyor olabilirsiniz"
        description="İşletme sahibi sizi eklediğinde ya da bir davet gönderdiğinde bu sayfayı yenilemeniz yeterli."
        action={
          <form action={signOutAction}>
            <Button type="submit" variant="outline" size="md">
              Çıkış yap
            </Button>
          </form>
        }
      />
    </AuthShell>
  );
}
