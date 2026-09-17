import { redirect } from "next/navigation";
import { requireTenant } from "@/lib/tenant";
import { DEFAULT_TIMEZONE, reportCaps } from "@/lib/reports/model";
import { PageHeader } from "@/components/ui/page-header";
import { TimezoneForm } from "@/components/reports/timezone-form";

export const metadata = { title: "Raporlama ayarları · BoutiqueOS" };

/** The one reporting setting: which calendar the reports count days in. */
export default async function ReportingSettingsPage() {
  const { active } = await requireTenant();
  if (!reportCaps(active.role).canConfigure) redirect("/app/ayarlar");
  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow={{ href: "/app/ayarlar", label: "Ayarlar" }}
        title="Raporlama"
        description="Bugün, dün, bu ay gibi dönemler bu saat dilimine göre hesaplanır; satışlar kendi anlarına göre o günlere düşer."
      />
      <section className="space-y-3">
        <p className="text-xs text-text-muted">
          Şu an: <span className="font-medium text-text-secondary" data-numeric>{active.timezone ?? `${DEFAULT_TIMEZONE} (varsayılan, ayarlanmamış)`}</span>
        </p>
        <TimezoneForm current={active.timezone} />
      </section>
    </div>
  );
}
