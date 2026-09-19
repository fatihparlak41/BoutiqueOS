import Link from "next/link";
import Image from "next/image";
import { notFound } from "next/navigation";
import { getHome, getStore } from "@/lib/shop/queries";
import { publicImageUrl } from "@/lib/shop/model";
import { ProductGrid } from "@/components/shop/product-card";

/**
 * Storefront home. Editorial opening (store name, tagline, the first featured image as
 * the hero), then featured products, new arrivals and the category strip. A store with
 * little data degrades to the opening and whatever exists — no placeholder banners.
 */
export default async function ShopHome({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const [store, home] = await Promise.all([getStore(slug), getHome(slug)]);
  if (!store || !home) notFound();
  const hero = home.featured.find((c) => c.image)?.image ?? home.new_arrivals.find((c) => c.image)?.image ?? null;
  const heroUrl = publicImageUrl(hero?.path);
  const base = `/shop/${store.slug}`;

  return (
    <>
      <section className="shop-hero">
        <p className="shop-eyebrow">{store.tagline ?? "Yeni sezon"}</p>
        <h1 className="shop-h1" style={{ marginTop: 12 }}>{store.store_name}</h1>
        {store.about ? <p className="shop-lead" style={{ marginTop: 16 }}>{store.about}</p> : null}
        {store.published_count > 0 ? (
          <p style={{ marginTop: 24 }}>
            <Link href={`${base}/urunler`} className="shop-btn shop-btn-ghost" style={{ width: "auto" }}>Koleksiyonu keşfet</Link>
          </p>
        ) : (
          <p className="shop-muted" style={{ marginTop: 24 }}>Koleksiyon yakında burada.</p>
        )}
        {heroUrl ? (
          <div className="shop-hero-media">
            <Image src={heroUrl} alt={hero?.alt ?? store.store_name} width={hero?.width ?? 1600} height={hero?.height ?? 900} priority unoptimized />
          </div>
        ) : null}
      </section>

      {store.categories.length > 1 ? (
        <section className="shop-section" style={{ paddingTop: 0 }}>
          <nav className="shop-cats" aria-label="Kategoriler">
            {store.categories.map((c) => (
              <Link key={c.slug} href={`${base}/kategori/${c.slug}`} className="shop-chip">{c.name}</Link>
            ))}
          </nav>
        </section>
      ) : null}

      {home.featured.length > 0 ? (
        <section className="shop-section" style={{ paddingTop: 0 }}>
          <div className="shop-section-head">
            <h2 className="shop-h2">Öne çıkanlar</h2>
            <Link href={`${base}/urunler`}>Tümü</Link>
          </div>
          <ProductGrid slug={store.slug} cards={home.featured} currency={store.currency} eager={2} />
        </section>
      ) : null}

      {home.new_arrivals.length > 0 ? (
        <section className="shop-section" style={{ paddingTop: home.featured.length > 0 ? undefined : 0 }}>
          <div className="shop-section-head">
            <h2 className="shop-h2">Yeni gelenler</h2>
            <Link href={`${base}/urunler`}>Tümü</Link>
          </div>
          <ProductGrid slug={store.slug} cards={home.new_arrivals} currency={store.currency} eager={home.featured.length > 0 ? 0 : 2} />
        </section>
      ) : null}
    </>
  );
}
