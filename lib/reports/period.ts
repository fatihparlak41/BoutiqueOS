import { DEFAULT_TIMEZONE, PERIOD_PRESETS, type Period, type PeriodPreset } from "@/lib/reports/model";

/**
 * Report windows are calendar days in the tenant timezone. This module only decides which
 * local days a preset means; PostgreSQL turns them into instants (fn_report_window) with
 * the same zone, so "today" here and "today" in SQL are the same day.
 *
 * Dates are plain YYYY-MM-DD strings and the arithmetic runs on UTC-midnight Date values,
 * which keeps it independent of the server's own zone.
 */

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** Today's calendar date in `timezone`. */
export function localToday(timezone: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date());
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

function toUtc(iso: string): Date {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d));
}

function fromUtc(d: Date): string {
  return d.toISOString().slice(0, 10);
}

export function addDays(iso: string, n: number): string {
  const d = toUtc(iso);
  d.setUTCDate(d.getUTCDate() + n);
  return fromUtc(d);
}

export function startOfMonth(iso: string): string {
  return `${iso.slice(0, 7)}-01`;
}

export function endOfMonth(iso: string): string {
  const d = toUtc(startOfMonth(iso));
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(0);
  return fromUtc(d);
}

/** Inclusive number of days between two ISO dates. */
export function dayCount(from: string, to: string): number {
  return Math.round((toUtc(to).getTime() - toUtc(from).getTime()) / 86_400_000) + 1;
}

export function isPreset(v: string | undefined): v is PeriodPreset {
  return PERIOD_PRESETS.some((p) => p.key === v);
}

/** Bounded like the RPC: a window is at most 366 days. */
export const MAX_RANGE_DAYS = 366;

/**
 * Turns the URL state (`d`, `from`, `to`) into a concrete window plus its comparable
 * predecessor. "Bu ay" compares the elapsed days of this month with the same number of
 * days at the start of last month; a custom window compares with the window of the same
 * length that ends the day before it.
 */
export function resolvePeriod(
  params: { d?: string; from?: string; to?: string },
  timezone: string | null,
): Period {
  const tz = timezone ?? DEFAULT_TIMEZONE;
  const today = localToday(tz);
  const preset: PeriodPreset = isPreset(params.d) ? params.d : "today";
  const base = { preset, timezone: tz, timezoneSet: timezone !== null };

  switch (preset) {
    case "yesterday": {
      const y = addDays(today, -1);
      return { ...base, from: y, to: y, prevFrom: addDays(y, -1), prevTo: addDays(y, -1) };
    }
    case "7d": {
      const from = addDays(today, -6);
      return { ...base, from, to: today, prevFrom: addDays(from, -7), prevTo: addDays(from, -1) };
    }
    case "month": {
      const from = startOfMonth(today);
      const elapsed = dayCount(from, today);
      const prevFrom = startOfMonth(addDays(from, -1));
      const prevTo = addDays(prevFrom, Math.min(elapsed, dayCount(prevFrom, endOfMonth(prevFrom))) - 1);
      return { ...base, from, to: today, prevFrom, prevTo };
    }
    case "last_month": {
      const from = startOfMonth(addDays(startOfMonth(today), -1));
      const to = endOfMonth(from);
      const prevFrom = startOfMonth(addDays(from, -1));
      return { ...base, from, to, prevFrom, prevTo: endOfMonth(prevFrom) };
    }
    case "custom": {
      const from = params.from && ISO_DATE.test(params.from) ? params.from : addDays(today, -6);
      let to = params.to && ISO_DATE.test(params.to) ? params.to : today;
      if (toUtc(to) < toUtc(from)) to = from;
      if (dayCount(from, to) > MAX_RANGE_DAYS) to = addDays(from, MAX_RANGE_DAYS - 1);
      const len = dayCount(from, to);
      return { ...base, from, to, prevFrom: addDays(from, -len), prevTo: addDays(from, -1) };
    }
    default:
      return { ...base, preset: "today", from: today, to: today, prevFrom: addDays(today, -1), prevTo: addDays(today, -1) };
  }
}

const dayFormatter = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
const shortDay = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "short", timeZone: "UTC" });

/** "17 Eylül 2026" or "11 – 17 Eylül 2026". */
export function formatPeriod(from: string, to: string): string {
  if (from === to) return dayFormatter.format(toUtc(from));
  return `${dayFormatter.format(toUtc(from))} – ${dayFormatter.format(toUtc(to))}`;
}

export function formatDayShort(iso: string): string {
  return shortDay.format(toUtc(iso));
}

/** Query string for a period so every report page shares one URL vocabulary. */
export function periodQuery(period: Period, extra: Record<string, string | undefined> = {}): string {
  const q = new URLSearchParams();
  q.set("d", period.preset);
  if (period.preset === "custom") {
    q.set("from", period.from);
    q.set("to", period.to);
  }
  for (const [k, v] of Object.entries(extra)) if (v) q.set(k, v);
  const s = q.toString();
  return s ? `?${s}` : "";
}
