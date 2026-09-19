import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { getStore, listProducts } from "@/lib/shop/queries";
import { PAGE_SIZE, SORT_OPTIONS, type SortKey } from "@/lib/shop/model";
import { ProductGrid } from "@/components/shop/product-card";

type Search = { sirala?: string; sayfa?: string; q?: string };

function readSort(v: string | undefined): SortKey {
  return SORT_OPTIONS.some((o) => o.value === v) ? (v as SortKey) : "newest";
}

export async function listingMetadata({ slug }: { slug: string }, category: string | null): Promise<Metadata> {
  const store = await getStore(slug);
  if (!store) return {};
  const cat = category ? store.categories.find((c) => c.slug === category) : null;
  const title = cat ? cat.name : "Tüm ürünler";
  return { title, alternates: { canonical: cat ? `/shop/${slug}/kategori/${cat.slug}` : `/shop/${slug}/urunler` } };
}

/** Shared listing for "all products" and a category: filter strip, sort, grid, pager. */
export async function Listing({ slug, category, searchParams }: { slug: string; category: string | null; searchParams: Search }) {
  const store = await getStore(slug);
  if (!store) notFound();
  const sort = readSort(searchParams.sirala);
  const q = (searchParams.q ?? "").trim().slice(0, 60) || null;
  const page = Math.max(1, Number.parseInt(searchParams.sayfa ?? "1", 10) || 1);
  const list = await listProducts(slug, category, q, sort, (page - 1) * PAGE_SIZE, PAGE_SIZE);
  if (!list) notFound();
  if (category && !list.category) notFound();
  const base = `/shop/${slug}`;
  const here = category ? `${base}/kategori/${category}` : `${base}/urunler`;
  const href = (p: number) => `${here}?${new URLSearchParams({ ...(sort !== "newest" ? { sirala: sort } : {}), ...(q ? { q } : {}), ...(p > 1 ? { sayfa: String(p) } : {}) }).toString()}`;
  const pages = Math.max(1, Math.ceil(list.total / PAGE_SIZE));

  return (
    <div className="shop-section" style={{ paddingTop: 24 }}>
      <p className="shop-eyebrow">{store.store_name}</p>
      <h1 className="shop-h2" style={{ marginTop: 8 }}>{list.category?.name ?? (q ? `"${q}" için sonuçlar` : "Tüm ürünler")}</h1>
      <p className="shop-muted" style={{ marginTop: 6, fontSize: 13 }} data-numeric>{list.total} ürün</p>

      <nav className="shop-cats" aria-label="Kategoriler" style={{ marginTop: 20 }}>
        <Link href={`${base}/urunler`} className="shop-chip" aria-current={!category ? "page" : undefined}>Tümü</Link>
        {store.categories.map((c) => (
          <Link key={c.slug} href={`${base}/kategori/${c.slug}`} className="shop-chip" aria-current={category === c.slug ? "page" : undefined}>{c.name}</Link>
        ))}
      </nav>

      <form method="get" action={here} style={{ display: "flex", gap: 8, marginTop: 16, alignItems: "center" }}>
        <input className="shop-input" type="search" name="q" defaultValue={q ?? ""} placeholder="Ara" aria-label="Ürün ara" style={{ maxWidth: 260 }} />
        <select className="shop-select" name="sirala" defaultValue={sort} aria-label="Sırala">
          {SORT_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
        <button type="submit" className="shop-btn shop-btn-ghost" style={{ width: "auto", height: 40, padding: "0 14px" }}>Uygula</button>
      </form>

      <div style={{ marginTop: 28 }}>
        {list.rows.length === 0 ? (
          <p className="shop-muted">Bu seçimde ürün yok.</p>
        ) : (
          <ProductGrid slug={slug} cards={list.rows} currency={store.currency} eager={page === 1 ? 4 : 0} />
        )}
      </div>

      {pages > 1 ? (
        <nav className="shop-pager" aria-label="Sayfalar">
          {page > 1 ? <Link href={href(page - 1)}>← Önceki</Link> : <span>← Önceki</span>}
          <span data-numeric>{page} / {pages}</span>
          {page < pages ? <Link href={href(page + 1)}>Sonraki →</Link> : <span>Sonraki →</span>}
        </nav>
      ) : null}
    </div>
  );
}
