import Link from "next/link";
import { requireTenant } from "@/lib/tenant";
import { listProducts } from "@/lib/catalog/queries";
import { catalogCaps } from "@/lib/catalog/model";
import { listStock } from "@/lib/stock/queries";
import { listReceipts } from "@/lib/receiving/queries";
import { receivingCaps } from "@/lib/receiving/model";
import { formatDate, formatQuantity } from "@/lib/receiving/format";
import { Button } from "@/components/ui/button";
import { Stat, StatGrid } from "@/components/ui/stat";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { ReceiptStatusPill } from "@/components/receiving/receipt-status-pill";
import { TBody, TD, TH, THead, TR, TableShell, rowLinkClass } from "@/components/ui/table";

/**
 * Landing screen after sign-in.
 *
 * The business, branch and role already sit in the shell, so this screen answers "what
 * is the state of the shop right now" with numbers the existing read queries already
 * produce — nothing is invented and nothing is charted. What a role may not read is not
 * summarised for it: receiving numbers appear only for procurement roles, exactly as the
 * receiving screen itself does.
 */
const LIST_CAP = 200;

function countLabel(n: number): string {
  return n >= LIST_CAP ? `${LIST_CAP}+` : String(n);
}

function greeting(): string {
  const hour = Number(
    new Intl.DateTimeFormat("tr-TR", { hour: "numeric", hour12: false, timeZone: "Europe/Istanbul" }).format(new Date()),
  );
  if (hour < 6) return "İyi geceler";
  if (hour < 12) return "Günaydın";
  if (hour < 18) return "İyi günler";
  return "İyi akşamlar";
}

export default async function AppHomePage() {
  const { profile, user, active, branch } = await requireTenant();
  const catalog = catalogCaps(active.role);
  const receiving = receivingCaps(active.role);

  const [products, stock, receipts] = await Promise.all([
    listProducts({}),
    listStock({}),
    receiving.canRead ? listReceipts({}) : Promise.resolve([]),
  ]);

  const name = profile.full_name?.trim() || user.email?.split("@")[0] || "";
  const activeProducts = products.filter((p) => p.status === "active").length;
  const available = stock.filter((r) => r.available > 0).length;
  const outOfStock = stock.filter((r) => r.available <= 0).length;
  const drafts = receipts.filter((r) => r.status === "draft");
  const recent = receipts.slice(0, 5);
  const firstUse = products.length === 0 && stock.length === 0 && receipts.length === 0;

  return (
    <div className="space-y-10">
      <header>
        <p className="text-sm text-text-muted">
          {greeting()}
          {name ? `, ${name}` : ""}
        </p>
        <h1 className="mt-1 font-serif text-4xl font-medium leading-none tracking-tightish text-text-primary">
          {active.business_name}
        </h1>
        <p className="mt-3 max-w-prose text-sm leading-relaxed text-text-muted">
          {branch ? `${branch.name} için bugünkü durum.` : "Bugünkü durum."} Stok yalnız işlenmiş mal kabul
          belgeleriyle oluşur; hiçbir ekranda elle stok girişi yoktur.
        </p>
      </header>

      {firstUse ? (
        <EmptyState
          editorial
          title="Mağaza henüz boş"
          description={
            catalog.canEditCatalog
              ? "İlk ürünü tanımlayın; varyantlar ve barkodlar üründen sonra gelir, stok ise ilk mal kabulle."
              : "Ürün ve stok, işletme sahibi ya da yönetici ilk kayıtları girdiğinde burada görünecek."
          }
          action={
            catalog.canEditCatalog ? (
              <Link href="/app/urunler/yeni">
                <Button>İlk ürünü ekle</Button>
              </Link>
            ) : undefined
          }
        />
      ) : (
        <section className="space-y-3">
          <SectionHeader title="Özet" />
          <StatGrid>
            <Stat label="Aktif ürün" value={countLabel(activeProducts)} hint={`${countLabel(products.length)} ürün toplam`} href="/app/urunler" />
            <Stat label="Stokta varyant" value={countLabel(available)} hint="uygun adedi sıfırdan büyük" href="/app/stok" />
            <Stat label="Tükenen varyant" value={countLabel(outOfStock)} hint="uygun adedi sıfır" href="/app/stok?durum=out_of_stock" />
            {receiving.canRead ? (
              <Stat label="Taslak mal kabul" value={countLabel(drafts.length)} hint="stoğu henüz etkilemiyor" href="/app/mal-kabul?durum=draft" />
            ) : null}
          </StatGrid>
        </section>
      )}

      {receiving.canRead && recent.length > 0 ? (
        <section className="space-y-3">
          <SectionHeader
            title="Son mal kabuller"
            action={
              <Link href="/app/mal-kabul" className="text-text-muted underline-offset-4 hover:text-text-primary hover:underline">
                Tümünü gör
              </Link>
            }
          />
          <TableShell minWidth="40rem">
            <THead>
              <TH>Belge</TH>
              <TH>Tarih</TH>
              <TH>Tedarikçi</TH>
              <TH align="right">Adet</TH>
              <TH>Durum</TH>
            </THead>
            <TBody>
              {recent.map((receipt) => (
                <TR key={receipt.id}>
                  <TD>
                    <Link href={`/app/mal-kabul/${receipt.id}`} className={rowLinkClass} data-numeric>
                      {receipt.receipt_number}
                    </Link>
                  </TD>
                  <TD muted numeric nowrap>{formatDate(receipt.received_at)}</TD>
                  <TD muted>{receipt.supplier_name}</TD>
                  <TD muted numeric align="right">{formatQuantity(receipt.total_quantity)}</TD>
                  <TD><ReceiptStatusPill status={receipt.status} /></TD>
                </TR>
              ))}
            </TBody>
          </TableShell>
        </section>
      ) : null}

      <section className="space-y-3">
        <SectionHeader title="Sık kullanılan" />
        <ul className="grid gap-2 sm:grid-cols-2">
          {[
            { href: "/app/stok", title: "Stok sorgula", body: "Hangi bedenden kaç adet kaldığını ve hareket geçmişini görün." },
            { href: "/app/urunler", title: "Ürünler", body: "Modeller, varyantlar, SKU ve barkodlar." },
            ...(receiving.canWriteReceipt
              ? [{ href: "/app/mal-kabul/yeni", title: "Yeni mal kabul", body: "Tedarikçiden gelen ürünleri belgeye girip stoğa alın." }]
              : []),
            ...(receiving.canRead
              ? [{ href: "/app/tedarikciler", title: "Tedarikçiler", body: "Mal kabul belgelerinin bağlanacağı tedarikçiler." }]
              : []),
          ].map(({ href, title, body }) => (
            <li key={href}>
              <Link
                href={href}
                className="flex h-full flex-col rounded border border-border bg-surface px-4 py-3 transition-colors hover:border-border-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              >
                <span className="text-sm font-medium text-text-primary">{title}</span>
                <span className="mt-1 text-xs leading-relaxed text-text-muted">{body}</span>
              </Link>
            </li>
          ))}
        </ul>
        <p className="text-2xs leading-relaxed text-text-muted">
          Kasa, satış, müşteriler, rezervasyonlar ve raporlar henüz açılmadı.
        </p>
      </section>

    </div>
  );
}
