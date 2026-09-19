"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Archive, ArchiveRestore, ExternalLink, MoreHorizontal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { useToast } from "@/components/ui/toast";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell, rowLinkClass } from "@/components/ui/table";
import { StatusPill } from "@/components/catalog/status-pill";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { formatPrice, formatPriceRange } from "@/lib/catalog/format";
import type { ProductListRow } from "@/lib/catalog/model";
import { IDLE } from "@/lib/catalog/action-state";
import { archiveProductAction } from "@/app/app/urunler/actions";
import { cn } from "@/lib/utils";

/**
 * The product list, two presentations of the same rows: cards on a phone (image, name,
 * price, stock, status only when it is not "active"), a table from lg up. A tap on a row
 * opens the product. Everything else — open in a new tab, archive, restore — lives
 * behind the row's ⋯ menu, and archiving always passes through a confirmation.
 */
function priceOf(p: ProductListRow): string {
  return p.variant_count === 0 || p.price_min === null ? formatPrice(p.default_sale_price) : formatPriceRange(p.price_min, p.price_max);
}

function stockOf(p: ProductListRow): { text: string; tone: "ok" | "zero" | "none" } {
  if (p.available_total === null) return { text: `${p.variant_count} seçenek`, tone: "none" };
  if (p.available_total <= 0) return { text: "Stok yok", tone: "zero" };
  return { text: `Stokta ${p.available_total}`, tone: "ok" };
}

function RowMenu({ product, canEdit, onArchive }: { product: ProductListRow; canEdit: boolean; onArchive: (p: ProductListRow) => void }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="relative" onClick={(e) => e.stopPropagation()}>
      <button
        type="button"
        aria-label={`${product.name} işlemleri`}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
        onBlur={(e) => {
          if (!e.currentTarget.parentElement?.contains(e.relatedTarget as Node)) setOpen(false);
        }}
        className="inline-flex h-11 w-11 items-center justify-center rounded text-text-muted hover:bg-surface-muted hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring lg:h-9 lg:w-9"
        data-testid="row-menu"
      >
        <MoreHorizontal aria-hidden className="h-4 w-4" />
      </button>
      {open ? (
        <ul role="menu" className="absolute right-0 z-20 mt-1 w-48 rounded border border-border bg-surface py-1 text-sm shadow-md">
          <li role="none">
            <Link role="menuitem" href={`/app/urunler/${product.id}`} onClick={() => setOpen(false)} className="flex min-h-10 items-center gap-2 px-3 hover:bg-surface-muted">
              <ExternalLink aria-hidden className="h-4 w-4 text-text-muted" /> Ürünü aç
            </Link>
          </li>
          {canEdit ? (
            <li role="none">
              <button
                role="menuitem"
                type="button"
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => {
                  setOpen(false);
                  onArchive(product);
                }}
                className={cn("flex min-h-10 w-full items-center gap-2 px-3 text-left hover:bg-surface-muted", product.status === "archived" ? "" : "text-danger")}
                data-testid="row-archive"
              >
                {product.status === "archived" ? <ArchiveRestore aria-hidden className="h-4 w-4" /> : <Archive aria-hidden className="h-4 w-4" />}
                {product.status === "archived" ? "Arşivden çıkar" : "Arşivle"}
              </button>
            </li>
          ) : null}
        </ul>
      ) : null}
    </div>
  );
}

