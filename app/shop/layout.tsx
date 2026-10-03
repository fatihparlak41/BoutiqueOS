import "@/app/shop/shop.css";

/**
 * Every /shop route, including the neutral 404 of an unknown store, carries the storefront
 * stylesheet. The store chrome itself lives in [slug]/layout.
 */
export default function ShopRootLayout({ children }: { children: React.ReactNode }) {
  return children;
}
