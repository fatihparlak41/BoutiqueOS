"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
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
    <Link href={`/shop/${slug}/sepet`} className="shop-icon-btn" aria-label={`Sepet, ${count} ürün`}>
      <span>Sepet</span>
      {count > 0 ? <span className="shop-count" data-numeric>{count}</span> : null}
    </Link>
  );
}
