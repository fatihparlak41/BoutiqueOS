import * as React from "react";
import Link from "next/link";
import { PageHeader } from "@/components/ui/page-header";
import { Select } from "@/components/ui/select";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { INTEL_DEFINITIONS, INTEL_WINDOWS, type IntelCaps, type IntelThresholds, type IntelWindow } from "@/lib/intel/model";
import { formatPeriod } from "@/lib/reports/period";
import { fmtInt } from "@/components/reports/format";
import { cn } from "@/lib/utils";

/** Frame of the intelligence pages: title, the two surfaces, the window, the thresholds that explain every list. */

const LINKS = [
  { href: "/app/analiz", label: "Sinyaller" },
  { href: "/app/analiz/beden-renk", label: "Beden & renk" },
];

export function IntelPage({
  title, description, current, caps, query, children,
}: { title: string; description?: React.ReactNode; current: string; caps: IntelCaps; query: string; children: React.ReactNode }) {
  return (
    <div className="space-y-6">
      <PageHeader eyebrow="Analiz" title={title} description={description} />
      <nav aria-label="Analiz" className="-mx-5 overflow-x-auto px-5 sm:mx-0 sm:px-0">
        <ul className="flex min-w-max gap-1 border-b border-border text-sm">
          {LINKS.filter((l) => caps.canView).map((l) => (
            <li key={l.href}>
              <Link
                href={l.href + query}
                aria-current={l.href === current ? "page" : undefined}
                className={cn(
                  "-mb-px inline-flex h-10 items-center border-b-2 px-3 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                  l.href === current ? "border-text-primary font-medium text-text-primary" : "border-transparent text-text-muted hover:text-text-primary",
                )}
              >
                {l.label}
              </Link>
            </li>
          ))}
        </ul>
      </nav>
      {children}
    </div>
  );
}

/** Window presets as links plus the branch select; the thresholds fold away under them. */
export function WindowBar({
  basePath, window, days, branches, branchId, thresholds, extra = {},
}: {
  basePath: string;
  window: IntelWindow;
  days: number;
  branches: Array<{ id: string; name: string }>;
  branchId: string | null;
  thresholds?: IntelThresholds;
  extra?: Record<string, string | undefined>;
}) {
  const q = (d: number) => {
    const p = new URLSearchParams();
    p.set("gun", String(d));
    if (branchId) p.set("sube", branchId);
    for (const [k, v] of Object.entries(extra)) if (v) p.set(k, v);
    return `?${p.toString()}`;
  };
  return (
    <section aria-label="Dönem" className="space-y-3 rounded border border-border bg-background/60 p-4">
      <div className="flex flex-wrap items-center gap-1.5">
        {INTEL_WINDOWS.map((w) => (
          <Link
            key={w.days}
            href={basePath + q(w.days)}
            aria-current={w.days === days ? "true" : undefined}
            className={cn(
              "inline-flex h-9 items-center rounded border px-3 text-xs focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
              w.days === days ? "border-text-primary bg-surface font-medium text-text-primary" : "border-border text-text-secondary hover:border-border-strong hover:text-text-primary",
            )}
          >
            {w.label}
          </Link>
        ))}
        {branches.length > 1 ? (
          <form method="get" action={basePath} className="flex items-center gap-2">
            <input type="hidden" name="gun" value={days} />
            {Object.entries(extra).map(([k, v]) => (v ? <input key={k} type="hidden" name={k} value={v} /> : null))}
            <Select name="sube" defaultValue={branchId ?? ""} className="h-9 w-auto sm:h-9">
              <option value="">Tüm şubeler</option>
              {branches.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </Select>
            <Button type="submit" size="sm" variant="outline" className="h-9">Uygula</Button>
          </form>
        ) : null}
      </div>
      <p className="text-xs text-text-muted" data-numeric>
        <span className="font-medium text-text-secondary">{formatPeriod(window.from, window.to)}</span> · {window.timezone}
        {branchId ? ` · ${branches.find((b) => b.id === branchId)?.name ?? ""}` : branches.length > 1 ? " · tüm şubeler" : ""}
      </p>
      {thresholds ? (
        <details className="text-xs">
          <summary className="cursor-pointer text-text-secondary hover:text-text-primary">
            Eşikler: örneklem {fmtInt(thresholds.min_sample)} adet · min. stok {fmtInt(thresholds.min_stock)} · yavaş: {fmtInt(thresholds.slow_age_days)} gün / {fmtInt(thresholds.slow_no_sale_days)} gün satışsız / ≥ {fmtInt(thresholds.slow_min_qty)} adet · sipariş: ≥ {fmtInt(thresholds.replenish_min_sold)} satış · fazla: ≥ {fmtInt(thresholds.excess_min_qty)} adet, ≥ {fmtInt(thresholds.excess_cover_days)} günlük
          </summary>
          <form method="get" action={basePath} className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
            <input type="hidden" name="gun" value={days} />
            {branchId ? <input type="hidden" name="sube" value={branchId} /> : null}
            {[
              ["orneklem", "Örneklem eşiği (adet)", thresholds.min_sample],
              ["min_stok", "Minimum stok", thresholds.min_stock],
              ["yavas_yas", "Yavaş: yaş (gün)", thresholds.slow_age_days],
              ["yavas_satis", "Yavaş: satışsız gün", thresholds.slow_no_sale_days],
              ["yavas_adet", "Yavaş: en az müsait", thresholds.slow_min_qty],
              ["siparis_adet", "Sipariş: en az satış", thresholds.replenish_min_sold],
              ["fazla_adet", "Fazla: en az müsait", thresholds.excess_min_qty],
              ["fazla_gun", "Fazla: günlük stok", thresholds.excess_cover_days],
            ].map(([name, label, value]) => (
              <label key={String(name)} className="space-y-1 text-text-muted">
                <span>{label}</span>
                <Input name={String(name)} type="number" min={0} defaultValue={Number(value)} className="h-9" />
              </label>
            ))}
            <div className="col-span-2 flex items-center gap-3 sm:col-span-4">
              <Button type="submit" size="sm" variant="outline" className="h-9">Eşikleri uygula</Button>
              <Link href={basePath + q(days)} className="text-text-muted underline-offset-4 hover:text-text-primary hover:underline">Varsayılanlara dön</Link>
            </div>
          </form>
        </details>
      ) : null}
    </section>
  );
}

export function IntelDefinitions({ financial }: { financial: boolean }) {
  return (
    <details className="rounded border border-border bg-background/60 px-4 py-3 text-xs">
      <summary className="cursor-pointer text-text-secondary hover:text-text-primary">Bu sinyaller nasıl hesaplanır?</summary>
      <dl className="mt-3 grid gap-x-6 gap-y-2 sm:grid-cols-2">
        {INTEL_DEFINITIONS.filter((d) => financial || !d.financial).map((d) => (
          <div key={d.label}>
            <dt className="font-medium text-text-primary">{d.label}</dt>
            <dd className="text-text-muted">{d.definition}</dd>
          </div>
        ))}
      </dl>
    </details>
  );
}

/** A horizontal share bar; width is the share, the label is the number — never a colour code for "good" or "bad". */
export function ShareBar({ pct, label }: { pct: number | null; label: string }) {
  return (
    <span className="flex items-center gap-2" data-numeric>
      <span className="h-1.5 w-24 shrink-0 overflow-hidden rounded-sm bg-surface-muted" aria-hidden>
        <span className="block h-full bg-text-primary/70" style={{ width: `${Math.max(0, Math.min(100, pct ?? 0))}%` }} />
      </span>
      <span className="text-xs text-text-secondary">{label}</span>
    </span>
  );
}
