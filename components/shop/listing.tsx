import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { getStore, listProducts } from "@/lib/shop/queries";
import { PAGE_SIZE, WINDOW_SIZE } from "@/lib/shop/model";
import { hasFilters, isParameterised, listingHref, parseListing } from "@/lib/shop/listing-url";
import { ProductGrid } from "@/components/shop/product-card";
import { ListingControls } from "@/components/shop/listing-controls";

type Search = Record<string, string | string[] | undefined>;

/**
 * Canonical is always the clean route. Any query (search, filter, sort, load-more) marks the
 * page noindex,follow — no crawlable filter combinations.
 */
export async function listingMetadata({ slug }: { slug: string }, category: string | null, searchParams: Search = {}): Promise<Metadata> {
  const store = await getStore(slug);
  if (!store) return {};
  const cat = category ? store.categories.find((c) => c.slug === category) : null;
  const title = cat ? cat.name : "Tüm Ürünler";
  return {
    title,
    alternates: { canonical: cat ? `/shop/${slug}/kategori/${cat.slug}` : `/shop/${slug}/urunler` },
    ...(isParameterised(searchParams) ? { robots: { index: false, follow: true } } : {}),
  };
}

/** Shared catalogue for "all products", a category and search results. */
export async function Listing({ slug, category, searchParams }: { slug: string; category: string | null; searchParams: Search }) {
  const store = await getStore(slug);
  if (!store) notFound();
  const state = parseListing(searchParams);
  const { steps, start, ...filters } = state;
  const limit = steps * PAGE_SIZE;
  const list = await listProducts(slug, category, filters, start, limit);
  if (!list) notFound();
  if (category && !list.category) notFound();

  const base = `/shop/${slug}`;
  const filtered = hasFilters(filters);
  const shownTo = start + list.rows.length;
  const remainingInWindow = shownTo < list.total && steps * PAGE_SIZE < WINDOW_SIZE;
  const nextWindow = shownTo < list.total && !remainingInWindow;
  const title = list.category?.name ?? (filters.q ? `“${filters.q}” için sonuçlar` : "Tüm Ürünler");

  return (
    <div className="shop-listing">
      <header className="shop-listing-head">
        <h1 className="shop-listing-title" data-search={!list.category && filters.q ? "true" : undefined}>{title}</h1>
        <p className="shop-listing-count" data-numeric>{list.total} ürün</p>
      </header>

      <ListingControls base={base} category={category} categories={store.categories} facets={list.facets} filters={filters} />

      {filtered ? (
        <div className="shop-active" aria-label="Seçili filtreler">
          {filters.sizes.map((s) => (
            <Link key={`b-${s}`} href={listingHref(base, category, { ...filters, sizes: filters.sizes.filter((x) => x !== s) })} aria-label={`Beden ${s} filtresini kaldır`}>Beden {s} <span aria-hidden>×</span></Link>
          ))}
          {filters.colors.map((c) => (
            <Link key={`r-${c}`} href={listingHref(base, category, { ...filters, colors: filters.colors.filter((x) => x !== c) })} aria-label={`${c} filtresini kaldır`}>{c} <span aria-hidden>×</span></Link>
          ))}
          {filters.inStock ? <Link href={listingHref(base, category, { ...filters, inStock: false })} aria-label="Yalnız stokta olanlar filtresini kaldır">Stokta <span aria-hidden>×</span></Link> : null}
          <Link href={listingHref(base, category, { q: filters.q, sort: filters.sort })} className="shop-active-clear">Temizle</Link>
        </div>
      ) : null}

      {list.rows.length === 0 ? (
        <section className="shop-empty" data-testid="shop-empty">
          {filtered ? (
            <>
              <h2 className="shop-empty-title">Bu seçime uygun ürün yok.</h2>
              <p className="shop-empty-text">Birkaç filtreyi kaldırmayı deneyin.</p>
              <Link href={listingHref(base, category, { q: filters.q, sort: filters.sort })} className="shop-link">Filtreleri temizle</Link>
            </>
          ) : filters.q ? (
            <>
              <h2 className="shop-empty-title">Aradığın ürünü bulamadık.</h2>
              <p className="shop-empty-text">Farklı bir kelimeyle aramayı deneyin.</p>
              <Link href={`${base}/urunler`} className="shop-link">Tüm ürünleri keşfet</Link>
            </>
          ) : (
            <>
              <h2 className="shop-empty-title">Burada şu an ürün yok.</h2>
              <Link href={`${base}/urunler`} className="shop-link">Tüm ürünleri keşfet</Link>
            </>
          )}
        </section>
      ) : (
        <ProductGrid slug={slug} cards={list.rows} currency={store.currency} eager={start === 0 ? 4 : 0} variant="catalog" startIndex={start} />
      )}

      {list.rows.length > 0 ? (
        <nav className="shop-more" aria-label="Daha fazla ürün">
          <p className="shop-more-count" data-numeric>{list.total} üründen {start + 1}–{shownTo} gösteriliyor</p>
          {remainingInWindow ? (
            <Link href={listingHref(base, category, { ...filters, start, steps: steps + 1 }, `urun-${shownTo + 1}`)} className="shop-btn shop-btn-ghost shop-more-btn" data-testid="shop-load-more">
              Daha fazla göster
            </Link>
          ) : null}
          {start > 0 || nextWindow ? (
            <div className="shop-more-window">
              {start > 0 ? <Link href={listingHref(base, category, { ...filters, start: Math.max(0, start - WINDOW_SIZE), steps: 4 })} className="shop-link">← Önceki ürünler</Link> : <span />}
              {nextWindow ? <Link href={listingHref(base, category, { ...filters, start: start + WINDOW_SIZE })} className="shop-link">Sonraki ürünler →</Link> : null}
            </div>
          ) : null}
        </nav>
      ) : null}
    </div>
  );
}
