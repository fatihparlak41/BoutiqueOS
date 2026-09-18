import Link from "next/link";
import { requirePlatformAdmin } from "@/lib/platform/queries";
import { Wordmark } from "@/components/brand";
import { AccountMenu } from "@/components/shell/account-menu";
import { PlatformNav } from "@/components/platform/platform-nav";

export const metadata = { title: "Platform · BoutiqueOS" };

/**
 * Platform console shell. Deliberately not the tenant shell: no business plate, no
 * branch, no tenant navigation — this surface belongs to the operator of BoutiqueOS,
 * not to any tenant. A visitor without the platform role gets the site's 404.
 */
export default async function PlatformLayout({ children }: { children: React.ReactNode }) {
  const { email, pendingApplications } = await requirePlatformAdmin();
  return (
    <div className="min-h-dvh bg-surface">
      <header className="sticky top-0 z-10 border-b border-border bg-background/95 backdrop-blur-sm">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-2.5 sm:px-6">
          <div className="flex min-w-0 items-center gap-4">
            <Wordmark className="text-base" />
            <span className="rounded-sm border border-accent/25 bg-accent-muted px-1.5 py-0.5 text-2xs font-medium text-accent">Platform</span>
          </div>
          <div className="flex items-center gap-4">
            <Link href="/app" className="hidden text-xs text-text-muted underline-offset-4 hover:text-text-primary hover:underline sm:inline">
              Uygulamaya dön
            </Link>
            <AccountMenu email={email} fullName={null} />
          </div>
        </div>
        <div className="mx-auto max-w-6xl px-4 sm:px-6">
          <PlatformNav pending={pendingApplications} />
        </div>
      </header>
      {/* px-5 on phones: TableShell bleeds -mx-5 and must stay inside the viewport */}
      <main className="mx-auto w-full max-w-6xl px-5 py-8 sm:px-6">{children}</main>
    </div>
  );
}
