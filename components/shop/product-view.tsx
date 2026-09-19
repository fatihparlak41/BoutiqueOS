"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import {
  AVAILABILITY_LABELS,
  CART_MAX_LINES,
  CART_MAX_QTY,
  availabilityText,
  formatPriceRange,
  formatShopPrice,
  publicImageUrl,
  readCart,
  writeCart,
  type AvailabilityMap,
  type ShopProduct,
  type ShopVariant,
} from "@/lib/shop/model";

/**
 * Product page body: gallery + variant picker + add to cart. Options come from the
 * product's own option architecture (colour first, then size, then anything else); a
 * product may have none, one or several. Availability is the fresh map the page fetched
 * (never the cached copy). Adding to the cart reserves nothing — CART ≠ RESERVATION.
 */
export function ProductView({ slug, product, fresh }: { slug: string; product: ShopProduct; fresh: AvailabilityMap }) {
  const variants = useMemo<ShopVariant[]>(
    () => product.variants.map((v) => ({ ...v, state: fresh[v.id]?.state ?? v.state, available: fresh[v.id]?.available ?? v.available, price: fresh[v.id]?.price ?? v.price })),
    [product.variants, fresh],
  );
  const options = product.options;
  const colorOpt = options.find((o) => o.kind === "color") ?? null;

  const matches = (v: ShopVariant, sel: Record<string, string>) => Object.entries(sel).every(([, valueId]) => v.option_value_ids.includes(valueId));
  const anyLive = (sel: Record<string, string>) => variants.some((v) => matches(v, sel) && v.state !== "sold_out");

  // default: the first colour that still has something, sizes left to the customer (a single value is taken)
  const initial = useMemo(() => {
    const sel: Record<string, string> = {};
    for (const o of options) {
      if (o.values.length === 1) sel[o.id] = o.values[0].id;
    }
    if (colorOpt && !sel[colorOpt.id]) {
      const first = colorOpt.values.find((val) => anyLive({ ...sel, [colorOpt.id]: val.id })) ?? colorOpt.values[0];
      if (first) sel[colorOpt.id] = first.id;
    }
    return sel;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [product.slug]);
  const [sel, setSel] = useState<Record<string, string>>(initial);
  const [imageId, setImageId] = useState<string | null>(product.images[0]?.id ?? null);
  const [added, setAdded] = useState<string | null>(null);

  const complete = options.every((o) => sel[o.id]);
  const chosen = complete ? (variants.find((v) => matches(v, sel) && v.option_value_ids.length === Object.keys(sel).length) ?? variants.find((v) => matches(v, sel)) ?? null) : null;
  const prices = variants.map((v) => v.price);
  const priceText = chosen ? formatShopPrice(chosen.price, product.currency) : formatPriceRange(prices.length ? Math.min(...prices) : null, prices.length ? Math.max(...prices) : null, product.currency);

  // colour → variant image where one exists
  useEffect(() => {
    if (!colorOpt || !sel[colorOpt.id]) return;
    const v = variants.find((x) => x.option_value_ids.includes(sel[colorOpt.id]) && x.image_id);
    if (v?.image_id) setImageId(v.image_id);
  }, [sel, colorOpt, variants]);

  const image = product.images.find((i) => i.id === imageId) ?? product.images[0] ?? null;
  const mainUrl = publicImageUrl(image?.path);

  function choose(optionId: string, valueId: string) {
    setAdded(null);
    setSel((s) => ({ ...s, [optionId]: valueId }));
  }

  function addToCart() {
    if (!chosen || chosen.state === "sold_out") return;
    const cart = readCart(slug);
    const line = cart.lines.find((l) => l.variant_id === chosen.id);
    const labels = options.map((o) => o.values.find((v) => v.id === sel[o.id])?.value).filter(Boolean).join(" / ");
    if (line) {
      line.quantity = Math.min(CART_MAX_QTY, line.quantity + 1);
    } else {
      if (cart.lines.length >= CART_MAX_LINES) { setAdded("Sepet dolu (en fazla 20 ürün)."); return; }
      cart.lines.push({ variant_id: chosen.id, product_slug: product.slug, name: product.name, labels, unit_price: chosen.price, currency: product.currency, quantity: 1, image_path: image?.path ?? null });
    }
    writeCart(cart);
    setAdded("Sepete eklendi.");
  }

  const sold = chosen ? chosen.state === "sold_out" : variants.every((v) => v.state === "sold_out");

  return (
    <div className="shop-pdp">
      <div className="shop-gallery">
        <div className="shop-gallery-main">
          {mainUrl ? <Image src={mainUrl} alt={image?.alt ?? product.name} width={image?.width ?? 1200} height={image?.height ?? 1600} priority unoptimized style={{ width: "100%", height: "100%", objectFit: "cover" }} /> : <span className="shop-card-empty" aria-hidden>{product.name.slice(0, 1)}</span>}
        </div>
        {product.images.length > 1 ? (
          <div className="shop-thumbs" role="list">
            {product.images.map((i) => {
              const u = publicImageUrl(i.path);
              return (
                <button key={i.id} type="button" className="shop-thumb" aria-current={i.id === image?.id ? "true" : undefined} onClick={() => setImageId(i.id ?? null)} aria-label={i.alt ?? "Görsel"}>
                  {u ? <Image src={u} alt="" width={64} height={85} unoptimized /> : null}
                </button>
              );
            })}
          </div>
        ) : null}
      </div>

      <div className="shop-buy">
        <div>
          {product.category ? <Link href={`/shop/${slug}/kategori/${product.category.slug}`} className="shop-eyebrow" style={{ textDecoration: "none" }}>{product.category.name}</Link> : null}
          <h1 className="shop-h2" style={{ marginTop: 6 }}>{product.name}</h1>
          <p className="shop-price" style={{ marginTop: 10, fontSize: 17 }}>{priceText}</p>
        </div>

        {options.map((o) => {
          const isColor = o.kind === "color";
          const label = isColor ? "Renk" : o.kind === "size" ? "Beden" : o.name;
          const current = o.values.find((v) => v.id === sel[o.id]);
          return (
            <div key={o.id}>
              <div className="shop-opt-label">
                <span>{label}</span>
                {current ? <b>{current.value}</b> : <span>Seçin</span>}
              </div>
              <div className={isColor ? "shop-colors" : "shop-sizes"} role="group" aria-label={label}>
                {o.values.map((v) => {
                  const others = { ...sel }; delete others[o.id];
                  const live = anyLive({ ...others, [o.id]: v.id });
                  const pressed = sel[o.id] === v.id;
                  return isColor ? (
                    <button key={v.id} type="button" className="shop-color" aria-pressed={pressed} data-sold={!live} title={v.value} aria-label={`${v.value}${live ? "" : " — tükendi"}`} onClick={() => choose(o.id, v.id)}>
                      <span style={{ background: v.hex ?? "#e5e1da" }} />
                    </button>
                  ) : (
                    <button key={v.id} type="button" className="shop-size" aria-pressed={pressed} data-sold={!live} aria-label={`${v.value}${live ? "" : " — tükendi"}`} onClick={() => choose(o.id, v.id)}>
                      {v.value}
                    </button>
                  );
                })}
              </div>
            </div>
          );
        })}

        <div>
          <p className="shop-state" data-state={chosen ? chosen.state : sold ? "sold_out" : undefined} style={{ marginBottom: 12, fontSize: 13 }}>
            {chosen ? availabilityText(chosen.state, chosen.available, product.stock_display) : sold ? AVAILABILITY_LABELS.sold_out : options.length ? "Seçiminizi tamamlayın" : ""}
          </p>
          <button type="button" className="shop-btn" disabled={!chosen || sold} onClick={addToCart}>
            {sold ? "Tükendi" : "Sepete ekle"}
          </button>
          {added ? (
            <p className="shop-note" role="status" style={{ marginTop: 10 }}>
              {added} <Link href={`/shop/${slug}/sepet`} style={{ borderBottom: "1px solid currentColor" }}>Sepete git</Link>
            </p>
          ) : null}
          <p className="shop-note" style={{ marginTop: 12 }}>Sepet stok ayırmaz; ürün, sipariş anındaki müsaitliğe göre teslim edilir.</p>
        </div>

        {product.description ? <p className="shop-desc">{product.description}</p> : null}
      </div>
    </div>
  );
}
