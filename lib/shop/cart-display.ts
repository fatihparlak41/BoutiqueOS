import type { AvailabilityMap, CartLine } from "@/lib/shop/model";

/** "Siyah / M" (stored) → "Siyah · M" (shown). */
export const lineLabels = (labels: string) => labels.split(" / ").filter(Boolean).join(" · ");

/** A line that cannot be ordered as it stands, in customer words (no stock vocabulary). */
export function lineProblem(l: CartLine, f: AvailabilityMap[string] | undefined, exact: boolean): string | null {
  if (!f) return null;
  if (f.state === "sold_out") return "Bu ürün artık müsait değil.";
  if (f.available !== null && l.quantity > f.available) return exact ? `Bu üründen yalnız ${f.available} adet kaldı.` : "Bu adette müsait değil; adedi azaltın.";
  return null;
}
