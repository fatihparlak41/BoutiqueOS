import Link from "next/link";
import { requireTenant } from "@/lib/tenant";
import { navBadges } from "@/lib/shell/badges";
import { Wordmark } from "@/components/brand";
import { PrimaryNav } from "@/components/shell/primary-nav";
import { BusinessPlate } from "@/components/shell/business-plate";
import { AccountMenu } from "@/components/shell/account-menu";
import { MobileNav } from "@/components/shell/mobile-nav";
import { ToastProvider } from "@/components/ui/toast";

export const metadata = { title: "BoutiqueOS" };

/**
 * Authenticated shell.
 *
 * Desktop: a quiet rail on the left — wordmark, the tenant's plate, grouped navigation
 * filtered by role, the account at the foot — and a content column of bounded width.
 * Below lg: a slim top bar that names the boutique, a bottom bar with the operational
 * doors and "Menü" (the full navigation sheet). The bottom bar steps aside on screens
 * that own their bottom edge (POS, counting, intake).
 *
 * Tenant identity, role and branch come from requireTenant() on the server; the shell
 * shows them and decides nothing. Badges are one bounded read (new online orders) for
 * roles that handle them.
 */
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { active, branch, memberships, user, profile } = await requireTenant();
  const canSwitch = memberships.length > 1;
  const badges = await navBadges(active.role);

  const plate = <BusinessPlate active={active} branch={branch} canSwitch={canSwitch} />;
  const account = <AccountMenu email={user.email} fullName={profile.full_name} />;

  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[15.5rem_minmax(0,1fr)]">
      {/* desktop rail */}
      <aside className="hidden border-r border-border bg-background lg:sticky lg:top-0 lg:flex lg:h-dvh lg:flex-col">
        <div className="px-5 pb-5 pt-6">
          <Wordmark className="text-xl" />
        </div>
        <div className="px-5 pb-6">{plate}</div>
        <div className="min-h-0 flex-1 overflow-y-auto px-2 pb-4">
          <PrimaryNav role={active.role} badges={badges} />
        </div>
        <div className="border-t border-border px-5 py-4">{account}</div>
      </aside>

      {/* phone / tablet top bar: which boutique, nothing else */}
      <header className="sticky top-0 z-10 flex items-center justify-between gap-3 border-b border-border bg-background/95 px-4 py-2 backdrop-blur-sm lg:hidden">
        <div className="flex min-w-0 items-center gap-1">
          <MobileNav role={active.role} badges={badges} plate={plate} account={account} />
          <Link href="/app" className="min-w-0 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
            <p className="truncate font-serif text-lg font-semibold leading-tight tracking-tightish text-text-primary">{active.business_name}</p>
            <p className="truncate text-2xs text-text-muted">{branch ? branch.name : "Şube atanmamış"}</p>
          </Link>
        </div>
        <Wordmark className="text-base" />
      </header>

      <div className="flex min-h-dvh min-w-0 flex-col bg-surface lg:min-h-0">
        <main className="mx-auto w-full max-w-content flex-1 px-5 pb-24 pt-6 sm:px-8 sm:pt-8 lg:px-10 lg:py-10">
          <ToastProvider>{children}</ToastProvider>
        </main>
      </div>
    </div>
  );
}
