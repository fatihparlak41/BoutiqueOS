"use client";

import { useState } from "react";
import Link from "next/link";
import { Search, SlidersHorizontal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Sheet } from "@/components/ui/sheet";
import { PRODUCT_STATUS_LABELS, type NamedRef } from "@/lib/catalog/model";

/**
 * Search first, filters second: a single search field with a "Filtre" button; the
 * category / brand / status selects live in a side sheet. Plain GET forms — the page
 * owns the params and the query, nothing here talks to the database.
 */
export function ProductFilters({
  search,
  categoryId,
  brandId,
  status,
  categories,
  brands,
}: {
  search: string;
  categoryId: string;
  brandId: string;
  status: string;
  categories: NamedRef[];
  brands: NamedRef[];
}) {
  const [open, setOpen] = useState(false);
  const activeCount = [categoryId, brandId, status].filter(Boolean).length;

  return (
    <div className="flex items-center gap-2">
      <form method="get" className="relative min-w-0 flex-1">
        <Search aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 stroke-[1.5] text-text-muted" />
        <label htmlFor="q" className="sr-only">Ürün ara</label>
        <Input id="q" name="q" defaultValue={search} placeholder="Ürün adı, model kodu ya da barkod" spellCheck={false} enterKeyHint="search" className="h-11 pl-9 text-base sm:h-10 sm:text-sm" />
        {categoryId ? <input type="hidden" name="kategori" value={categoryId} /> : null}
        {brandId ? <input type="hidden" name="marka" value={brandId} /> : null}
        {status ? <input type="hidden" name="durum" value={status} /> : null}
      </form>
      <Button type="button" variant="outline" onClick={() => setOpen(true)} aria-haspopup="dialog" className="shrink-0" data-testid="filter-button">
        <SlidersHorizontal aria-hidden className="h-4 w-4" />
        Filtre{activeCount > 0 ? <span className="ml-1 rounded-full bg-accent px-1.5 text-2xs text-accent-foreground" data-numeric>{activeCount}</span> : null}
      </Button>

      <Sheet open={open} onClose={() => setOpen(false)} title="Filtrele" side="right" className="w-[min(22rem,92vw)]">
        <form method="get" className="space-y-4 p-4">
          {search ? <input type="hidden" name="q" value={search} /> : null}
          <div className="space-y-1.5">
            <Label htmlFor="f-kategori">Kategori</Label>
            <Select id="f-kategori" name="kategori" defaultValue={categoryId} className="h-11 sm:h-10">
              <option value="">Tümü</option>
              {categories.map((c) => (
                <option key={c.id} value={c.id}>{c.name}</option>
              ))}
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="f-marka">Marka</Label>
            <Select id="f-marka" name="marka" defaultValue={brandId} className="h-11 sm:h-10">
              <option value="">Tümü</option>
              {brands.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="f-durum">Durum</Label>
            <Select id="f-durum" name="durum" defaultValue={status} className="h-11 sm:h-10">
              <option value="">Tümü</option>
              {Object.entries(PRODUCT_STATUS_LABELS).map(([value, label]) => (
                <option key={value} value={value}>{label}</option>
              ))}
            </Select>
          </div>
          <div className="flex items-center justify-between gap-2 pt-2">
            <Link href="/app/urunler" className="text-xs text-text-muted underline-offset-4 hover:underline">Temizle</Link>
            <Button type="submit">Uygula</Button>
          </div>
        </form>
      </Sheet>
    </div>
  );
}
