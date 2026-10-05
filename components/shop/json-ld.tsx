import { serializeJsonLd } from "@/lib/shop/seo";

/** The only way storefront pages emit structured data: escaped, one <script> per object. */
export function JsonLd({ data }: { data: unknown }) {
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: serializeJsonLd(data) }} />;
}
