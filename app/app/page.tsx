import Link from "next/link";
import { ScanLine } from "lucide-react";
import { requireTenant } from "@/lib/tenant";
import { loadDashboard } from "@/lib/dashboard/queries";
import { Button } from "@/components/ui/button";
import { ActivityBlock, AttentionBlock, QuickActions, StarterBlock, TodayBlock } from "@/components/dashboard/home";

/**
 * Home: the boutique's operational start screen. Greeting and shop, one primary action
 * ("Satış yap" for whoever may sell), four shortcuts, today's number, what needs
 * attention, and — for a shop that has not yet done the three first things — a small
 * starter list. Everything comes from bounded server reads in one parallel round; what
 * a role may not read is never queried for it.
 */
function greeting(timezone: string | null): string {
  const hour = Number(new Intl.DateTimeFormat("tr-TR", { hour: "numeric", hour12: false, timeZone: timezone ?? "Europe/Istanbul" }).format(new Date()));
  if (hour < 6) return "İyi geceler";
  if (hour < 12) return "Günaydın";
  if (hour < 18) return "İyi günler";
  return "İyi akşamlar";
}

export default async function AppHomePage() {
  const { profile, user, active, branch } = await requireTenant();
  const d = await loadDashboard();
  const first = (profile.full_name?.trim() || user.email?.split("@")[0] || "").split(/\s+/)[0];
  const openSession = d.openSessions[0] ?? null;

  return (
    <div className="space-y-10">
      <header className="space-y-5">
        <div>
          <p className="text-sm text-text-muted">
            {greeting(active.timezone)}
            {first ? `, ${first}` : ""}
          </p>
          <h1 className="mt-1 font-serif text-4xl font-medium leading-none tracking-tightish text-text-primary">{active.business_name}</h1>
          {branch ? <p className="mt-2 text-sm text-text-muted">{branch.name}</p> : null}
        </div>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:gap-4">
          {d.caps.canSell ? (
            <Link href="/app/pos" className="contents" data-testid="primary-sell">
              <Button variant="accent" size="lg" className="w-full sm:w-auto">
                <ScanLine aria-hidden className="h-4 w-4" />
                Satış yap
              </Button>
            </Link>
          ) : null}
          <QuickActions caps={d.caps} />
        </div>
      </header>

      {d.starter ? <StarterBlock starter={d.starter} caps={d.caps} /> : null}

      <TodayBlock today={d.today} openSession={openSession} />

      <AttentionBlock items={d.attention} />

      <ActivityBlock items={d.activity} timezone={d.timezone} />
    </div>
  );
}
