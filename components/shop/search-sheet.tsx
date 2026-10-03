"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState } from "react";
import { Search, X } from "lucide-react";
import type { Store } from "@/lib/shop/model";
import { useOverlay } from "@/components/shop/overlay";

/**
 * Customer search: a full-width sheet from the top (full screen on a phone). It submits to
 * the existing public listing (`/urunler?q=`), whose rpc_shop_products matches only the
 * public product name / web title — never a SKU, barcode, internal code, supplier or cost.
 * A plain GET form, so it also works before hydration.
 */
export function SearchSheet({ store, open, onClose }: { store: Store; open: boolean; onClose: () => void }) {
  const router = useRouter();
  const panel = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const [q, setQ] = useState("");
  useOverlay(open, onClose, panel, input);
  if (!open) return null;

  const base = `/shop/${store.slug}`;
  function submit(e: React.FormEvent) {
    e.preventDefault();
    const term = q.trim().slice(0, 60);
    onClose();
    router.push(term ? `${base}/urunler?${new URLSearchParams({ q: term })}` : `${base}/urunler`);
  }

  return (
    <div className="shop-layer" data-testid="shop-search">
      <button type="button" className="shop-scrim" aria-label="Aramayı kapat" tabIndex={-1} onClick={onClose} />
      <div ref={panel} className="shop-sheet" role="dialog" aria-modal="true" aria-label="Ürün ara" tabIndex={-1}>
        <div className="shop-container">
          <form role="search" method="get" action={`${base}/urunler`} onSubmit={submit} className="shop-search-row">
            <Search aria-hidden strokeWidth={1.4} className="shop-search-glyph" />
            <input
              ref={input}
              className="shop-search-input"
              type="search"
              name="q"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              maxLength={60}
              placeholder="Ne arıyorsunuz?"
              aria-label="Ürün ara"
              autoComplete="off"
              enterKeyHint="search"
            />
            <button type="button" className="shop-icon" aria-label="Kapat" onClick={onClose}>
              <X aria-hidden strokeWidth={1.4} />
            </button>
          </form>
          {store.categories.length > 0 ? (
            <nav aria-label="Kategoriler" className="shop-search-cats">
              <p className="shop-kicker">Kategoriler</p>
              <ul>
                {store.categories.map((c) => (
                  <li key={c.slug}><Link href={`${base}/kategori/${c.slug}`} onClick={onClose}>{c.name}</Link></li>
                ))}
              </ul>
            </nav>
          ) : null}
        </div>
      </div>
    </div>
  );
}
