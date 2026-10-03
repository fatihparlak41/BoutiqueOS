import { SORT_OPTIONS, type ListingFilters, type SortKey } from "@/lib/shop/model";

/**
 * Listing state ⇄ URL. Shared by the server page (parsing) and the filter sheet (building).
 * Values are the public option-value names the customer sees (no UUIDs): repeated params
 * for multi-select (?renk=Siyah&renk=Bej), ?stok=1, ?sirala=, ?q=; ?sayfa= is the number
 * of 24-card steps shown (load more), ?baslangic= the start of the current 96-card window.
 * The category is the path (/kategori/{slug}), so the clean route stays the canonical one.
 */

type Raw = Record<string, string | string[] | undefined>;

const list = (v: string | string[] | undefined): string[] =>
  (Array.isArray(v) ? v : v ? [v] : []).map((x) => x.trim().slice(0, 60)).filter((x) => x.length > 0).slice(0, 20);
const one = (v: string | string[] | undefined): string | undefined => (Array.isArray(v) ? v[0] : v);

export function readSort(v: string | undefined): SortKey {
  return SORT_OPTIONS.some((o) => o.value === v) ? (v as SortKey) : "newest";
}

export function parseListing(raw: Raw): ListingFilters & { steps: number; start: number } {
  const q = (one(raw.q) ?? "").trim().slice(0, 60) || null;
  const steps = Math.min(4, Math.max(1, Number.parseInt(one(raw.sayfa) ?? "1", 10) || 1));
  const start = Math.max(0, Number.parseInt(one(raw.baslangic) ?? "0", 10) || 0);
  return {
    q,
    colors: [...new Set(list(raw.renk))],
    sizes: [...new Set(list(raw.beden))],
    inStock: one(raw.stok) === "1",
    sort: readSort(one(raw.sirala)),
    steps,
    start: start - (start % 96),
  };
}

export function hasFilters(f: Pick<ListingFilters, "colors" | "sizes" | "inStock">): boolean {
  return f.colors.length > 0 || f.sizes.length > 0 || f.inStock;
}

/** Any parameter at all makes the page a variant of the clean route (future noindex,follow). */
export function isParameterised(raw: Raw): boolean {
  return ["q", "renk", "beden", "stok", "sirala", "sayfa", "baslangic"].some((k) => raw[k] !== undefined);
}

export function listingHref(
  base: string,
  category: string | null,
  f: Partial<ListingFilters> & { steps?: number; start?: number },
  hash?: string,
): string {
  const path = category ? `${base}/kategori/${category}` : `${base}/urunler`;
  const p = new URLSearchParams();
  if (f.q) p.set("q", f.q);
  for (const c of f.colors ?? []) p.append("renk", c);
  for (const s of f.sizes ?? []) p.append("beden", s);
  if (f.inStock) p.set("stok", "1");
  if (f.sort && f.sort !== "newest") p.set("sirala", f.sort);
  if (f.start && f.start > 0) p.set("baslangic", String(f.start));
  if (f.steps && f.steps > 1) p.set("sayfa", String(f.steps));
  const qs = p.toString();
  return `${path}${qs ? `?${qs}` : ""}${hash ? `#${hash}` : ""}`;
}
