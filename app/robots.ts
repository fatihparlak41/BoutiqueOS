import type { MetadataRoute } from "next";
import { siteOrigin } from "@/lib/url";

/**
 * Crawl policy. Public storefront pages are crawlable; operational, auth and private
 * storefront routes are not. This is NOT a security boundary — those routes stay protected
 * by auth, tokens and noindex,nofollow on their own.
 */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      {
        userAgent: "*",
        allow: ["/shop/"],
        disallow: [
          "/app/", "/platform/", "/login", "/kayit", "/basvuru", "/hesap-durumu", "/davet/",
          "/sifre-belirle", "/sifre-sifirla", "/select-business", "/no-access", "/auth/",
          "/shop/*/sepet", "/shop/*/checkout", "/shop/*/siparis/",
        ],
      },
    ],
    sitemap: `${siteOrigin()}/sitemap.xml`,
  };
}
