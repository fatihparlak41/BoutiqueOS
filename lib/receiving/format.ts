import type { Currency } from "@/lib/receiving/model";

/**
 * Receiving shows amounts in the invoice currency as well as the TRY base, so unlike the
 * catalogue's TRY-only helper this one takes the currency explicitly.
 * Client-safe: the receipt forms need it too.
 */

const formatters = new Map<string, Intl.NumberFormat>();

function formatter(currency: Currency): Intl.NumberFormat {
  let f = formatters.get(currency);
  if (!f) {
    f = new Intl.NumberFormat("tr-TR", {
      style: "currency",
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    formatters.set(currency, f);
  }
  return f;
}

export function formatMoney(value: number, currency: Currency): string {
  return formatter(currency).format(value);
}

/** Rates are fx6 — NUMERIC(14,6) — so trailing zeros are trimmed for display. */
export function formatRate(value: number): string {
  return new Intl.NumberFormat("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 6 }).format(value);
}

export function formatQuantity(value: number): string {
  return new Intl.NumberFormat("tr-TR").format(value);
}

export function formatDate(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat("tr-TR").format(date);
}

export function formatDateTime(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? value
    : new Intl.DateTimeFormat("tr-TR", { dateStyle: "short", timeStyle: "short" }).format(date);
}

/** Signed quantity for the ledger view: +5 / −3, never a bare minus glyph. */
export function formatSigned(value: number): string {
  const abs = formatQuantity(Math.abs(value));
  return value < 0 ? `−${abs}` : `+${abs}`;
}

/** Accepts "1.234,56" and "1234.56"; mirrors the parser in the server actions. */
export function parseDecimalInput(input: string): number | null {
  const trimmed = input.trim();
  if (!trimmed) return null;
  const normalised = trimmed.includes(",") ? trimmed.replace(/\./g, "").replace(",", ".") : trimmed;
  if (!/^\d+(\.\d{1,6})?$/.test(normalised)) return null;
  const value = Number(normalised);
  return Number.isFinite(value) && value >= 0 ? value : null;
}

export function moneyInputValue(value: number): string {
  return value.toFixed(2).replace(".", ",");
}
