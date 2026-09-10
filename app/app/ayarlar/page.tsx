import Link from "next/link";
import { Users } from "lucide-react";
import { requireTenant } from "@/lib/tenant";

export const metadata = { title: "Ayarlar · BoutiqueOS" };

/**
 * Settings hub. Only sections that actually exist are listed — an inert row here would
 * be the same broken promise the navigation already avoids.
 */
export default async function SettingsPage() {
  const { active } = await requireTenant();
  const isManagerPlus = active.role === "owner" || active.role === "manager";

  return (
    <div className="max-w-3xl space-y-8">
      <header>
        <h2 className="font-serif text-xl leading-tight tracking-tightish">Ayarlar</h2>
        <p className="mt-1 text-xs leading-relaxed text-muted">
          {active.business_name} işletmesinin yapılandırması.
        </p>
      </header>

      {isManagerPlus ? (
        <ul className="grid gap-3 sm:grid-cols-2">
          <li>
            <Link
              href="/app/ayarlar/ekip"
              className="flex h-full gap-3 border border-line p-4 transition-colors hover:border-line-strong hover:bg-panel/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
            >
              <Users aria-hidden className="mt-0.5 h-4 w-4 shrink-0 stroke-[1.5] text-accent" />
              <span>
                <span className="block text-sm font-medium">Ekip</span>
                <span className="mt-1 block text-xs leading-relaxed text-muted">
                  Çalışanları davet edin, rol ve şube atayın, erişimi açıp kapatın.
                </span>
              </span>
            </Link>
          </li>
        </ul>
      ) : (
        <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">
          Bu bölüm işletme sahibi ve yöneticiler içindir.
        </p>
      )}
    </div>
  );
}
