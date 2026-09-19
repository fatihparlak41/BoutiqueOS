import Link from "next/link";
import Image from "next/image";
import { AVAILABILITY_LABELS, formatPriceRange, publicImageUrl, type ProductCard as Card } from "@/lib/shop/model";

/** Listing card: image, name, price, colour swatches, availability. Nothing operational. */
export function ProductCard({ slug, card, currency, priority = false }: { slug: string; card: Card; currency: string; priority?: boolean }) {
  const img = publicImageUrl(card.image?.path);
  const sold = card.availability === "sold_out";
  return (
    <Link href={`/shop/${slug}/urun/${card.slug}`} className={`shop-card${sold ? " shop-card-sold" : ""}`}>
      <div className="shop-card-media">
        {img ? (
          <Image src={img} alt={card.image?.alt ?? card.name} fill sizes="(min-width: 1200px) 25vw, (min-width: 768px) 33vw, 50vw" priority={priority} unoptimized />
        ) : (
          <span className="shop-card-empty" aria-hidden>{card.name.slice(0, 1)}</span>
        )}
      </div>
      <div className="shop-card-body">
        <p className="shop-card-name">{card.name}</p>
        <div className="shop-card-meta">
          <span className="shop-price">{formatPriceRange(card.price_from, card.price_to, currency)}</span>
          {card.colors.length > 1 ? (
            <span className="shop-swatches" aria-label={`${card.colors.length} renk`}>
              {card.colors.slice(0, 5).map((c) => (
                <span key={c.value} className="shop-swatch" style={{ background: c.hex ?? "#e5e1da" }} title={c.value} />
              ))}
            </span>
          ) : null}
        </div>
        {card.availability !== "in_stock" ? <span className="shop-state" data-state={card.availability}>{AVAILABILITY_LABELS[card.availability]}</span> : null}
      </div>
    </Link>
  );
}

export function ProductGrid({ slug, cards, currency, eager = 0 }: { slug: string; cards: Card[]; currency: string; eager?: number }) {
  return (
    <div className="shop-grid">
      {cards.map((c, i) => (
        <ProductCard key={c.slug} slug={slug} card={c} currency={currency} priority={i < eager} />
      ))}
    </div>
  );
}
