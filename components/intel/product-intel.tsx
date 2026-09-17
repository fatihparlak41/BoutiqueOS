import * as React from "react";
import Link from "next/link";
import { Stat, StatGrid } from "@/components/ui/stat";
import { SectionHeader } from "@/components/ui/section-header";
import { ShareBar } from "@/components/intel/intel-shell";
import { fmtInt, fmtMoney, fmtPct } from "@/components/reports/format";
import type { IntelProduct } from "@/lib/intel/model";

/**
 * Compact intelligence block on the product page (manager+): velocity, sell-through,
 * size / colour distribution, stock, holds, return rate, age. One RPC, rendered as it
 * came; sparse data is said out loud rather than padded.
 */
export function ProductIntel({ intel, productId }: { intel: IntelProduct; productId: string }) {
  const fmtVel = (v: number | null) => (v === null ? "—" : `${v.toLocaleString("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} adet/gün`);
  const days = intel.window.days;
  return (
    <section className="space-y-3">
      <SectionHeader
        title="Analiz"
        meta={`son ${days} gün`}
        action={<Link href={`/app/analiz/beden-renk?gun=${days}&urun=${productId}`} className="underline-offset-4 hover:underline">Beden & renk</Link>}
      />
      {!intel.enough_data ? (
        <p className="text-xs text-text-muted">
          Henüz yeterli veri yok: son {days} günde {fmtInt(intel.sold_win)} adet satıldı; pay ve iade oranı için en az {fmtInt(intel.min_sample)} adet gerekir. Stok ve yaş yine aşağıda.
        </p>
      ) : null}
      <StatGrid>
        <Stat label="Satış hızı" value={fmtVel(intel.velocity)} hint={`${fmtInt(intel.sold_win)} adet / ${fmtInt(intel.active_days ?? days)} aktif gün${intel.days_of_cover !== null ? ` · ${fmtInt(intel.days_of_cover)} günlük stok` : ""}`} />
        <Stat label="Sell-through" value={fmtPct(intel.sell_through_pct)} hint={`${fmtInt(intel.sold_all - intel.returned_all)} net satış / ${fmtInt(intel.supplied)} arz`} />
        <Stat label="Müsait" value={fmtInt(intel.stock.available)} hint={`${fmtInt(intel.stock.sellable)} satılabilir${intel.stock.reserved > 0 ? ` · ${fmtInt(intel.stock.reserved)} rezerve` : ""}${intel.stock.damaged + intel.stock.quarantine > 0 ? ` · ${fmtInt(intel.stock.damaged)} hasarlı / ${fmtInt(intel.stock.quarantine)} karantina` : ""}`} />
        <Stat label="Stok yaşı" value={intel.age_days === null ? "—" : `${fmtInt(intel.age_days)} gün`} hint={intel.days_since_sale === null ? (intel.first_arrival ? "hiç satılmadı" : "hiç stoklanmadı") : `son satış ${fmtInt(intel.days_since_sale)} gün önce`} />
        <Stat label="İade oranı" value={intel.return_rate_pct === null ? (intel.returned_win > 0 ? `${fmtInt(intel.returned_win)} adet` : "—") : fmtPct(intel.return_rate_pct)} hint={intel.return_rate_pct === null && intel.sold_win > 0 ? "küçük örneklem" : `${fmtInt(intel.returned_win)} / ${fmtInt(intel.sold_win)} adet`} />
        {intel.holds_active !== null ? <Stat label="Rezervasyon" value={fmtInt(intel.holds_active)} hint="aktif, süresi dolmamış" /> : null}
        {intel.variants_out > 0 ? <Stat label="Tükenen varyant" value={`${fmtInt(intel.variants_out)} / ${fmtInt(intel.variants)}`} /> : null}
        {intel.stock_value !== null ? <Stat label="Stok değeri" value={fmtMoney(intel.stock_value)} hint="mevcut maliyet havuzu" /> : null}
      </StatGrid>
      {intel.sizes.length > 0 || intel.colors.length > 0 ? (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          {intel.sizes.length > 0 ? <Distribution title="Beden dağılımı" rows={intel.sizes} /> : null}
          {intel.colors.length > 0 ? <Distribution title="Renk dağılımı" rows={intel.colors} /> : null}
        </div>
      ) : null}
    </section>
  );
}

function Distribution({ title, rows }: { title: string; rows: Array<{ value: string; sold_win: number; share_pct: number | null; available: number; out: boolean; returned_win: number; return_rate_pct?: number | null; never_stocked?: boolean }> }) {
  return (
    <div className="rounded border border-border">
      <p className="border-b border-border px-4 py-2 text-xs font-medium text-text-primary">{title}</p>
      <ul className="divide-y divide-border">
        {rows.map((r) => (
          <li key={r.value} className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 px-4 py-2 text-xs">
            <span className="w-16 font-medium text-text-primary">{r.value}</span>
            <ShareBar pct={r.share_pct} label={r.share_pct !== null ? `${fmtPct(r.share_pct)} · ${fmtInt(r.sold_win)} adet` : `${fmtInt(r.sold_win)} adet`} />
            <span className="text-text-muted" data-numeric>
              {r.never_stocked ? "hiç stoklanmadı" : r.out ? <span className="font-medium text-text-primary">tükendi</span> : `${fmtInt(r.available)} müsait`}
              {r.returned_win > 0 ? ` · ${fmtInt(r.returned_win)} iade${r.return_rate_pct !== null && r.return_rate_pct !== undefined ? ` (${fmtPct(r.return_rate_pct)})` : ""}` : ""}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
