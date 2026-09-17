import * as React from "react";
import Link from "next/link";
import { EmptyState } from "@/components/ui/empty-state";
import { SectionHeader } from "@/components/ui/section-header";
import { fmtInt, fmtMoney, fmtPct } from "@/components/reports/format";
import type { BrokenSizeRun, FastMover, HoldSignal, ReturnSignal, VariantSignal } from "@/lib/intel/model";

/** Compact insight rows: a name, its identifiers, the numbers, and the sentence that put it on the list. */

function VariantLabel({ r }: { r: { product_id: string; product: string; sku: string; size: string | null; color: string | null } }) {
  return (
    <span className="min-w-0">
      <Link href={`/app/urunler/${r.product_id}`} className="block truncate text-sm font-medium text-text-primary hover:underline">{r.product}</Link>
      <span className="mt-0.5 block text-2xs text-text-muted" data-numeric>
        {r.sku}{r.size ? ` · ${r.size}` : ""}{r.color ? ` · ${r.color}` : ""}
      </span>
    </span>
  );
}

export function Section({ title, meta, empty, hint, children, count }: { title: string; meta?: React.ReactNode; empty: string; hint?: string; children?: React.ReactNode; count: number }) {
  return (
    <section className="space-y-3">
      <SectionHeader title={title} meta={meta ?? (count > 0 ? fmtInt(count) : undefined)} />
      {hint ? <p className="text-2xs text-text-muted">{hint}</p> : null}
      {count === 0 ? <EmptyState compact title={empty} /> : children}
    </section>
  );
}

export function VariantRows({ rows, financial, numbers }: { rows: VariantSignal[]; financial: boolean; numbers: (r: VariantSignal) => React.ReactNode }) {
  return (
    <ul className="divide-y divide-border rounded border border-border">
      {rows.map((r) => (
        <li key={r.variant_id} className="grid gap-x-4 gap-y-1 px-4 py-2.5 sm:grid-cols-[minmax(0,1fr)_auto]">
          <VariantLabel r={r} />
          <span className="text-xs text-text-secondary sm:text-right" data-numeric>{numbers(r)}</span>
          {r.why ? <p className="text-xs text-text-muted sm:col-span-2">{r.why}{financial && r.sellable_value !== null && r.sellable_value !== undefined ? ` · stok değeri ${fmtMoney(r.sellable_value)}` : ""}</p> : null}
        </li>
      ))}
    </ul>
  );
}

export function FastMoverRows({ rows }: { rows: FastMover[] }) {
  return (
    <ul className="divide-y divide-border rounded border border-border">
      {rows.map((r, i) => (
        <li key={r.product_id} className="grid gap-x-4 gap-y-1 px-4 py-2.5 sm:grid-cols-[auto_minmax(0,1fr)_auto]">
          <span className="text-xs text-text-muted" data-numeric>{i + 1}.</span>
          <span className="min-w-0">
            <Link href={`/app/urunler/${r.product_id}`} className="block truncate text-sm font-medium text-text-primary hover:underline">{r.product}</Link>
            <span className="mt-0.5 block text-2xs text-text-muted">{r.category ?? "Kategorisiz"}{r.variants_out > 0 ? ` · ${fmtInt(r.variants_out)} varyant tükendi` : ""}</span>
          </span>
          <span className="text-xs text-text-secondary sm:text-right" data-numeric>
            <span className="font-medium text-text-primary">{r.velocity.toLocaleString("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} adet/gün</span>
            {" · "}{fmtInt(r.sold_win)} adet / {fmtInt(r.active_days)} gün · {fmtInt(r.available)} müsait
            {r.days_of_cover !== null ? ` · ${fmtInt(r.days_of_cover)} günlük` : ""}
            {r.sell_through_pct !== null ? ` · sell-through ${fmtPct(r.sell_through_pct)}` : ""}
          </span>
        </li>
      ))}
    </ul>
  );
}

export function BrokenRows({ rows }: { rows: BrokenSizeRun[] }) {
  return (
    <ul className="divide-y divide-border rounded border border-border">
      {rows.map((r) => (
        <li key={r.product_id} className="space-y-1 px-4 py-2.5">
          <Link href={`/app/urunler/${r.product_id}`} className="block text-sm font-medium text-text-primary hover:underline">{r.product}</Link>
          <p className="text-xs text-text-secondary" data-numeric>
            <span className="text-text-muted">Müsait:</span> {r.sizes_available ?? "—"} <span className="ml-2 text-text-muted">Tükenen:</span> <span className="font-medium text-text-primary">{r.sizes_missing ?? "—"}</span>
            {r.sizes_never_stocked ? <span className="ml-2 text-text-muted">Hiç stoklanmayan: {r.sizes_never_stocked}</span> : null}
          </p>
          <p className="text-xs text-text-muted" data-numeric>
            Dönemde {fmtInt(r.sold_win)} adet satıldı{r.sold_win_missing_sizes ? `, ${fmtInt(r.sold_win_missing_sizes)} tanesi tükenen bedenlerden` : ""} · {fmtInt(r.available)} adet müsait{r.holds_active > 0 ? ` · ${fmtInt(r.holds_active)} aktif rezervasyon` : ""}
          </p>
        </li>
      ))}
    </ul>
  );
}

export function ReturnRows({ rows, minSample }: { rows: ReturnSignal[]; minSample: number }) {
  return (
    <ul className="divide-y divide-border rounded border border-border">
      {rows.map((r) => (
        <li key={`${r.kind}:${r.key}`} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 px-4 py-2.5">
          <span className="text-sm text-text-primary">
            {r.label}
            <span className="ml-2 text-2xs text-text-muted">{r.kind === "product" ? "ürün" : r.kind === "size" ? "beden" : "varyant"}</span>
          </span>
          <span className="text-xs text-text-secondary" data-numeric>
            {fmtInt(r.returned_win)} / {fmtInt(r.sold_win)} adet
            {r.meaningful && r.rate_pct !== null ? <span className="ml-2 font-medium text-text-primary">{fmtPct(r.rate_pct)}</span> : <span className="ml-2 text-text-muted">küçük örneklem (&lt; {fmtInt(minSample)} satış)</span>}
          </span>
        </li>
      ))}
    </ul>
  );
}

export function HoldRows({ rows }: { rows: HoldSignal[] }) {
  return (
    <ul className="divide-y divide-border rounded border border-border">
      {rows.map((r) => (
        <li key={r.variant_id} className="grid gap-x-4 gap-y-1 px-4 py-2.5 sm:grid-cols-[minmax(0,1fr)_auto]">
          <VariantLabel r={r} />
          <span className="text-xs text-text-secondary sm:text-right" data-numeric>
            {fmtInt(r.holds_active)} aktif rezervasyon · {fmtInt(r.reserved)} adet rezerve · {fmtInt(r.available)} müsait
            {r.low_stock ? <span className="ml-2 font-medium text-text-primary">stok az</span> : null}
            {r.converted_win + r.cancelled_win + r.expired_win > 0 ? (
              <span className="block text-2xs text-text-muted">dönemde {fmtInt(r.converted_win)} teslim · {fmtInt(r.cancelled_win)} iptal · {fmtInt(r.expired_win)} süresi doldu</span>
            ) : null}
          </span>
        </li>
      ))}
    </ul>
  );
}
