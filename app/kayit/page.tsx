import { AuthShell, BackToLogin } from "@/components/auth/auth-shell";
import { getPublicPlans } from "@/lib/saas/queries";
import { RegisterForm } from "./register-form";

export const metadata = { title: "Başvuru · BoutiqueOS" };

/**
 * Public registration. A signed-in visitor never sees this page: the middleware sends
 * them to /basvuru, where an existing account applies for a (further) business.
 */
export default async function RegisterPage() {
  const plans = await getPublicPlans();
  return (
    <AuthShell
      title="İşletmenizi BoutiqueOS'a taşıyın"
      description="Hesabınızı oluşturun, işletmenizi tanıtın, planınızı seçin. Başvurunuz incelendikten sonra işletmeniz sizin sahipliğinizde açılır."
      footer={<BackToLogin label="Zaten hesabınız var mı? Giriş yapın" />}
      wide
    >
      <RegisterForm plans={plans} />
    </AuthShell>
  );
}
