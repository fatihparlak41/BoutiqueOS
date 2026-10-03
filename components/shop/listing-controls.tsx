"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { Check, ChevronDown, SlidersHorizontal, X } from "lucide-react";
import { SORT_OPTIONS, type ListingFilters, type ShopCategory, type ShopFacets } from "@/lib/shop/model";
import { listingHref } from "@/lib/shop/listing-url";
import { useOverlay } from "@/components/shop/overlay";

type Props = {
  base: string;
  category: string | null;
  categories: ShopCategory[];
  facets: ShopFacets;
  filters: ListingFilters;
};

/**
 * The quiet bar above the catalogue: "Filtrele" opens a sheet (bottom / full height on a
 * phone, a right-hand panel on desktop — never a permanent sidebar), "Sırala" a short list.
 * Everything ends in a URL; the server filters (rpc_shop_products). Back/forward just work.
 */
export function ListingControls({ base, category, categories, facets, filters }: Props) {
  const [open, setOpen] = useState(false);
  const close = useCallback(() => setOpen(false), []);
  const active = (category ? 1 : 0) + filters.colors.length + filters.sizes.length + (filters.inStock ? 1 : 0);
  const canFilter = categories.length > 0 || facets.colors.length > 0 || facets.sizes.length > 0;

  return (
    <>
      <div className="shop-toolbar" data-testid="shop-toolbar">
        {canFilter ? (
          <button type="button" className="shop-toolbar-btn" aria-expanded={open} onClick={() => setOpen(true)} data-testid="shop-filter-button">
            <SlidersHorizontal aria-hidden strokeWidth={1.4} />
            Filtrele{active > 0 ? <span className="shop-toolbar-count" data-numeric>({active})</span> : null}
          </button>
        ) : <span />}
        <SortMenu base={base} category={category} filters={filters} />
      </div>
      <FilterSheet open={open} onClose={close} base={base} category={category} categories={categories} facets={facets} filters={filters} />
    </>
  );
}

