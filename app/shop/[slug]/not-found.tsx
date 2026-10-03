"use client";

import Link from "next/link";
import { useParams } from "next/navigation";

/**
 * A missing product, category, order or any other page inside a live store. Renders
 * inside the store's own header and footer; it never links to the operational app.
 */
export default function ShopPageNotFound() {
  const params = useParams<{ slug: string }>();
  const base = `/shop/${params.slug}`;
  return (
    <section className="shop-404" data-testid="shop-404">
      <p className="shop-kicker">404</p>
      <h1 className="shop-display">Bu sayfa bulunamadı.</h1>
      <p className="shop-404-text">Aradığınız ürün ya da sayfa artık yayında olmayabilir.</p>
      <div className="shop-404-actions">
        <Link href={`${base}/urunler`} className="shop-btn">Ürünleri keşfet</Link>
        <Link href={base} className="shop-link">Mağazaya dön</Link>
      </div>
    </section>
  );
}
