import * as React from "react";
import type { DailyPoint } from "@/lib/reports/model";
import { addDays, dayCount, formatDayShort } from "@/lib/reports/period";
import { fmtMoney, fmtMoneyShort } from "@/components/reports/format";

/**
 * One trend: net sales per local day as plain SVG bars. Days without activity are drawn
 * as zero so the shape is the calendar, not the list of busy days. Below three days of
 * data there is nothing to read from a chart, so the component renders a sentence
 * instead of a chart with one bar.
 */
export function TrendChart({ daily, from, to, title = "Günlük net satış" }: { daily: DailyPoint[]; from: string; to: string; title?: string }) {
  const days = Math.min(dayCount(from, to), 366);
  const byDate = new Map(daily.map((d) => [d.date, d]));
  const series: Array<{ date: string; value: number; tx: number }> = [];
  for (let i = 0; i < days; i++) {
    const date = addDays(from, i);
    const p = byDate.get(date);
    series.push({ date, value: p?.net_sales ?? 0, tx: p?.transactions ?? 0 });
  }
  const active = series.filter((s) => s.tx > 0).length;
  if (days < 3 || active < 2) {
    return (
      <p className="text-xs text-text-muted">
        {active === 0 ? "Bu dönemde satış yok." : `Bu dönemde ${active} günde satış var — eğilim için daha uzun bir dönem seçin.`}
      </p>
    );
  }
  const max = Math.max(...series.map((s) => s.value), 1);
  const w = 100;
  const h = 40;
  const gap = days > 60 ? 0 : 0.25;
  const bw = w / days;
  const tickEvery = days <= 14 ? 1 : days <= 31 ? 5 : days <= 92 ? 14 : 30;
  return (
    <figure className="space-y-2">
      <figcaption className="flex items-baseline justify-between text-xs text-text-muted">
        <span>{title}</span>
        <span data-numeric>en yüksek gün {fmtMoneyShort(max)}</span>
      </figcaption>
      <svg viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" className="h-28 w-full text-text-primary" role="img" aria-label={`${title}, ${days} gün`}>
        <line x1="0" y1={h - 0.25} x2={w} y2={h - 0.25} stroke="currentColor" strokeOpacity="0.2" strokeWidth="0.25" vectorEffect="non-scaling-stroke" />
        {series.map((s, i) => {
          const bh = s.value > 0 ? Math.max((s.value / max) * (h - 2), 0.4) : 0;
          return (
            <rect key={s.date} x={i * bw + gap / 2} y={h - 0.5 - bh} width={Math.max(bw - gap, 0.2)} height={bh} fill="currentColor" fillOpacity={s.value > 0 ? 0.85 : 0}>
              <title>{`${formatDayShort(s.date)}: ${fmtMoney(s.value)} · ${s.tx} işlem`}</title>
            </rect>
          );
        })}
      </svg>
      <ol className="flex justify-between text-2xs text-text-muted" data-numeric aria-hidden>
        {series.filter((_, i) => i % tickEvery === 0 || i === days - 1).map((s) => (
          <li key={s.date}>{formatDayShort(s.date)}</li>
        ))}
      </ol>
    </figure>
  );
}
