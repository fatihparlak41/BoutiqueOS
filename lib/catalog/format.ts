/**
 * Formatting and input parsing shared by server and client components.
 * No "server-only" here on purpose — the variant forms need parseMoney too.
 */

/** Business base currency for the pilot. Read from businesses.base_currency when V2 adds multi-currency UI. */
const DISPLAY_CURRENCY = "TRY";

const priceFormatter = new Intl.NumberFormat("tr-TR", {
  style: "currency",
  currency: DISPLAY_CURRENCY,
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

export function formatPrice(value: number): string {
  return priceFormatter.format(value);
}

/** "120,00 ₺ – 145,00 ₺" for a span, a single price when both ends match. */
export function formatPriceRange(min: number | null, max: number | null): string {
  if (min === null || max === null) return "—";
  return min === max ? formatPrice(min) : `${formatPrice(min)} – ${formatPrice(max)}`;
}

/**
 * Accepts what a Turkish keyboard actually produces: "1.234,56", "1234,56", "1234.56".
 * Returns null when the input is not a usable amount, so callers can show a field error
 * instead of writing a silent 0.
 */
export function parseMoney(input: string): number | null {
  const trimmed = input.trim();
  if (!trimmed) return null;

  const normalised = trimmed.includes(",")
    ? trimmed.replace(/\./g, "").replace(",", ".")
    : trimmed;

  if (!/^\d+(\.\d{1,2})?$/.test(normalised)) return null;

  const value = Number(normalised);
  if (!Number.isFinite(value) || value < 0) return null;
  // money2 is NUMERIC(12,2): ten integer digits at most.
  if (value > 9_999_999_999.99) return null;
  return value;
}

/** Suggests "TLC-CROP-SIYAH-M" from a prefix and the chosen option values. */
export function suggestSku(skuPrefix: string, values: string[]): string {
  const slug = (part: string) =>
    part
      .toLocaleUpperCase("tr-TR")
      .replace(/İ/g, "I")
      .replace(/Ş/g, "S")
      .replace(/Ğ/g, "G")
      .replace(/Ü/g, "U")
      .replace(/Ö/g, "O")
      .replace(/Ç/g, "C")
      .replace(/[^A-Z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");

  return [skuPrefix, ...values].map(slug).filter(Boolean).join("-").slice(0, 64);
}
