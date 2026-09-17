import * as React from "react";
import Link from "next/link";
import { PageHeader } from "@/components/ui/page-header";
import { Select } from "@/components/ui/select";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { PERIOD_PRESETS, type Period, type ReportCaps } from "@/lib/reports/model";
import { formatPeriod, periodQuery } from "@/lib/reports/period";
import { cn } from "@/lib/utils";

/**
 * The frame every report page shares: title, the report switcher, the period bar.
 * Everything is a GET link or a GET form, so a report is a URL that can be reopened
 * or sent to a colleague; the page re-runs one aggregate RPC for it.
 */

export const REPORT_LINKS: Array<{ href: string; label: string; needs?: keyof ReportCaps }> = [
  { href: "/app/raporlar", label: "Genel bakış", needs: "canViewSales" },
  { href: "/app/raporlar/satis", label: "Satış", needs: "canViewSales" },
  { href: "/app/raporlar/urunler", label: "Ürünler", needs: "canViewSales" },
  { href: "/app/raporlar/personel", label: "Personel", needs: "canViewSales" },
  { href: "/app/raporlar/odemeler", label: "Ödemeler", needs: "canViewFinancial" },
  { href: "/app/raporlar/stok", label: "Stok", needs: "canViewStock" },
  { href: "/app/raporlar/mal-kabul", label: "Mal kabul", needs: "canViewFinancial" },
  { href: "/app/raporlar/musteriler", label: "Müşteriler", needs: "canViewSales" },
  { href: "/app/raporlar/iadeler", label: "İadeler", needs: "canViewSales" },
];

export function ReportNav({ current, caps, query }: { current: string; caps: ReportCaps; query: string }) {
  return (
    <nav aria-label="Raporlar" className="-mx-5 overflow-x-auto px-5 sm:mx-0 sm:px-0">
      <ul className="flex min-w-max gap-1 border-b border-border text-sm">
        {REPORT_LINKS.filter((l) => !l.needs || caps[l.needs]).map((l) => {
          const active = l.href === current;
          return (
            <li key={l.href}>
              <Link
                href={l.href + (l.href === "/app/raporlar/stok" ? "" : query)}
                aria-current={active ? "page" : undefined}
                className={cn(
                  "-mb-px inline-flex h-10 items-center border-b-2 px-3 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                  active ? "border-text-primary font-medium text-text-primary" : "border-transparent text-text-muted hover:text-text-primary",
                )}
              >
                {l.label}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

/** Quick presets as links, a custom range as a small GET form, the branch as a select. */
export function PeriodBar({
  basePath,
  period,
  branches,
  branchId,
  extra = {},
}: {
  basePath: string;
  period: Period;
  branches: Array<{ id: string; name: string }>;
  branchId: string | null;
  /** Other query params the page owns (grouping etc.) that must survive a period change. */
  extra?: Record<string, string | undefined>;
}) {
  const keep = { ...extra, sube: branchId ?? undefined };
  return (
    <section aria-label="Dönem" className="space-y-3 rounded border border-border bg-background/60 p-4">
      <div className="flex flex-wrap items-center gap-1.5">
        {PERIOD_PRESETS.filter((p) => p.key !== "custom").map((p) => {
          const active = period.preset === p.key;
          return (
            <Link
              key={p.key}
              href={basePath + periodQuery({ ...period, preset: p.key }, keep)}
              aria-current={active ? "true" : undefined}
              className={cn(
                "inline-flex h-9 items-center rounded border px-3 text-xs focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                active ? "border-text-primary bg-surface font-medium text-text-primary" : "border-border text-text-secondary hover:border-border-strong hover:text-text-primary",
              )}
            >
              {p.label}
            </Link>
          );
        })}
      </div>
      <form method="get" action={basePath} className="grid grid-cols-2 items-end gap-3 sm:grid-cols-[auto_auto_auto_auto] sm:gap-x-3">
        <input type="hidden" name="d" value="custom" />
        {Object.entries(extra).map(([k, v]) => (v ? <input key={k} type="hidden" name={k} value={v} /> : null))}
        <label className="space-y-1 text-xs text-text-muted">
          <span>Başlangıç</span>
          <Input type="date" name="from" defaultValue={period.preset === "custom" ? period.from : ""} className="h-9" />
        </label>
        <label className="space-y-1 text-xs text-text-muted">
          <span>Bitiş</span>
          <Input type="date" name="to" defaultValue={period.preset === "custom" ? period.to : ""} className="h-9" />
        </label>
        {branches.length > 1 ? (
          <label className="space-y-1 text-xs text-text-muted">
            <span>Şube</span>
            <Select name="sube" defaultValue={branchId ?? ""} className="h-9 sm:h-9">
              <option value="">Tüm şubeler</option>
              {branches.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </Select>
          </label>
        ) : null}
        <Button type="submit" size="sm" variant="outline" className="h-9">
          Özel tarih
        </Button>
      </form>
      <p className="text-xs text-text-muted" data-numeric>
        <span className="font-medium text-text-secondary">{formatPeriod(period.from, period.to)}</span>
        {" · "}
        {period.timezone}
        {!period.timezoneSet ? (
          <>
            {" · "}
            <span>
              saat dilimi ayarlanmamış, varsayılan kullanılıyor —{" "}
              <Link href="/app/ayarlar/raporlama" className="underline underline-offset-4 hover:text-text-primary">ayarla</Link>
            </span>
          </>
        ) : null}
        {branchId ? ` · ${branches.find((b) => b.id === branchId)?.name ?? ""}` : branches.length > 1 ? " · tüm şubeler" : ""}
      </p>
    </section>
  );
}

export function ReportPage({
  title,
  description,
  current,
  caps,
  query,
  children,
  actions,
}: {
  title: string;
  description?: React.ReactNode;
  current: string;
  caps: ReportCaps;
  query: string;
  children: React.ReactNode;
  actions?: React.ReactNode;
}) {
  return (
    <div className="space-y-6">
      <PageHeader eyebrow="Raporlar" title={title} description={description} actions={actions} />
      <ReportNav current={current} caps={caps} query={query} />
      {children}
    </div>
  );
}

/** Scope note for sales_staff: their reports are their own sales, per the tenant policy. */
export function ScopeNote({ scope }: { scope: string }) {
  if (scope === "business") return null;
  return (
    <p className="text-xs text-text-muted">
      {scope === "own" ? "Bu rapor yalnız sizin sattığınız ya da size atanmış satışları kapsar." : "Bu rapor şubenizin satışlarını kapsar."}
    </p>
  );
}
