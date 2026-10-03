"use client";

import Image from "next/image";
import { useEffect, useRef, useState } from "react";
import { publicImageUrl, type ShopImage } from "@/lib/shop/model";

/**
 * Product imagery. Phone: a native horizontal scroll-snap track (no carousel library) with a
 * quiet position indicator; arrow keys move between images when the track has focus.
 * Desktop: the same images as a vertical stack beside the sticky purchase column.
 * Only public storefront copies are ever passed in (rpc_shop_product); nothing is invented —
 * a product without images shows one calm placeholder.
 */
export function ProductGallery({ images, name, resetKey }: { images: ShopImage[]; name: string; resetKey: string }) {
  const track = useRef<HTMLDivElement>(null);
  const [index, setIndex] = useState(0);

  // a colour change re-orders the images (its own image first): show the first one again
  useEffect(() => {
    track.current?.scrollTo({ left: 0, behavior: "smooth" });
    setIndex(0);
  }, [resetKey]);

  function onScroll() {
    const el = track.current;
    if (!el || el.clientWidth === 0) return;
    setIndex(Math.round(el.scrollLeft / el.clientWidth));
  }

  function onKey(e: React.KeyboardEvent<HTMLDivElement>) {
    const el = track.current;
    if (!el || (e.key !== "ArrowRight" && e.key !== "ArrowLeft")) return;
    e.preventDefault();
    const next = Math.max(0, Math.min(images.length - 1, index + (e.key === "ArrowRight" ? 1 : -1)));
    el.scrollTo({ left: next * el.clientWidth, behavior: "smooth" });
  }

  if (images.length === 0) {
    return (
      <div className="shop-gal">
        <div className="shop-gal-slide"><span className="shop-card-empty" aria-hidden>{name.slice(0, 1)}</span></div>
      </div>
    );
  }

  return (
    <div className="shop-gal" data-testid="shop-gallery">
      <div
        ref={track}
        className="shop-gal-track"
        onScroll={onScroll}
        onKeyDown={onKey}
        tabIndex={images.length > 1 ? 0 : -1}
        role="region"
        aria-roledescription="galeri"
        aria-label={`${name} görselleri`}
      >
        {images.map((img, i) => {
          const url = publicImageUrl(img.path);
          return (
            <div key={img.id ?? img.path} className="shop-gal-slide" aria-label={images.length > 1 ? `${i + 1} / ${images.length}` : undefined}>
              {url ? (
                <Image
                  src={url}
                  alt={img.alt ?? (images.length > 1 ? `${name} — görsel ${i + 1}` : name)}
                  fill
                  sizes="(min-width: 900px) 58vw, 100vw"
                  priority={i === 0}
                  unoptimized
                  className="shop-gal-img"
                />
              ) : null}
            </div>
          );
        })}
      </div>
      {images.length > 1 ? (
        <div className="shop-gal-dots" aria-hidden>
          {images.map((img, i) => <span key={img.id ?? img.path} data-active={i === index ? "true" : undefined} />)}
          <span className="shop-gal-count" data-numeric>{index + 1} / {images.length}</span>
        </div>
      ) : null}
    </div>
  );
}
