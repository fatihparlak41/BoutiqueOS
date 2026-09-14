import Link from "next/link";
import { ChevronRight, Users } from "lucide-react";
import { requireTenant } from "@/lib/tenant";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";

export const metadata = { title: "Ayarlar · BoutiqueOS" };

/**
 * Settings hub. Only sections that actually exist are listed — an inert row here would
 * be the same broken promise the navigation already avoids. Who may open a section is
 * decided by the section itself on the server; this page only avoids listing what the
 * role cannot use.
 */
export default async function SettingsPage() {
  const { active } = await requireTenant();
  const isManagerPlus = active.role === "owner" || active.role === "manager";

  return (
    <div className="space-y-8">
      <PageHeader title="Ayarlar" description={`${active.business_name} işletmesinin yapılandırması.`} />

      {isManagerPlus ? (
        <ul className="divide-y divide-border border-y border-border">
          <li>
            <Link
              href="/app/ayarlar/ekip"
              className="group flex items-center gap-4 py-4 transition-colors hover:bg-surface-muted/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:px-2"
            >
              <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded border border-border bg-background text-accent">
                <Users aria-hidden className="h-4 w-4 stroke-[1.5]" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-medium text-text-primary">Ekip</span>
                <span className="mt-0.5 block text-xs leading-relaxed text-text-muted">
                  Çalışanları davet edin, rol ve şube atayın, erişimi açıp kapatın.
                </span>
              </span>
              <ChevronRight aria-hidden className="h-4 w-4 shrink-0 stroke-[1.5] text-text-muted group-hover:text-text-primary" />
            </Link>
          </li>
        </ul>
      ) : (
        <EmptyState
          compact
          title="Bu bölümde sizin için bir ayar yok"
          description="İşletme ayarları sahip ve yöneticiler tarafından yönetilir. Bir değişiklik gerekiyorsa yöneticinize iletin."
        />
      )}
    </div>
  );
}
