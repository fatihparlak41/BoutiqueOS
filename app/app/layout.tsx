import { requireTenant, ROLE_LABELS } from "@/lib/tenant";
import { Wordmark } from "@/components/brand";
import { PrimaryNav } from "@/components/shell/primary-nav";
import { AccountMenu } from "@/components/shell/account-menu";

export const metadata = { title: "BoutiqueOS" };

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { active, branch, memberships, user, profile } = await requireTenant();

  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[15rem_1fr]">
      <aside className="flex flex-col border-b border-line bg-panel/60 lg:h-dvh lg:border-b-0 lg:border-r">
        <div className="flex items-center justify-between px-5 py-4 lg:block">
          <Wordmark className="text-base" />
        </div>
        <PrimaryNav />
        <div className="hidden px-5 py-4 text-2xs text-muted lg:block">Rev 3 · pilot</div>
      </aside>

      <div className="flex min-h-dvh flex-col">
        <header className="flex flex-wrap items-center justify-between gap-4 border-b border-line px-5 py-3 sm:px-8">
          <div className="min-w-0">
            {/* Tenant identity — every value below comes from Supabase, none from client state. */}
            <h1 className="truncate font-serif text-lg leading-tight tracking-tightish">
              {active.business_name}
            </h1>
            <p className="mt-0.5 truncate text-xs text-muted">
              {branch ? `${branch.name} (${branch.code})` : "Şube atanmamış"}
              <span aria-hidden className="mx-2 text-line-strong">·</span>
              {ROLE_LABELS[active.role]}
            </p>
          </div>

          <AccountMenu
            email={user.email}
            fullName={profile.full_name}
            canSwitchBusiness={memberships.length > 1}
          />
        </header>

        <main className="flex-1 px-5 py-8 sm:px-8">{children}</main>
      </div>
    </div>
  );
}