export function ProductList({ products, canEdit, footer }: { products: ProductListRow[]; canEdit: boolean; footer: string }) {
  const router = useRouter();
  const { toast } = useToast();
  const [pending, start] = useTransition();
  const [target, setTarget] = useState<ProductListRow | null>(null);

  function confirm() {
    if (!target) return;
    const product = target;
    const restore = product.status === "archived";
    start(async () => {
      const fd = new FormData();
      fd.set("product_id", product.id);
      fd.set("status", restore ? "active" : "archived");
      const res = await archiveProductAction(IDLE, fd);
      setTarget(null);
      if (!res.ok) {
        toast({ tone: "danger", title: restore ? "Arşivden çıkarılamadı" : "Arşivlenemedi", description: res.error ?? undefined });
        return;
      }
      toast({
        tone: "success",
        title: restore ? `${product.name} yeniden satışta.` : `${product.name} arşivlendi.`,
        description: restore ? undefined : "Satış ekranlarından kaldırıldı; geçmiş kayıtlar duruyor.",
        action: { label: "Ürünü aç", href: `/app/urunler/${product.id}` },
      });
      router.refresh();
    });
  }

  return (
    <>
      {/* phone / tablet: cards */}
      <ul className="divide-y divide-border border-y border-border lg:hidden" data-testid="product-cards">
        {products.map((p) => {
          const stock = stockOf(p);
          return (
            <li key={p.id} className="flex items-center gap-3 py-3">
              <Link href={`/app/urunler/${p.id}`} className="flex min-w-0 flex-1 items-center gap-3 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
                <ProductThumb url={p.thumbnail_url} alt={p.name} size="md" />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium text-text-primary">{p.name}</span>
                  <span className="mt-0.5 flex flex-wrap items-center gap-x-2 text-xs text-text-secondary">
                    <span data-numeric className="font-medium text-text-primary">{priceOf(p)}</span>
                    <span className={cn(stock.tone === "zero" ? "text-warning" : "text-text-muted")} data-numeric>{stock.text}</span>
                    {p.category ? <span className="text-text-muted">{p.category.name}</span> : null}
                  </span>
                  {p.status !== "active" ? <span className="mt-1 inline-block"><StatusPill status={p.status} /></span> : null}
                </span>
              </Link>
              <RowMenu product={p} canEdit={canEdit} onArchive={setTarget} />
            </li>
          );
        })}
      </ul>
      <p className="text-2xs text-text-muted lg:hidden" data-numeric>{footer}</p>

      {/* desktop: table */}
      <div className="hidden lg:block" data-testid="product-table">
        <TableShell minWidth="40rem" footer={footer}>
          <THead>
            <TH>Ürün</TH>
            <TH>Kategori</TH>
            <TH align="right">Fiyat</TH>
            <TH align="right">Stok</TH>
            <TH>Durum</TH>
            <TH></TH>
          </THead>
          <TBody>
            {products.map((p) => {
              const stock = stockOf(p);
              return (
                <TR key={p.id}>
                  <TD>
                    <span className="flex items-center gap-3">
                      <ProductThumb url={p.thumbnail_url} alt={p.name} />
                      <CellTitle sub={p.style_code ?? undefined} subNumeric>
                        <Link href={`/app/urunler/${p.id}`} className={rowLinkClass}>
                          {p.name}
                        </Link>
                      </CellTitle>
                    </span>
                  </TD>
                  <TD muted>{p.category?.name ?? "—"}</TD>
                  <TD numeric align="right">{priceOf(p)}</TD>
                  <TD numeric align="right" className={stock.tone === "zero" ? "text-warning" : "text-text-secondary"}>{stock.text}</TD>
                  <TD>{p.status !== "active" ? <StatusPill status={p.status} /> : <span className="text-xs text-text-muted">Satışta</span>}</TD>
                  <TD align="right"><RowMenu product={p} canEdit={canEdit} onArchive={setTarget} /></TD>
                </TR>
              );
            })}
          </TBody>
        </TableShell>
      </div>

      <ConfirmDialog
        open={target !== null}
        onClose={() => (pending ? undefined : setTarget(null))}
        title={target?.status === "archived" ? "Bu ürün yeniden satışa açılsın mı?" : "Bu ürünü arşivlemek istiyor musun?"}
        description={target?.status === "archived" ? "Ürün ve seçenekleri satış ekranlarında yeniden görünür." : "Ürün satış ekranlarından kaldırılır. Geçmiş kayıtlar korunur."}
        confirmLabel={target?.status === "archived" ? "Satışa aç" : "Arşivle"}
        destructive={target?.status !== "archived"}
        busy={pending}
        onConfirm={confirm}
      >
        {target ? (
          <div className="flex items-center gap-3 rounded border border-border bg-surface-muted/40 p-2">
            <ProductThumb url={target.thumbnail_url} alt={target.name} />
            <span className="min-w-0">
              <span className="block truncate text-sm font-medium">{target.name}</span>
              <span className="text-xs text-text-muted" data-numeric>{priceOf(target)} · {stockOf(target).text}</span>
            </span>
          </div>
        ) : null}
      </ConfirmDialog>
    </>
  );
}
