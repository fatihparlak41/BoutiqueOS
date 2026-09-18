import { redirect } from "next/navigation";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthStatus } from "@/components/auth/auth-status";
import { signOutAction } from "@/app/auth/actions";
import { Button } from "@/components/ui/button";
import { getMyOnboarding, getPublicPlans } from "@/lib/saas/queries";
import { ApplicationForm } from "./application-form";
import { ResendConfirmation } from "./resend-confirmation";

export const metadata = { title: "İşletme başvurusu · BoutiqueOS" };

/**
 * Where the confirmation link lands, and where an existing account applies for a
 * further business. A pending application goes to its waiting page; an unconfirmed
 * account is told to open its link first (the RPC would refuse it anyway).
 */
export default async function ApplicationPage() {
  const [{ email, confirmed, onboarding, draft }, plans] = await Promise.all([getMyOnboarding(), getPublicPlans()]);

  if (onboarding.application?.status === "pending") redirect("/basvuru-bekliyor");

  if (!confirmed) {
    return (
      <AuthShell title="Önce e-postanızı doğrulayın" description="Başvuru yalnız doğrulanmış bir adresle alınır." wide>
        <AuthStatus
          className="mt-8"
          tone="warning"
          title="Doğrulama bekleniyor"
          description={
            <>
              <span className="text-text-primary">{email ?? "Adresiniz"}</span> için gönderilen bağlantıyı açın; sonra bu
              sayfa başvurunuzu alır.
            </>
          }
          action={<ResendConfirmation />}
        />
      </AuthShell>
    );
  }

  const previous = onboarding.application;

  return (
    <AuthShell
      title={draft ? "Başvurunuzu tamamlayın" : "Yeni işletme başvurusu"}
      description={
        draft
          ? "E-postanız doğrulandı. Kayıtta verdiğiniz bilgileri kontrol edin ve başvuruyu gönderin."
          : "İşletmenizi tanıtın ve planınızı seçin. Başvurunuz platform tarafından incelenir; onaylandığında işletme sizin sahipliğinizde açılır."
      }
      footer={
        <form action={signOutAction}>
          <Button type="submit" variant="ghost" size="sm">
            Çıkış yap
          </Button>
        </form>
      }
      wide
    >
      {previous?.status === "rejected" ? (
        <AuthStatus
          className="mt-6"
          tone="warning"
          title={`"${previous.business_name}" başvurusu kabul edilmedi`}
          description={previous.review_note ?? "Yeniden başvurabilirsiniz."}
        />
      ) : null}
      <ApplicationForm draft={draft} plans={plans} />
    </AuthShell>
  );
}
