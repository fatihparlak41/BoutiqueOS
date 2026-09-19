"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Archive, ArchiveRestore, ClipboardCheck, MoreHorizontal, Pencil } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { useToast } from "@/components/ui/toast";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { StatusPill } from "@/components/catalog/status-pill";
import { IDLE } from "@/lib/catalog/action-state";
import type { ProductStatus } from "@/lib/catalog/model";
import { archiveProductAction } from "@/app/app/urunler/actions";

/**
 * The product as a boutique sees it: photo, name, price, where it belongs, whether it
 * sells. One primary action ("Stok say"), one secondary ("Ürünü düzenle" — jumps to the
 * edit section), the rest behind ⋯. Archive / restore only through the confirmation.
 */
export function ProductHero({
  productId,
  name,
  price,
  category,
  brand,
  styleCode,
  status,
  imageUrl,
  canEdit,
  canCount,
}: {
  productId: string;
  name: string;
  price: string;
  category: string | null;
  brand: string | null;
  styleCode: string | null;
  status: ProductStatus;
  imageUrl: string | null;
  canEdit: boolean;
  canCount: boolean;
}) {
  const router = useRouter();
  const { toast } = useToast();
  const [menu, setMenu] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [pending, start] = useTransition();
  const archived = status === "archived";

  function toggleArchive() {
    start(async () => {
      const fd = new FormData();
      fd.set("product_id", productId);
      fd.set("status", archived ? "active" : "archived");
      const res = await archiveProductAction(IDLE, fd);
      setConfirm(false);
      if (!res.ok) {
        toast({ tone: "danger", title: archived ? "Arşivden çıkarılamadı" : "Arşivlenemedi", description: res.error ?? undefined });
        return;
      }
      toast({ tone: "success", title: archived ? "Ürün yeniden satışta." : "Ürün arşivlendi.", description: archived ? undefined : "Satış ekranlarından kaldırıldı; geçmiş ve kalan stok duruyor." });
      router.refresh();
    });
  }

  return (
    <header className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between" data-testid="product-hero">
      <div className="flex min-w-0 items-start gap-4">
        <ProductThumb url={imageUrl} alt={name} size="lg" className="h-24 w-24 sm:h-32 sm:w-32" />
        <div className="min-w-0">
          <h1 className="text-xl font-medium leading-tight tracking-tightish text-text-primary sm:text-2xl">{name}</h1>
          <p className="mt-1 text-lg font-medium text-text-primary" data-numeric>{price}</p>
          <p className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-text-secondary">
            <span>{category ?? "Kategorisiz"}</span>
            {brand ? <><span className="text-text-muted">·</span><span>{brand}</span></> : null}
            {styleCode ? <><span className="text-text-muted">·</span><span data-numeric className="text-xs text-text-muted">Model {styleCode}</span></> : null}
            <StatusPill status={status} />
          </p>
        </div>
      </div>

      <div className="flex shrink-0 items-center gap-2">
        {canCount && !archived ? (
          <Link href="/app/stok/sayim" data-testid="product-primary-count">
            <Button variant="accent">
              <ClipboardCheck aria-hidden className="h-4 w-4" />
              Stok say
            </Button>
          </Link>
        ) : null}
        {canEdit ? (
          <a href="#duzenle">
            <Button variant="outline">
              <Pencil aria-hidden className="h-4 w-4" />
              Ürünü düzenle
            </Button>
          </a>
        ) : null}
        {canEdit ? (
          <div className="relative">
            <button
              type="button"
              aria-label="Diğer işlemler"
              aria-haspopup="menu"
              aria-expanded={menu}
              onClick={() => setMenu((v) => !v)}
              onBlur={(e) => {
                if (!e.currentTarget.parentElement?.contains(e.relatedTarget as Node)) setMenu(false);
              }}
              className="inline-flex h-11 w-11 items-center justify-center rounded border border-border-strong bg-surface text-text-muted hover:bg-surface-muted hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:h-10 sm:w-10"
              data-testid="product-menu"
            >
              <MoreHorizontal aria-hidden className="h-4 w-4" />
            </button>
            {menu ? (
              <ul role="menu" className="absolute right-0 z-20 mt-1 w-52 rounded border border-border bg-surface py-1 text-sm shadow-md">
                <li role="none">
                  <Link role="menuitem" href={`/app/stok?q=${encodeURIComponent(name)}`} onClick={() => setMenu(false)} className="flex min-h-10 items-center px-3 hover:bg-surface-muted">
                    Stok hareketleri
                  </Link>
                </li>
                <li role="none">
                  <button
                    role="menuitem"
                    type="button"
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => {
                      setMenu(false);
                      setConfirm(true);
                    }}
                    className={`flex min-h-10 w-full items-center gap-2 px-3 text-left hover:bg-surface-muted ${archived ? "" : "text-danger"}`}
                    data-testid="product-archive"
                  >
                    {archived ? <ArchiveRestore aria-hidden className="h-4 w-4" /> : <Archive aria-hidden className="h-4 w-4" />}
                    {archived ? "Arşivden çıkar" : "Arşivle"}
                  </button>
                </li>
              </ul>
            ) : null}
          </div>
        ) : null}
      </div>

      <ConfirmDialog
        open={confirm}
        onClose={() => (pending ? undefined : setConfirm(false))}
        title={archived ? "Bu ürün yeniden satışa açılsın mı?" : "Bu ürünü arşivlemek istiyor musun?"}
        description={archived ? "Ürün ve seçenekleri satış ekranlarında yeniden görünür." : "Ürün satış ekranlarından kaldırılır. Geçmiş kayıtlar ve kalan stok korunur."}
        confirmLabel={archived ? "Satışa aç" : "Arşivle"}
        destructive={!archived}
        busy={pending}
        onConfirm={toggleArchive}
      />
    </header>
  );
}
