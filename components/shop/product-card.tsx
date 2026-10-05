import Link from "next/link";
import Image from "next/image";
import { formatPriceRange, publicImageUrl, type ProductCard as Card } from "@/lib/shop/model";

const MAX_SWATCHES = 4;

/**
 * Catalogue card: the photograph is the card. Below it only the name, the price and — when
 * a product comes in more than one colour — a few swatches with their names for assistive
 * tech. A second public image fades in on hover (pointer devices only); without one there
 * is no animation. Nothing operational: no SKU, no stock count, no internal status.
 */
export function ProductCard({ slug, card, currency, priority = false, sizes }: { slug: string; card: Card; currency: string; priority?: boolean; sizes?: string }) {
  const img = publicImageUrl(card.image?.path);
  const hover = publicImageUrl(card.image_hover?.path);
  const sold = card.availability === "sold_out";
  const colors = card.colors.length > 1 ? card.colors : [];
  const shown = colors.slice(0, MAX_SWATCHES);
  const more = colors.length - shown.length;
  const imgSizes = sizes ?? "(min-width: 1200px) 25vw, (min-width: 768px) 33vw, 50vw";

  return (
    <Link href={`/shop/${slug}/urun/${card.slug}`} className="shop-card" data-sold={sold ? "true" : undefined} data-testid="shop-card">
      <div className="shop-card-media">
        {img ? (
          <Image src={img} alt={card.image?.alt ?? card.name} fill sizes={imgSizes} priority={priority} className="shop-card-img" />
        ) : (
          <span className="shop-card-empty" aria-hidden>{card.name.slice(0, 1)}</span>
        )}
        {img && hover ? <Image src={hover} alt="" aria-hidden fill sizes={imgSizes} className="shop-card-img shop-card-img-hover" /> : null}
      </div>
      <div className="shop-card-body">
        <p className="shop-card-name">{card.name}</p>
        <p className="shop-card-price shop-price">{formatPriceRange(card.price_from, card.price_to, currency)}</p>
        {shown.length > 0 ? (
          <p className="shop-swatches">
            <span className="shop-sr">{`Renkler: ${colors.map((c) => c.value).join(", ")}`}</span>
            {shown.map((c) => (
              <span key={c.value} className="shop-swatch" style={{ background: c.hex ?? "#e5e1da" }} title={c.value} aria-hidden />
            ))}
            {more > 0 ? <span className="shop-swatch-more" aria-hidden>+{more}</span> : null}
          </p>
        ) : null}
        {sold ? <p className="shop-card-state">Tükendi</p> : card.availability === "low" ? <p className="shop-card-state shop-card-state-low">Son ürünler</p> : null}
      </div>
    </Link>
  );
}

/** Home sections keep their 14A grid; the catalogue uses the full-bleed variant. */
export function ProductGrid({ slug, cards, currency, eager = 0, variant = "home", startIndex = 0 }: { slug: string; cards: Card[]; currency: string; eager?: number; variant?: "home" | "catalog"; startIndex?: number }) {
  if (variant === "catalog") {
    return (
      <ul className="shop-catalog" data-testid="shop-catalog">
        {cards.map((c, i) => (
          <li key={c.slug} id={`urun-${startIndex + i + 1}`}>
            <ProductCard slug={slug} card={c} currency={currency} priority={i < eager} sizes="(min-width: 1200px) 25vw, (min-width: 768px) 33vw, 50vw" />
          </li>
        ))}
      </ul>
    );
  }
  return (
    <div className="shop-grid">
      {cards.map((c, i) => (
        <ProductCard key={c.slug} slug={slug} card={c} currency={currency} priority={i < eager} />
      ))}
    </div>
  );
}
