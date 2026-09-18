import { redirect } from "next/navigation";
import { loadMemberships } from "@/lib/tenant";
import { getMyOnboarding } from "@/lib/saas/queries";
import { BUSINESS_STATUS_LABELS } from "@/lib/saas/model";
import { signOutAction } from "@/app/auth/actions";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthStatus } from "@/components/auth/auth-status";
import { Button } from "@/components/ui/button";

export const metadata = { title: "Hesap durumu · BoutiqueOS" };

/**
 * A member whose only business(es) are suspended or cancelled. The page names the
 * business and its state in plain words and nothing else — no reason, no id, no way to
 * change it from here. Reactivation is a platform decision.
 */
export default async function AccountStatusPage() {
  const [{ memberships }, { onboarding }] = await Promise.all([loadMemberships(), getMyOnboarding()]);
  if (memberships.length > 0) redirect("/app");
  if (onboarding.inactive_businesses.length === 0) redirect("/no-access");

  return (
    <AuthShell
      title="İşletmeniz şu anda kullanıma kapalı"
      description="Üyesi olduğunuz işletme platform tarafından askıya alınmış ya da kapatılmış. Bu süre boyunca uygulamaya giriş yapılamaz; verileriniz korunur."
      wide
    >
      <ul className="mt-8 divide-y divide-border border-y border-border text-sm">
        {onboarding.inactive_businesses.map((b) => (
          <li key={b.name} className="flex items-center justify-between gap-4 py-3">
            <span className="text-text-primary">{b.name}</span>
            <span className="text-text-muted">{BUSINESS_STATUS_LABELS[b.status]}</span>
          </li>
        ))}
      </ul>
      <AuthStatus
        className="mt-8"
        tone="warning"
        title="Ne yapmalıyım?"
        description="Ödeme ya da sözleşme kaynaklı bir askıya almaysa platform ekibiyle iletişime geçin; işletme yeniden açıldığında aynı hesapla giriş yapabilirsiniz."
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
