import Link from "next/link";
import type { SimilarProduct } from "@/lib/catalog/model";
import { StatusPill } from "@/components/catalog/status-pill";

/**
 * Duplicate warning, not a block. Shown on the product page when another product of
 * this business shares the style code or starts with the same name; the person decides.
 */
export function SimilarProducts({ items }: { items: SimilarProduct[] }) {
  if (items.length === 0) return null;
  return (
    <div className="rounded border border-warning/40 bg-warning-muted/50 px-4 py-3">
      <p className="text-sm font-medium text-text-primary">Benzer ürünler var</p>
      <p className="mt-0.5 text-xs text-text-muted">
        Aynı model kodu ya da benzer ad. Bu bir uyarıdır; ayrı bir model olduğundan eminseniz devam edin.
      </p>
      <ul className="mt-2 space-y-1 text-xs">
        {items.map((p) => (
          <li key={p.id} className="flex flex-wrap items-center gap-2">
            <Link href={`/app/urunler/${p.id}`} className="font-medium underline-offset-4 hover:underline">
              {p.name}
            </Link>
            {p.style_code ? <span className="text-text-muted" data-numeric>{p.style_code}</span> : null}
            <StatusPill status={p.status} />
            <span className="text-2xs text-text-muted">{p.reason === "style_code" ? "aynı model kodu" : "benzer ad"}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
