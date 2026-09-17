/** Number formatting for the report pages. Client-safe, TRY base currency (pilot). */

const money = new Intl.NumberFormat("tr-TR", { style: "currency", currency: "TRY", minimumFractionDigits: 2, maximumFractionDigits: 2 });
const moneyShort = new Intl.NumberFormat("tr-TR", { style: "currency", currency: "TRY", minimumFractionDigits: 0, maximumFractionDigits: 0 });
const int = new Intl.NumberFormat("tr-TR");
const pct = new Intl.NumberFormat("tr-TR", { minimumFractionDigits: 1, maximumFractionDigits: 1 });

export function fmtMoney(v: number | null | undefined): string {
  return v === null || v === undefined ? "—" : money.format(v);
}

/** Whole lira for KPI tiles; the table keeps the cents. */
export function fmtMoneyShort(v: number | null | undefined): string {
  return v === null || v === undefined ? "—" : moneyShort.format(v);
}

export function fmtInt(v: number | null | undefined): string {
  return v === null || v === undefined ? "—" : int.format(v);
}

export function fmtPct(v: number | null | undefined): string {
  return v === null || v === undefined ? "—" : `% ${pct.format(v)}`;
}

/** Change against the previous period as "+12,5 %" / "−8,0 %"; null when there is no base. */
export function deltaPct(current: number, previous: number | null | undefined): number | null {
  if (previous === null || previous === undefined || previous === 0) return null;
  return ((current - previous) / Math.abs(previous)) * 100;
}

export function fmtDelta(v: number | null): string {
  if (v === null) return "";
  const sign = v > 0 ? "+" : v < 0 ? "−" : "";
  return `${sign}${pct.format(Math.abs(v))} %`;
}
