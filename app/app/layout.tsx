import { requireTenant } from "@/lib/tenant";
import { Wordmark } from "@/components/brand";
import { PrimaryNav } from "@/components/shell/primary-nav";
import { BusinessPlate } from "@/components/shell/business-plate";
import { AccountMenu } from "@/components/shell/account-menu";
import { MobileNav } from "@/components/shell/mobile-nav";

export const metadata = { title: "BoutiqueOS" };

/**
 * Authenticated shell.
 *
 * Desktop: a quiet rail on the left — wordmark, the tenant's plate, grouped navigation,
 * the account at the foot — and a content column of bounded width. Below lg the rail
 * folds into a top bar with the tenant's name and a drawer; the page keeps the full width.
 *
 * Tenant identity, role and branch come from requireTenant() on the server; the shell
 * shows them and decides nothing.
 */
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { active, branch, memberships, user, profile } = await requireTenant();
  const canSwitch = memberships.length > 1;

  const plate = <BusinessPlate active={active} branch={branch} canSwitch={canSwitch} />;
  const account = <AccountMenu email={user.email} fullName={profile.full_name} />;

  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[15.5rem_minmax(0,1fr)]">
      {/* desktop rail */}
      <aside className="hidden border-r border-border bg-background lg:sticky lg:top-0 lg:flex lg:h-dvh lg:flex-col">
        <div className="px-5 pb-5 pt-6">
          <Wordmark className="text-lg" />
        </div>
        <div className="px-5 pb-6">{plate}</div>
        <div className="min-h-0 flex-1 overflow-y-auto px-2 pb-4">
          <PrimaryNav />
        </div>
        <div className="border-t border-border px-5 py-4">{account}</div>
      </aside>

      {/* phone / tablet top bar */}
      <header className="sticky top-0 z-10 flex items-center justify-between gap-3 border-b border-border bg-background/95 px-3 py-2 backdrop-blur-sm lg:hidden">
        <div className="flex min-w-0 items-center gap-2">
          <MobileNav
            footer={
              <>
                {plate}
                {account}
              </>
            }
          />
          <div className="min-w-0">
            <p className="truncate text-sm font-medium leading-tight text-text-primary">{active.business_name}</p>
            <p className="truncate text-2xs text-text-muted">{branch ? branch.name : "Şube atanmamış"}</p>
          </div>
        </div>
        <Wordmark className="pr-2 text-base" />
      </header>

      <div className="flex min-h-dvh min-w-0 flex-col bg-surface lg:min-h-0">
        <main className="mx-auto w-full max-w-content flex-1 px-5 py-6 sm:px-8 sm:py-8 lg:px-10 lg:py-10">
          {children}
        </main>
      </div>
    </div>
  );
}
