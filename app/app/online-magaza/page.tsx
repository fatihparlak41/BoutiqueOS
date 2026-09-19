import Link from "next/link";
import { requireTenant } from "@/lib/tenant";
import { getStorefrontAdmin } from "@/lib/storefront/queries";
import { storefrontCaps } from "@/lib/storefront/model";
import { siteOrigin } from "@/lib/url";
import { formatShopPrice } from "@/lib/shop/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { Badge } from "@/components/ui/badge";
import { FilterBar } from "@/components/ui/filter-bar";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { StorefrontSettingsForm, PublishToggle, FeaturedToggle } from "@/app/app/online-magaza/forms";

export const metadata = { title: "Online Mağaza · BoutiqueOS" };

const PAGE = 50;

/**
 * Online store admin. One catalogue: the merchant picks what the storefront shows and
 * how the store presents itself; the products, prices and stock stay where they are.
 * Owner and manager only — staff see an explanation, never a form.
 */
export default async function OnlineStorePage({ searchParams }: { searchParams: Promise<{ q?: string; sayfa?: string }> }) {
  const { active } = await requireTenant();
  if (!storefrontCaps(active.role).canManage) {
    return (
      <div className="space-y-8">
        <PageHeader title="Online Mağaza" />
        <EmptyState compact title="Bu bölüm sahip ve yöneticilere açıktır" description="Online mağaza ayarları ve yayın kararları işletme sahibi ya da yönetici tarafından verilir." />
      </div>
    );
  }
  const { q, sayfa } = await searchParams;
  const query = (q ?? "").trim().slice(0, 80) || null;
  const page = Math.max(1, Number.parseInt(sayfa ?? "1", 10) || 1);
  const admin = await getStorefrontAdmin(query, (page - 1) * PAGE, PAGE);
  const origin = siteOrigin();
  const sf = admin.storefront;
  const live = Boolean(sf?.enabled);
  const pages = Math.max(1, Math.ceil(admin.total / PAGE));

  return (
    <div className="space-y-8">
      <PageHeader
        title="Online Mağaza"
        description="Kataloğunuz tek: burada yalnız neyin herkese açık görüneceğine ve mağazanın nasıl tanıtılacağına karar verirsiniz. Fiyat ve stok ürünlerden gelir."
        actions={
          sf ? (
            <a href={`${origin}/shop/${sf.slug}`} target="_blank" rel="noopener noreferrer" className="text-sm underline-offset-4 hover:underline">
              {live ? "Mağazayı aç ↗" : "Önizleme kapalı"}
            </a>
          ) : null
        }
      />

      <section className="space-y-3">
        <SectionHeader title="Mağaza ayarları" meta={sf ? (live ? "yayında" : "kapalı") : "henüz kurulmadı"} />
        <StorefrontSettingsForm settings={sf} branches={admin.branches} siteOrigin={origin} />
        <p className="text-xs leading-relaxed text-text-muted">
          Online ödeme ve sipariş bu sürümde yoktur; müşteri sepetini WhatsApp / Instagram ile iletir. Sepet stok ayırmaz. Özel alan adı platform tarafından ileride bağlanır.
        </p>
      </section>

      <section className="space-y-3">
        <SectionHeader title="Ürünler" meta={`${admin.published_count} yayında · ${admin.total} aktif`} />
        <FilterBar clearHref="/app/online-magaza" hasFilter={Boolean(query)} columns={4}>
          <div className="space-y-1.5">
            <Label htmlFor="q">Ürün adı</Label>
            <Input id="q" name="q" defaultValue={query ?? ""} />
          </div>
        </FilterBar>
        {admin.products.length === 0 ? (
          <EmptyState compact title="Aktif ürün yok" description="Yayınlanacak ürün için önce kataloğa ürün ekleyin." />
        ) : (
          <TableShell minWidth="56rem" footer={`${admin.total} ürün`}>
            <THead>
              <TH>Ürün</TH>
              <TH>Kategori</TH>
              <TH align="right">Web fiyatı</TH>
              <TH align="right">Web varyantı</TH>
              <TH align="right">Görsel</TH>
              <TH>Durum</TH>
              <TH>İşlem</TH>
            </THead>
            <TBody>
              {admin.products.map((p) => (
                <TR key={p.id}>
                  <TD>
                    <CellTitle sub={p.web_slug ? `/shop/${sf?.slug ?? "…"}/urun/${p.web_slug}` : "adres yayınlandığında üretilir"}>
                      <Link href={`/app/online-magaza/urun/${p.id}`} className="hover:underline">{p.web_title ?? p.name}</Link>
                    </CellTitle>
                  </TD>
                  <TD muted>{p.category ?? "—"}</TD>
                  <TD align="right" numeric>{p.price_from !== null ? formatShopPrice(p.price_from, admin.currency) : "—"}</TD>
                  <TD align="right" numeric>{p.web_variants} / {p.variants}</TD>
                  <TD align="right" numeric>{p.public_images}</TD>
                  <TD>
                    <span className="flex flex-wrap gap-1">
                      <Badge tone={p.web_published ? "success" : "neutral"}>{p.web_published ? "Yayında" : "Yayında değil"}</Badge>
                      {p.web_featured ? <Badge tone="accent">Öne çıkan</Badge> : null}
                    </span>
                  </TD>
                  <TD>
                    <div className="flex flex-wrap items-center gap-2">
                      <PublishToggle productId={p.id} published={p.web_published} disabled={!sf} />
                      {p.web_published ? <FeaturedToggle productId={p.id} featured={p.web_featured} /> : null}
                    </div>
                  </TD>
                </TR>
              ))}
            </TBody>
          </TableShell>
        )}
        {pages > 1 ? (
          <nav className="flex items-center gap-4 text-xs text-text-muted" aria-label="Sayfalar" data-numeric>
            {page > 1 ? <Link href={`/app/online-magaza?${new URLSearchParams({ ...(query ? { q: query } : {}), sayfa: String(page - 1) })}`} className="underline-offset-4 hover:underline">← Önceki</Link> : <span>← Önceki</span>}
            <span>{page} / {pages}</span>
            {page < pages ? <Link href={`/app/online-magaza?${new URLSearchParams({ ...(query ? { q: query } : {}), sayfa: String(page + 1) })}`} className="underline-offset-4 hover:underline">Sonraki →</Link> : <span>Sonraki →</span>}
          </nav>
        ) : null}
      </section>
    </div>
  );
}
