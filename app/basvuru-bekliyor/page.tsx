import Link from "next/link";
import { redirect } from "next/navigation";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthStatus } from "@/components/auth/auth-status";
import { signOutAction } from "@/app/auth/actions";
import { Button } from "@/components/ui/button";
import { getMyOnboarding } from "@/lib/saas/queries";
import { formatPlanPrice } from "@/lib/saas/model";
import { WithdrawForm } from "./withdraw-form";

export const metadata = { title: "Başvurunuz inceleniyor · BoutiqueOS" };

const dateFmt = new Intl.DateTimeFormat("tr-TR", { dateStyle: "long" });

/**
 * The waiting room. Says what was applied for and what happens next; never a raw id,
 * never a status code. When the application is no longer pending the visitor is sent
 * where they now belong (the app once approved, the form when rejected or withdrawn).
 */
export default async function ApplicationPendingPage() {
  const { email, onboarding } = await getMyOnboarding();
  const app = onboarding.application;

  if (!app) redirect("/basvuru");
  if (app.status === "approved") redirect(app.business_active ? "/app" : "/hesap-durumu");
  if (app.status !== "pending") redirect("/basvuru");

  return (
    <AuthShell
      title="Başvurunuz inceleniyor"
      description={
        <>
          <span className="text-text-primary">{app.business_name}</span> için başvurunuz {dateFmt.format(new Date(app.submitted_at))}{" "}
          tarihinde alındı. Onaylandığında işletmeniz sizin sahipliğinizde açılır ve{" "}
          <span className="text-text-primary">{email}</span> adresiyle giriş yapabilirsiniz.
        </>
      }
      footer={
        <div className="flex items-center gap-4">
          <form action={signOutAction}>
            <Button type="submit" variant="ghost" size="sm">
              Çıkış yap
            </Button>
          </form>
          <Link href="/app" className="underline-offset-4 hover:text-text-primary hover:underline">
            Durumu yenile
          </Link>
        </div>
      }
      wide
    >
      <dl className="mt-8 divide-y divide-border border-y border-border text-sm">
        <div className="flex justify-between gap-4 py-2"><dt className="text-text-muted">Ülke · para birimi</dt><dd className="text-text-primary">{app.country} · {app.currency}</dd></div>
        <div className="flex justify-between gap-4 py-2"><dt className="text-text-muted">Plan</dt><dd className="text-right text-text-primary">{app.plan ? `${app.plan.name} — ${formatPlanPrice(app.plan)}` : "Seçilmedi"}</dd></div>
        <div className="flex justify-between gap-4 py-2"><dt className="text-text-muted">Durum</dt><dd className="text-text-primary">İnceleniyor</dd></div>
      </dl>
      <AuthStatus
        className="mt-8"
        title="Ödeme, başvuru onayından sonra tamamlanacaktır."
        description="Bu aşamada kart bilgisi istenmez ve ücret alınmaz. Onay e-posta ile bildirilir; bu sayfayı yenileyerek de kontrol edebilirsiniz."
        action={<WithdrawForm applicationId={app.application_id} />}
      />
    </AuthShell>
  );
}
