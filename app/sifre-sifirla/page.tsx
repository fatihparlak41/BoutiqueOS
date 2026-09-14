import { AuthShell, BackToLogin } from "@/components/auth/auth-shell";
import { AuthStatus } from "@/components/auth/auth-status";
import { ResetRequestForm } from "./reset-request-form";

export const metadata = { title: "Parola sıfırlama · BoutiqueOS" };

/**
 * `durum` is set by /auth/confirm when an emailed link could not be verified — expired,
 * already used, or malformed. Which of those it was is not said: the sentence is the
 * same for all, and a fresh link fixes every case.
 */
const NOTICE: Record<string, { title: string; description: string }> = {
  gecersiz: {
    title: "Bu bağlantı artık geçerli değil",
    description:
      "Bağlantının süresi dolmuş ya da daha önce kullanılmış olabilir. Aşağıdan yeni bir bağlantı isteyin.",
  },
};

export default async function ResetRequestPage({
  searchParams,
}: {
  searchParams: Promise<{ durum?: string }>;
}) {
  const { durum } = await searchParams;
  const notice = durum ? NOTICE[durum] : undefined;

  return (
    <AuthShell
      title="Parolanızı sıfırlayın"
      description="Hesabınızın e-posta adresini yazın. Kayıtlıysa sıfırlama bağlantısı gönderilir."
      footer={<BackToLogin />}
    >
      {notice ? (
        <AuthStatus tone="warning" title={notice.title} description={notice.description} className="mt-6" />
      ) : null}

      <ResetRequestForm />
    </AuthShell>
  );
}
