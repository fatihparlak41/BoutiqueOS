"use client";

/** "Geri dön" for the neutral store 404: browser history only, no destination of our own. */
export function ShopBackLink() {
  return (
    <button type="button" className="shop-link" onClick={() => window.history.back()}>
      Geri dön
    </button>
  );
}