function SortMenu({ base, category, filters }: { base: string; category: string | null; filters: ListingFilters }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const current = SORT_OPTIONS.find((o) => o.value === filters.sort) ?? SORT_OPTIONS[0];
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); document.removeEventListener("keydown", onKey); };
  }, [open]);
  return (
    <div className="shop-sort" ref={ref}>
      <button type="button" className="shop-toolbar-btn" aria-expanded={open} aria-controls="shop-sort-list" aria-label={`Sırala: ${current.label}`} onClick={() => setOpen((v) => !v)} data-testid="shop-sort-button">
        <span>Sırala</span>
        <span className="shop-sort-value">: {current.label}</span>
        <ChevronDown aria-hidden strokeWidth={1.4} />
      </button>
      {open ? (
        <ul id="shop-sort-list" className="shop-sort-list" aria-label="Sıralama">
          {SORT_OPTIONS.map((o) => (
            <li key={o.value}>
              <Link href={listingHref(base, category, { ...filters, sort: o.value })} aria-current={o.value === filters.sort ? "true" : undefined} onClick={() => setOpen(false)} scroll={false}>
                {o.label}
                {o.value === filters.sort ? <Check aria-hidden strokeWidth={1.4} /> : null}
              </Link>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function FilterSheet({ open, onClose, base, category, categories, facets, filters }: Props & { open: boolean; onClose: () => void }) {
  const router = useRouter();
  const panel = useRef<HTMLDivElement>(null);
  const closeBtn = useRef<HTMLButtonElement>(null);
  const [cat, setCat] = useState<string | null>(category);
  const [colors, setColors] = useState<string[]>(filters.colors);
  const [sizes, setSizes] = useState<string[]>(filters.sizes);
  const [inStock, setInStock] = useState(filters.inStock);
  useOverlay(open, onClose, panel, closeBtn);

  // every time the sheet opens it starts from what the URL says
  useEffect(() => {
    if (!open) return;
    setCat(category); setColors(filters.colors); setSizes(filters.sizes); setInStock(filters.inStock);
  }, [open, category, filters]);

  if (!open) return null;
  const toggle = (list: string[], v: string) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);
  // the facets shown are the current scope's; after a category switch a chosen value may simply match nothing there
  const apply = (next: { cat: string | null; colors: string[]; sizes: string[]; inStock: boolean }) => {
    onClose();
    router.push(listingHref(base, next.cat, { q: filters.q, sort: filters.sort, colors: next.colors, sizes: next.sizes, inStock: next.inStock }));
  };

  return (
    <div className="shop-layer" data-testid="shop-filter-sheet">
      <button type="button" className="shop-scrim" aria-label="Filtreleri kapat" tabIndex={-1} onClick={onClose} />
      <div ref={panel} className="shop-filter" role="dialog" aria-modal="true" aria-labelledby="shop-filter-title" tabIndex={-1}>
        <div className="shop-layer-head">
          <h2 id="shop-filter-title" className="shop-filter-title">Filtrele</h2>
          <button ref={closeBtn} type="button" className="shop-icon" aria-label="Kapat" onClick={onClose}>
            <X aria-hidden strokeWidth={1.4} />
          </button>
        </div>

        <div className="shop-filter-body">
          {categories.length > 0 ? (
            <fieldset className="shop-filter-group">
              <legend className="shop-kicker">Kategori</legend>
              <div className="shop-filter-list">
                {[{ slug: null as string | null, name: "Tümü" }, ...categories.map((c) => ({ slug: c.slug as string | null, name: c.name }))].map((c) => (
                  <button key={c.slug ?? "_all"} type="button" className="shop-filter-option" aria-pressed={cat === c.slug} onClick={() => setCat(c.slug)}>
                    <span>{c.name}</span>
                    {cat === c.slug ? <Check aria-hidden strokeWidth={1.4} /> : null}
                  </button>
                ))}
              </div>
            </fieldset>
          ) : null}

          {facets.sizes.length > 0 ? (
            <fieldset className="shop-filter-group">
              <legend className="shop-kicker">Beden</legend>
              <div className="shop-filter-sizes">
                {facets.sizes.map((s) => (
                  <button key={s.value} type="button" className="shop-filter-size" aria-pressed={sizes.includes(s.value)} onClick={() => setSizes(toggle(sizes, s.value))}>
                    {s.value}
                  </button>
                ))}
              </div>
            </fieldset>
          ) : null}

          {facets.colors.length > 0 ? (
            <fieldset className="shop-filter-group">
              <legend className="shop-kicker">Renk</legend>
              <div className="shop-filter-colors">
                {facets.colors.map((c) => (
                  <button key={c.value} type="button" className="shop-filter-color" aria-pressed={colors.includes(c.value)} onClick={() => setColors(toggle(colors, c.value))}>
                    <span className="shop-filter-dot" style={{ background: c.hex ?? "#e5e1da" }} aria-hidden />
                    <span>{c.value}</span>
                  </button>
                ))}
              </div>
            </fieldset>
          ) : null}

          <fieldset className="shop-filter-group">
            <legend className="shop-kicker">Stok</legend>
            <button type="button" role="switch" aria-checked={inStock} className="shop-filter-switch" onClick={() => setInStock((v) => !v)}>
              <span>Yalnız stokta olanlar</span>
              <span className="shop-switch" aria-hidden />
            </button>
          </fieldset>
        </div>

        <div className="shop-filter-actions">
          <button type="button" className="shop-link" onClick={() => apply({ cat: null, colors: [], sizes: [], inStock: false })} data-testid="shop-filter-clear">
            Temizle
          </button>
          <button type="button" className="shop-btn shop-filter-apply" onClick={() => apply({ cat, colors, sizes, inStock })} data-testid="shop-filter-apply">
            Sonuçları göster
          </button>
        </div>
      </div>
    </div>
  );
}
