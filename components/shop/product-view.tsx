"use client";

import Image from "next/image";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { X } from "lucide-react";
import {
  CART_MAX_LINES,
  CART_MAX_QTY,
  availabilityText,
  formatPriceRange,
  formatShopPrice,
  publicImageUrl,
  readCart,
  writeCart,
  type AvailabilityMap,
  type ShopImage,
  type ShopOption,
  type ShopProduct,
  type ShopVariant,
  type Store,
} from "@/lib/shop/model";
import { ProductGallery } from "@/components/shop/product-gallery";

type Added = { name: string; labels: string; quantity: number; image: string | null };

/**
 * Product page body. Variant state comes only from the public product response plus the
 * fresh availability map the server fetched for this request (rpc_shop_product +
 * rpc_shop_availability) — no second resolver, no browser inventory. Options are dynamic:
 * colour first, then size, then any other option; none, one or several. An option value
 * that cannot be bought with the current choice stays visible but disabled, so the customer
 * never picks something that fails afterwards. Adding to the cart writes the browser cart
 * only: CART ≠ RESERVATION (no movement, no hold).
 */
export function ProductView({ store, product, fresh }: { store: Store; product: ShopProduct; fresh: AvailabilityMap }) {
  const variants = useMemo<ShopVariant[]>(
    () => product.variants.map((v) => ({ ...v, state: fresh[v.id]?.state ?? v.state, available: fresh[v.id]?.available ?? v.available, price: fresh[v.id]?.price ?? v.price })),
    [product.variants, fresh],
  );
  const options = product.options;
  const colorOpt = options.find((o) => o.kind === "color") ?? null;
  const allSold = variants.length === 0 || variants.every((v) => v.state === "sold_out");

  const fits = (v: ShopVariant, sel: Record<string, string>) => Object.values(sel).every((valueId) => v.option_value_ids.includes(valueId));
  /** Some web variant carries this value together with the other current choices (colour only constrains, never the reverse). */
  const status = (o: ShopOption, valueId: string, sel: Record<string, string>): "ok" | "sold" | "absent" => {
    const others: Record<string, string> = {};
    for (const [k, v] of Object.entries(sel)) {
      if (k === o.id) continue;
      if (o.kind === "color") continue; // a colour is judged on its own
      others[k] = v;
    }
    const pool = variants.filter((v) => v.option_value_ids.includes(valueId) && fits(v, others));
    if (pool.length === 0) return "absent";
    return pool.some((v) => v.state !== "sold_out") ? "ok" : "sold";
  };

  const initial = useMemo(() => {
    const sel: Record<string, string> = {};
    for (const o of options) if (o.values.length === 1) sel[o.id] = o.values[0].id;
    if (colorOpt && !sel[colorOpt.id]) {
      const first = colorOpt.values.find((val) => variants.some((v) => v.option_value_ids.includes(val.id) && v.state !== "sold_out")) ?? colorOpt.values[0];
      if (first) sel[colorOpt.id] = first.id;
    }
    return sel;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [product.slug]);
  const [sel, setSel] = useState<Record<string, string>>(initial);
  const [helper, setHelper] = useState<string | null>(null);
  const [added, setAdded] = useState<Added | null>(null);
  const [ctaVisible, setCtaVisible] = useState(true);
  const [passedCta, setPassedCta] = useState(false);
  const cta = useRef<HTMLButtonElement>(null);
  const groups = useRef<Record<string, HTMLDivElement | null>>({});

  const complete = options.every((o) => sel[o.id]);
  const chosen = complete ? (variants.find((v) => fits(v, sel) && v.option_value_ids.length === Object.keys(sel).length) ?? variants.find((v) => fits(v, sel)) ?? null) : null;
  const prices = variants.map((v) => v.price);
  const priceText = chosen ? formatShopPrice(chosen.price, product.currency) : formatPriceRange(prices.length ? Math.min(...prices) : null, prices.length ? Math.max(...prices) : null, product.currency);

  // images: the chosen colour's own public images first, then the rest; never blank, never invented
  const colorValue = colorOpt ? sel[colorOpt.id] ?? null : null;
  const orderedImages = useMemo<ShopImage[]>(() => {
    if (!colorValue) return product.images;
    const own = new Set(variants.filter((v) => v.option_value_ids.includes(colorValue) && v.image_id).map((v) => v.image_id as string));
    if (own.size === 0) return product.images;
    return [...product.images.filter((i) => i.id && own.has(i.id)), ...product.images.filter((i) => !i.id || !own.has(i.id))];
  }, [colorValue, product.images, variants]);

  // the sticky phone CTA appears only once the real one has scrolled away above. A scroll
  // listener (rAF-throttled, passive) rather than IntersectionObserver: a jump from below the
  // viewport straight to above it (anchor, fling) crosses no threshold and would be missed.
  useEffect(() => {
    let frame = 0;
    const measure = () => {
      frame = 0;
      const el = cta.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      setCtaVisible(r.bottom > 0 && r.top < window.innerHeight);
      setPassedCta(r.bottom <= 0);
    };
    const onScroll = () => { if (!frame) frame = window.requestAnimationFrame(measure); };
    measure();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => { window.removeEventListener("scroll", onScroll); window.removeEventListener("resize", onScroll); if (frame) window.cancelAnimationFrame(frame); };
  }, []);

  const closeAdded = useCallback(() => setAdded(null), []);
  useEffect(() => {
    if (!added) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") closeAdded(); };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [added, closeAdded]);

  function choose(o: ShopOption, valueId: string) {
    setHelper(null);
    setAdded(null);
    setSel((s) => {
      const next = { ...s, [o.id]: valueId };
      // a colour change may make the chosen size impossible: drop it rather than keep a dead choice
      if (o.kind === "color") {
        for (const other of options) {
          if (other.id === o.id || !next[other.id]) continue;
          if (status(other, next[other.id], next) !== "ok") delete next[other.id];
        }
      }
      return next;
    });
  }

  function missingMessage(): string | null {
    const o = options.find((x) => !sel[x.id]);
    if (!o) return null;
    if (o.kind === "color") return "Lütfen renk seçin.";
    if (o.kind === "size") return "Lütfen beden seçin.";
    return `Lütfen ${o.name.toLocaleLowerCase("tr-TR")} seçin.`;
  }

  function addToCart() {
    if (allSold) return;
    const missing = missingMessage();
    if (missing || !chosen) {
      setHelper(missing ?? "Lütfen seçiminizi tamamlayın.");
      const o = options.find((x) => !sel[x.id]);
      if (o) groups.current[o.id]?.scrollIntoView({ behavior: "smooth", block: "center" });
      return;
    }
    if (chosen.state === "sold_out") { setHelper("Bu seçenek tükendi."); return; }
    const cart = readCart(store.slug);
    const labels = options.map((o) => o.values.find((v) => v.id === sel[o.id])?.value).filter(Boolean).join(" / ");
    const image = orderedImages[0]?.path ?? null;
    const line = cart.lines.find((l) => l.variant_id === chosen.id);
    if (line) {
      if (line.quantity >= CART_MAX_QTY) { setHelper(`Bu üründen sepette en fazla ${CART_MAX_QTY} adet olabilir.`); return; }
      line.quantity += 1;
    } else {
      if (cart.lines.length >= CART_MAX_LINES) { setHelper(`Sepette en fazla ${CART_MAX_LINES} farklı ürün olabilir.`); return; }
      cart.lines.push({ variant_id: chosen.id, product_slug: product.slug, name: product.name, labels, unit_price: chosen.price, currency: product.currency, quantity: 1, image_path: image });
    }
    writeCart(cart);
    setHelper(null);
    setAdded({ name: product.name, labels, quantity: (line?.quantity ?? 1), image: publicImageUrl(image) });
  }

  const stateText = chosen && !allSold ? availabilityText(chosen.state, chosen.available, product.stock_display) : null;
  const whatsapp = store.whatsapp ? `https://wa.me/${store.whatsapp.replace(/[^0-9]/g, "")}?text=${encodeURIComponent(`Merhaba, ${product.name} hakkında bilgi almak istiyorum.`)}` : null;
  const contact = [
    whatsapp ? { href: whatsapp, label: "WhatsApp ile yazın", external: true } : null,
    store.instagram ? { href: `https://instagram.com/${store.instagram}`, label: "Instagram", external: true } : null,
    store.contact_phone ? { href: `tel:${store.contact_phone.replace(/[^0-9+]/g, "")}`, label: store.contact_phone, external: false } : null,
    store.contact_email ? { href: `mailto:${store.contact_email}`, label: store.contact_email, external: false } : null,
  ].filter((x): x is { href: string; label: string; external: boolean } => x !== null);
  const description = product.description?.trim() || null;

  return (
    <div className="shop-pdp" data-testid="shop-pdp">
      <ProductGallery images={orderedImages} name={product.name} resetKey={colorValue ?? ""} />

      <div className="shop-buy">
        <div className="shop-buy-head">
          {product.category ? <Link href={`/shop/${store.slug}/kategori/${product.category.slug}`} className="shop-kicker shop-buy-cat">{product.category.name}</Link> : null}
          <h1 className="shop-buy-name">{product.name}</h1>
          <p className="shop-buy-price shop-price" data-testid="shop-price">{priceText}</p>
        </div>

        {options.map((o) => {
          const isColor = o.kind === "color";
          const label = isColor ? "Renk" : o.kind === "size" ? "Beden" : o.name;
          const current = o.values.find((v) => v.id === sel[o.id]);
          const swatches = isColor && o.values.every((v) => v.hex);
          return (
            <div key={o.id} className="shop-opt" ref={(el) => { groups.current[o.id] = el; }}>
              <p className="shop-opt-head" id={`opt-${o.id}`}>
                <span className="shop-kicker">{label}</span>
                {current ? <span className="shop-opt-value"> — {current.value}</span> : null}
              </p>
              <div className={swatches ? "shop-opt-swatches" : "shop-opt-buttons"} role="group" aria-labelledby={`opt-${o.id}`}>
                {o.values.map((v) => {
                  const st = status(o, v.id, sel);
                  const pressed = sel[o.id] === v.id;
                  const blocked = st !== "ok";
                  const name = `${v.value}${st === "sold" ? " — Tükendi" : st === "absent" ? " — Bu seçimde yok" : ""}`;
                  return swatches ? (
                    <button key={v.id} type="button" className="shop-opt-swatch" aria-pressed={pressed} aria-label={name} title={name} disabled={blocked} data-blocked={blocked ? "true" : undefined} onClick={() => choose(o, v.id)}>
                      <span style={{ background: v.hex ?? undefined }} aria-hidden />
                    </button>
                  ) : (
                    <button key={v.id} type="button" className="shop-opt-btn" aria-pressed={pressed} aria-label={name} disabled={blocked} data-blocked={blocked ? "true" : undefined} onClick={() => choose(o, v.id)}>
                      {v.value}
                    </button>
                  );
                })}
              </div>
            </div>
          );
        })}

        <div className="shop-buy-action">
          {stateText ? <p className="shop-buy-state" data-state={chosen ? chosen.state : "sold_out"} data-testid="shop-availability">{stateText}</p> : null}
          <button ref={cta} type="button" className="shop-btn" disabled={allSold} onClick={addToCart} data-testid="shop-add">
            {allSold ? "Tükendi" : "Sepete Ekle"}
          </button>
          <p className="shop-buy-helper" role="alert" aria-live="assertive">{helper ?? ""}</p>
        </div>

        {description || store.pickup_branch || contact.length > 0 ? (
          <div className="shop-info">
            {description ? (
              <details className="shop-disclosure" open>
                <summary>Açıklama</summary>
                <p className="shop-desc">{description}</p>
              </details>
            ) : null}
            {store.pickup_branch ? (
              <details className="shop-disclosure">
                <summary>Mağazadan teslim</summary>
                <div className="shop-disclosure-body">
                  <p>Siparişinizi {store.pickup_branch} mağazasından teslim alırsınız. Ödeme teslim sırasında mağazada yapılır.</p>
                  {store.pickup_note ? <p>{store.pickup_note}</p> : null}
                </div>
              </details>
            ) : null}
            {contact.length > 0 ? (
              <details className="shop-disclosure">
                <summary>İletişim</summary>
                <div className="shop-disclosure-body shop-disclosure-links">
                  {contact.map((c) => (
                    <a key={c.href} href={c.href} {...(c.external ? { target: "_blank", rel: "noopener noreferrer" } : {})}>{c.label}</a>
                  ))}
                </div>
              </details>
            ) : null}
          </div>
        ) : null}
      </div>

      {/* phone: the purchase action follows once the real one has scrolled away */}
      {!allSold && passedCta && !ctaVisible && !added ? (
        <div className="shop-sticky-cta" data-testid="shop-sticky-cta">
          <span className="shop-price" data-numeric>{priceText}</span>
          <button type="button" className="shop-btn" onClick={addToCart}>Sepete Ekle</button>
        </div>
      ) : null}

      {added ? (
        <div className="shop-added" role="dialog" aria-modal="false" aria-labelledby="shop-added-title" data-testid="shop-added">
          <div className="shop-added-head">
            <p id="shop-added-title" className="shop-added-title">Sepete eklendi</p>
            <button type="button" className="shop-icon" aria-label="Kapat" onClick={closeAdded}><X aria-hidden strokeWidth={1.4} /></button>
          </div>
          <div className="shop-added-item">
            <div className="shop-added-thumb">{added.image ? <Image src={added.image} alt="" fill sizes="64px" /> : null}</div>
            <div>
              <p className="shop-added-name">{added.name}</p>
              {added.labels ? <p className="shop-added-meta">{added.labels}</p> : null}
              <p className="shop-added-meta" data-numeric>Adet: {added.quantity}</p>
            </div>
          </div>
          <div className="shop-added-actions">
            <Link href={`/shop/${store.slug}/sepet`} className="shop-btn" autoFocus>Sepete git</Link>
            <button type="button" className="shop-link" onClick={closeAdded}>Alışverişe devam et</button>
          </div>
        </div>
      ) : null}
    </div>
  );
}
