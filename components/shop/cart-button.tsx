"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { ShoppingBag } from "lucide-react";
import { cartCount, readCart } from "@/lib/shop/model";

/** Cart entry in the header. Reads browser state only; renders 0 on the server. */
export function CartButton({ slug }: { slug: string }) {
  const [count, setCount] = useState(0);
  useEffect(() => {
    const refresh = () => setCount(cartCount(readCart(slug)));
    refresh();
    const onCart = (e: Event) => { if ((e as CustomEvent<{ store: string }>).detail?.store === slug) refresh(); };
    window.addEventListener("bos-cart", onCart);
    window.addEventListener("storage", refresh);
    return () => { window.removeEventListener("bos-cart", onCart); window.removeEventListener("storage", refresh); };
  }, [slug]);
  return (
    <Link href={`/shop/${slug}/sepet`} className="shop-icon shop-cart-btn" aria-label={`Sepet, ${count} ürün`} data-testid="shop-cart-button">
      <ShoppingBag aria-hidden strokeWidth={1.4} />
      <span className="shop-icon-label">Sepet</span>
      {/* reserved width: the count appearing after hydration does not shift the header */}
      <span className="shop-count" data-numeric data-empty={count === 0 ? "true" : undefined}>{count > 0 ? count : ""}</span>
    </Link>
  );
}
