import Link from "next/link";
import { AlertTriangle, ArrowRight, Check, ClipboardCheck, Info, Package, ScanLine, ShoppingBag, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import { SectionHeader } from "@/components/ui/section-header";
import type { Activity, Attention, Dashboard } from "@/lib/dashboard/queries";
import { cn } from "@/lib/utils";

/**
 * The home screen answers three questions in order: what do I do now (one primary
 * action + four shortcuts), how is the shop doing today (one strong number), what needs
 * my attention (only real conditions). No card grid, no charts, nothing invented.
 */

function money(v: number): string {
  return new Intl.NumberFormat("tr-TR", { style: "currency", currency: "TRY", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(v);
}

/** Times in the boutique's day (tenant timezone, Europe/Istanbul until one is set) — the server may run in UTC. */
function when(iso: string, tz: string): string {
  const d = new Date(iso);
  const day = (x: Date) => new Intl.DateTimeFormat("tr-TR", { timeZone: tz, dateStyle: "short" }).format(x);
  const sameDay = day(new Date()) === day(d);
  return new Intl.DateTimeFormat("tr-TR", sameDay ? { timeZone: tz, hour: "2-digit", minute: "2-digit" } : { timeZone: tz, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }).format(d);
}

export function QuickActions({ caps }: { caps: Dashboard["caps"] }) {
  const items = [
    caps.canEditCatalog ? { href: "/app/urunler/katalog-ekle", label: "Ürün ekle", icon: Package } : null,
    caps.canCount ? { href: "/app/stok/sayim", label: "Stok say", icon: ClipboardCheck } : null,
    caps.canAccessCrm ? { href: "/app/musteriler", label: "Müşteriler", icon: Users } : null,
    caps.canViewOrders ? { href: "/app/online-siparisler", label: "Online siparişler", icon: ShoppingBag } : null,
  ].filter((x): x is { href: string; label: string; icon: typeof Package } => !!x);
  if (items.length === 0) return null;
  return (
    <ul className="grid grid-cols-2 gap-2 sm:flex sm:flex-wrap" data-testid="quick-actions">
      {items.map(({ href, label, icon: Icon }) => (
        <li key={href}>
          <Link href={href} className="flex min-h-11 items-center gap-2 rounded border border-border bg-surface px-3 text-sm text-text-primary transition-colors hover:border-border-strong hover:bg-surface-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:min-h-10">
            <Icon aria-hidden className="h-4 w-4 stroke-[1.5] text-text-muted" />
            {label}
          </Link>
        </li>
      ))}
    </ul>
  );
}

export function TodayBlock({ today, openSession }: { today: Dashboard["today"]; openSession: Dashboard["openSessions"][number] | null }) {
  if (!today) return null;
  return (
    <section className="space-y-3" data-testid="today">
      <SectionHeader title="Bugün" meta={today.scope === "own" ? "kendi satışların" : undefined} />
      <div className="flex flex-wrap items-end gap-x-10 gap-y-4 border-y border-border py-5">
        <div>
          <p className="text-xs text-text-muted">Bugünkü satış</p>
          <p className="mt-1 font-serif text-4xl font-medium leading-none tracking-tightish text-text-primary" data-numeric>
            {today.net_sales !== null ? money(today.net_sales) : `${today.units} adet`}
          </p>
          <p className="mt-2 text-sm text-text-secondary" data-numeric>
            {today.transactions} işlem{today.units > 0 ? ` · ${today.units} adet` : ""}
          </p>
        </div>
        <dl className="flex flex-wrap gap-x-8 gap-y-2 text-sm">
          {today.returns_count > 0 ? (
            <div><dt className="text-xs text-text-muted">İade</dt><dd data-numeric className="text-text-primary">{today.returns_count}</dd></div>
          ) : null}
          <div>
            <dt className="text-xs text-text-muted">Kasa</dt>
            <dd className="text-text-primary">{openSession ? `${openSession.register_name} açık` : "Kapalı"}</dd>
          </div>
        </dl>
      </div>
    </section>
  );
}

export function AttentionBlock({ items }: { items: Attention[] }) {
  if (items.length === 0) return null;
  return (
    <section className="space-y-3" data-testid="attention">
      <SectionHeader title="Dikkat" meta={items.length} />
      <ul className="divide-y divide-border border-y border-border">
        {items.map((a) => {
          const Icon = a.level === "warning" ? AlertTriangle : Info;
          return (
            <li key={a.kind} className="flex items-center gap-3 py-3">
              <Icon aria-hidden className={cn("h-4 w-4 shrink-0 stroke-[1.5]", a.level === "warning" ? "text-warning" : "text-text-muted")} />
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium text-text-primary">{a.title}</p>
                <p className="text-xs text-text-muted">{a.detail}</p>
              </div>
              <Link href={a.href} className="shrink-0">
                <Button size="sm" variant="outline">{a.action}</Button>
              </Link>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

export function StarterBlock({ starter, caps }: { starter: NonNullable<Dashboard["starter"]>; caps: Dashboard["caps"] }) {
  const steps = [
    { done: starter.products, label: "İlk ürününü ekle", href: "/app/urunler/katalog-ekle", show: caps.canEditCatalog },
    { done: starter.stock, label: "Stoğunu say", href: "/app/stok/sayim", show: caps.canCount },
    { done: starter.sale, label: "İlk satışını yap", href: "/app/pos", show: caps.canSell },
  ];
  const doneCount = steps.filter((s) => s.done).length;
  return (
    <section className="rounded border border-border bg-surface p-4" data-testid="starter">
      <div className="flex items-baseline justify-between">
        <h2 className="text-sm font-medium text-text-primary">Başlangıç</h2>
        <span className="text-xs text-text-muted" data-numeric>{doneCount} / {steps.length}</span>
      </div>
      <ol className="mt-3 space-y-1">
        {steps.map((s, i) => (
          <li key={s.label} className="flex items-center gap-3 text-sm">
            <span className={cn("inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full border text-2xs", s.done ? "border-success/40 bg-success-muted text-success" : "border-border text-text-muted")}>
              {s.done ? <Check aria-hidden className="h-3.5 w-3.5" /> : i + 1}
            </span>
            {s.done || !s.show ? (
              <span className={cn(s.done ? "text-text-muted line-through" : "text-text-secondary")}>{s.label}</span>
            ) : (
              <Link href={s.href} className="flex min-h-9 items-center gap-1 text-text-primary underline-offset-4 hover:underline">
                {s.label} <ArrowRight aria-hidden className="h-3.5 w-3.5 text-text-muted" />
              </Link>
            )}
          </li>
        ))}
      </ol>
    </section>
  );
}

export function ActivityBlock({ items, timezone }: { items: Activity[]; timezone: string }) {
  if (items.length === 0) return null;
  const Icon = { sale: ScanLine, product: Package, count: ClipboardCheck, order: ShoppingBag };
  return (
    <section className="space-y-3" data-testid="activity">
      <SectionHeader title="Son hareketler" />
      <ul className="divide-y divide-border border-y border-border">
        {items.map((a) => {
          const I = Icon[a.kind];
          return (
            <li key={`${a.kind}-${a.href}`}>
              <Link href={a.href} className="flex min-h-11 items-center gap-3 py-2 text-sm hover:bg-surface-muted/60">
                <I aria-hidden className="h-4 w-4 shrink-0 stroke-[1.5] text-text-muted" />
                <span className="min-w-0 flex-1 truncate text-text-primary">{a.title}</span>
                {a.detail ? <span className="shrink-0 text-xs text-text-secondary" data-numeric>{a.detail}</span> : null}
                <span className="shrink-0 text-2xs text-text-muted" data-numeric>{when(a.when, timezone)}</span>
              </Link>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
