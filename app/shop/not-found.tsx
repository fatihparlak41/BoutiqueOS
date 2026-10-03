import type { Metadata } from "next";
import { ShopBackLink } from "@/components/shop/back-link";

export const metadata: Metadata = { title: "Sayfa bulunamadı", robots: { index: false, follow: false } };

/**
 * An unknown, closed or disabled store. There is no store to name and none to link to, so
 * the page stays neutral: no BoutiqueOS wordmark, no link into the operational app, and
 * the same answer whether the store never existed or is closed (nothing to enumerate).
 */
export default function ShopNotFound() {
  return (
    <div className="shop shop-404-page" data-testid="shop-404">
      <section className="shop-404">
        <p className="shop-kicker">404</p>
        <h1 className="shop-display">Bu sayfa bulunamadı.</h1>
        <p className="shop-404-text">Bu mağaza ya da sayfa şu anda yayında değil.</p>
        <div className="shop-404-actions">
          <ShopBackLink />
        </div>
      </section>
    </div>
  );
}
