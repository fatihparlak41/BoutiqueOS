import Link from "next/link";
import { redirect } from "next/navigation";
import { loadMemberships } from "@/lib/tenant";
import { getMyOnboarding } from "@/lib/saas/queries";
import { signOutAction } from "@/app/auth/actions";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthStatus } from "@/components/auth/auth-status";
import { Button, buttonVariants } from "@/components/ui/button";

export const metadata = { title: "Erişim yok · BoutiqueOS" };

/**
 * A signed-in account with no active membership and nothing pending. Two ways forward:
 * wait for an invitation, or apply for a business of their own. A rejected application
 * is named here with its note, since the applicant is the one person allowed to read it.
 */
export default async function NoAccessPage() {
  const [{ memberships, user }, { onboarding }] = await Promise.all([loadMemberships(), getMyOnboarding()]);

  // Access may have been granted since the last visit.
  if (memberships.length > 0) redirect("/app");
  if (onboarding.platform_admin) redirect("/platform");
  if (onboarding.application?.status === "pending") redirect("/basvuru-bekliyor");
  if (onboarding.inactive_businesses.length > 0) redirect("/hesap-durumu");

  const rejected = onboarding.application?.status === "rejected" ? onboarding.application : null;

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
      {rejected ? (
        <AuthStatus
          className="mt-8"
          tone="warning"
          title={`"${rejected.business_name}" başvurunuz kabul edilmedi`}
          description={rejected.review_note ?? "Yeniden başvurabilirsiniz."}
        />
      ) : null}
      <AuthStatus
        className="mt-8"
        title="Bir davet bekliyor olabilirsiniz"
        description="İşletme sahibi sizi eklediğinde ya da bir davet gönderdiğinde bu sayfayı yenilemeniz yeterli."
      />
      <AuthStatus
        className="mt-6"
        title="Kendi işletmeniz mi var?"
        description="İşletmenizi BoutiqueOS'a taşımak için başvurun; onaylandığında işletme sizin sahipliğinizde açılır."
        action={
          <div className="flex flex-wrap items-center gap-3">
            <Link href="/basvuru" className={buttonVariants({ size: "md" })}>
              İşletme başvurusu yap
            </Link>
            <form action={signOutAction}>
              <Button type="submit" variant="outline" size="md">
                Çıkış yap
              </Button>
            </form>
          </div>
        }
      />
    </AuthShell>
  );
}
