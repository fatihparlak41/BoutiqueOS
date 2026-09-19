import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireTenant } from "@/lib/tenant";
import { getStorefrontAdmin, getStorefrontAdminProduct } from "@/lib/storefront/queries";
import { IMAGE_ROLE_LABELS, PUBLIC_IMAGE_ROLES, storefrontCaps } from "@/lib/storefront/model";
import { formatShopPrice, publicImageUrl } from "@/lib/shop/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { Badge } from "@/components/ui/badge";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";
import { ImagePublishToggle, ProductWebForm, PublishToggle, VariantWebToggle } from "@/app/app/online-magaza/forms";

export const metadata = { title: "Online Mağaza · Ürün · BoutiqueOS" };

/**
 * A product's web presence: publish state, copy, which variants the storefront offers,
 * which images are public. Label tags and receiving proofs are listed only to say they
 * stay private; there is no button that could publish them.
 */
export default async function OnlineStoreProductPage({ params }: { params: Promise<{ id: string }> }) {
  const { active } = await requireTenant();
  if (!storefrontCaps(active.role).canManage) redirect("/app/online-magaza");
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const [product, admin] = await Promise.all([getStorefrontAdminProduct(id), getStorefrontAdmin(null, 0, 1)]);
  if (!product) notFound();
  const sf = admin.storefront;
  const publicUrl = sf && product.web_slug ? `/shop/${sf.slug}/urun/${product.web_slug}` : null;

  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow={{ href: "/app/online-magaza", label: "Online Mağaza" }}
        title={product.name}
        description={
          <>
            {product.status === "active" ? "Aktif ürün" : `Ürün ${product.status}`} · liste fiyatı <span data-numeric>{formatShopPrice(product.default_sale_price, admin.currency)}</span>
            {publicUrl && product.web_published ? <> · <a href={publicUrl} target="_blank" rel="noopener noreferrer" className="underline-offset-4 hover:underline">mağazada gör ↗</a></> : null}
            {" · "}<Link href={`/app/urunler/${product.id}`} className="underline-offset-4 hover:underline">ürün kartı</Link>
          </>
        }
        actions={<Badge tone={product.web_published ? "success" : "neutral"}>{product.web_published ? "Yayında" : "Yayında değil"}</Badge>}
      />

      <section className="space-y-3">
        <SectionHeader title="Yayın" meta={product.web_published_at ? `ilk yayın ${new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium" }).format(new Date(product.web_published_at))}` : undefined} />
        <div className="space-y-2 rounded border border-border bg-surface p-4">
          <p className="text-xs leading-relaxed text-text-muted">
            Yayın için ürün aktif olmalı, en az bir webde gösterilen varyantı ve sıfırdan büyük satış fiyatı bulunmalı. Stok şart değildir; stoksuz ürün &quot;Tükendi&quot; görünür. Arşivlenen ürün kendiliğinden yayından düşer.
          </p>
          <PublishToggle productId={product.id} published={product.web_published} disabled={!sf || product.status !== "active"} />
          {!sf ? <p className="text-xs text-text-muted">Önce mağaza ayarlarını kaydedin.</p> : null}
        </div>
      </section>

      <section className="space-y-3">
        <SectionHeader title="Web metni ve yerleşim" />
        <ProductWebForm product={product} />
      </section>

      <section className="space-y-3">
        <SectionHeader title="Varyantlar" meta={`${product.variants.filter((v) => v.web_enabled).length} / ${product.variants.length} webde`} />
        <TableShell minWidth="36rem">
          <THead>
            <TH>Seçenekler</TH>
            <TH align="right">Web fiyatı</TH>
            <TH>Web</TH>
            <TH>İşlem</TH>
          </THead>
          <TBody>
            {product.variants.map((v) => (
              <TR key={v.id}>
                <TD>{v.labels || "Tek beden"}</TD>
                <TD align="right" numeric>{formatShopPrice(v.price, admin.currency)}</TD>
                <TD><Badge tone={v.web_enabled ? "success" : "neutral"}>{v.web_enabled ? "Gösteriliyor" : "Gizli"}</Badge></TD>
                <TD><VariantWebToggle variantId={v.id} enabled={v.web_enabled} /></TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
        <p className="text-xs text-text-muted">Fiyat, ürünün satış fiyatıdır (varyant fiyatı varsa o). Web için ayrı fiyat listesi tutulmaz.</p>
      </section>

      <section className="space-y-3">
        <SectionHeader title="Görseller" meta={`${product.images.filter((i) => i.public_path).length} yayında`} />
        {product.images.length === 0 ? (
          <p className="text-sm text-text-muted">Bu ürünün görseli yok. Ürün kartından görsel yükleyin; ardından burada yayınlayın.</p>
        ) : (
          <ul className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
            {product.images.map((i) => {
              const allowed = (PUBLIC_IMAGE_ROLES as readonly string[]).includes(i.role);
              const url = publicImageUrl(i.public_path);
              return (
                <li key={i.id} className="space-y-2 rounded border border-border bg-surface p-3">
                  <div className="aspect-[3/4] overflow-hidden rounded-sm bg-surface-muted">
                    {url ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={url} alt={i.alt ?? ""} className="h-full w-full object-cover" loading="lazy" />
                    ) : (
                      <div className="flex h-full items-center justify-center text-2xs text-text-muted">{allowed ? "yayında değil" : "özel"}</div>
                    )}
                  </div>
                  <p className="text-xs text-text-secondary">{IMAGE_ROLE_LABELS[i.role] ?? i.role}</p>
                  <ImagePublishToggle imageId={i.id} published={Boolean(i.public_path)} allowed={allowed} />
                </li>
              );
            })}
          </ul>
        )}
        <p className="text-xs leading-relaxed text-text-muted">
          Yayınlanan görsel herkese açık depoya kopyalanır; özel depo özel kalır. Etiket ve mal kabul kanıtı görselleri hiçbir koşulda yayınlanmaz.
        </p>
      </section>
    </div>
  );
}
