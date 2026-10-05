import Link from "next/link";
import Image from "next/image";
import { notFound } from "next/navigation";
import { getHome, getStore } from "@/lib/shop/queries";
import { formatPriceRange, publicImageUrl, type ProductCard, type ShopHome, type Store } from "@/lib/shop/model";
import { ProductGrid } from "@/components/shop/product-card";

const SECTION_CARDS = 4;
/**
 * The hero's rendered width, mirrored from shop.css: phone full width; tablet a centred
 * portrait ≤ 600 px; desktop a 3:4 box whose height is min(76vh, 780px) → ≤ 585 px wide,
 * narrower than the 5fr column below ~1330 px. The browser multiplies by DPR itself.
 */
const HERO_SIZES = "(min-width: 1330px) 585px, (min-width: 900px) 44vw, (min-width: 600px) 600px, 100vw";

/**
 * Storefront home, editorial order: hero → Yeni Gelenler → category blocks → Öne Çıkanlar →
 * about → Instagram. Every section renders only from real, published data — no placeholder
 * banners, no invented campaign copy. Two reads: the store (shared with the layout, cached)
 * and one bounded home response. Only the hero (or the first fallback image) is a priority
 * image; everything below the fold loads lazily through the image optimiser.
 */
export default async function ShopHome({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const [store, home] = await Promise.all([getStore(slug), getHome(slug)]);
  if (!store || !home) notFound();
  const base = `/shop/${store.slug}`;
  const arrivals = home.new_arrivals.slice(0, SECTION_CARDS);
  const featured = home.featured.slice(0, SECTION_CARDS);
  const blocks = home.categories ?? [];

  return (
    <div className="shop-home">
      <Hero store={store} home={home} base={base} />

      {arrivals.length > 0 ? (
        <section className="shop-section" aria-labelledby="h-yeni" data-testid="shop-home-new">
          <div className="shop-section-head">
            <h2 id="h-yeni" className="shop-h2">Yeni Gelenler</h2>
            <Link href={`${base}/urunler?sirala=newest`}>Tümünü gör</Link>
          </div>
          <ProductGrid slug={store.slug} cards={arrivals} currency={store.currency} />
        </section>
      ) : null}

      {blocks.length >= 2 ? (
        <section className="shop-section" aria-labelledby="h-kat" data-testid="shop-home-categories">
          <div className="shop-section-head">
            <h2 id="h-kat" className="shop-h2">Kategoriler</h2>
          </div>
          <ul className="shop-catblocks" data-count={blocks.length}>
            {blocks.map((c) => {
              const url = publicImageUrl(c.image.path);
              return (
                <li key={c.slug}>
                  <Link href={`${base}/kategori/${c.slug}`} className="shop-catblock">
                    <span className="shop-catblock-media">
                      {url ? <Image src={url} alt="" fill sizes="(min-width: 900px) 33vw, 72vw" className="shop-catblock-img" /> : null}
                    </span>
                    <span className="shop-catblock-name">{c.name}</span>
                    <span className="shop-catblock-cta">Keşfet</span>
                  </Link>
                </li>
              );
            })}
          </ul>
        </section>
      ) : null}

      {featured.length > 0 ? (
        <section className="shop-section" aria-labelledby="h-one" data-testid="shop-home-featured" data-mode={featured.length === 1 ? "single" : "grid"}>
          <div className="shop-section-head">
            <h2 id="h-one" className="shop-h2">Öne Çıkanlar</h2>
            <Link href={`${base}/urunler`}>Tümünü gör</Link>
          </div>
          {featured.length === 1 ? (
            <FeaturedSingle base={base} card={featured[0]} currency={store.currency} />
          ) : (
            <ProductGrid slug={store.slug} cards={featured} currency={store.currency} />
          )}
        </section>
      ) : null}

      {store.about ? (
        <section className="shop-about" aria-labelledby="h-about" data-testid="shop-home-about">
          <p id="h-about" className="shop-eyebrow">Hakkımızda</p>
          <p className="shop-about-text">{store.about}</p>
        </section>
      ) : null}

      {store.instagram ? (
        <section className="shop-insta" data-testid="shop-home-instagram">
          <p className="shop-eyebrow">Instagram</p>
          <a className="shop-insta-link" href={`https://www.instagram.com/${store.instagram}/`} target="_blank" rel="noopener noreferrer">
            Instagram&apos;da bizi takip edin
          </a>
          <p className="shop-insta-handle">@{store.instagram}</p>
        </section>
      ) : null}
    </div>
  );
}

/**
 * Exactly one featured product: an editorial pairing (large photograph + name, price and a
 * quiet link) instead of one card stranded in an empty four-column row. 2–4 use the grid.
 */
function FeaturedSingle({ base, card, currency }: { base: string; card: ProductCard; currency: string }) {
  const url = publicImageUrl(card.image?.path);
  const href = `${base}/urun/${card.slug}`;
  return (
    <div className="shop-feature-one" data-testid="shop-featured-single">
      <Link href={href} className="shop-feature-one-media" aria-label={card.name}>
        {url ? <Image src={url} alt={card.image?.alt ?? card.name} fill sizes="(min-width: 900px) 40vw, 100vw" className="shop-feature-one-img" /> : null}
      </Link>
      <div className="shop-feature-one-copy">
        {card.category ? <p className="shop-eyebrow">{card.category.name}</p> : null}
        <h3 className="shop-feature-one-name">{card.name}</h3>
        <p className="shop-price">{formatPriceRange(card.price_from, card.price_to, currency)}</p>
        {card.availability === "sold_out" ? <p className="shop-card-state">Tükendi</p> : null}
        <Link href={href} className="shop-link">Ürünü incele</Link>
      </div>
    </div>
  );
}

function HeroCta({ store, base }: { store: Store; base: string }) {
  return store.published_count > 0 ? (
    <Link href={`${base}/urunler?sirala=newest`} className="shop-btn shop-hero-cta" data-testid="shop-hero-cta">Yeni Gelenleri Keşfet</Link>
  ) : (
    <p className="shop-muted">Koleksiyon yakında burada.</p>
  );
}

/**
 * The merchant's own hero image when one is set: image first on phones (portrait 4:5, the
 * copy and the CTA right below — never a full-screen poster), image beside the copy on
 * desktop at a height that keeps the next section in view. Without a hero image: the store
 * name and tagline, plus up to three current product photographs when there are at least two.
 */
function Hero({ store, home, base }: { store: Store; home: ShopHome; base: string }) {
  const hero = publicImageUrl(store.hero_image_path);
  if (hero) {
    return (
      <section className="shop-hero-ed" data-testid="shop-hero" data-variant="image">
        <div className="shop-hero-ed-media">
          <Image src={hero} alt={store.hero_heading ?? store.store_name} fill priority sizes={HERO_SIZES} className="shop-hero-ed-img" />
        </div>
        <div className="shop-hero-ed-copy">
          {store.tagline ? <p className="shop-eyebrow">{store.tagline}</p> : null}
          <h1 className="shop-hero-ed-title">{store.hero_heading ?? store.store_name}</h1>
          <HeroCta store={store} base={base} />
        </div>
      </section>
    );
  }
  const photos: ProductCard[] = home.new_arrivals.filter((c) => c.image).slice(0, 3);
  return (
    <section className="shop-hero-fb" data-testid="shop-hero" data-variant="fallback">
      <div className="shop-hero-fb-copy">
        <h1 className="shop-display">{store.store_name}</h1>
        {store.tagline ? <p className="shop-lead">{store.tagline}</p> : null}
        <HeroCta store={store} base={base} />
      </div>
      {photos.length >= 2 ? (
        <ul className="shop-hero-fb-media" data-count={photos.length}>
          {photos.map((c, i) => {
            const url = publicImageUrl(c.image?.path);
            return (
              <li key={c.slug}>
                <Link href={`${base}/urun/${c.slug}`} aria-label={c.name}>
                  {url ? <Image src={url} alt="" fill priority={i === 0} sizes="(min-width: 900px) 30vw, 50vw" className="shop-hero-fb-img" /> : null}
                </Link>
              </li>
            );
          })}
        </ul>
      ) : null}
    </section>
  );
}
