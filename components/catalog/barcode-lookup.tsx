import Link from "next/link";
import { ScanLine } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { VARIANT_STATUS_LABELS } from "@/lib/catalog/model";
import type { BarcodeHit } from "@/lib/catalog/queries";

/**
 * Scan / type a code, land on the variant. A GET form so a handheld scanner that
 * "types" a code followed by Enter works without any script; the server resolves it
 * through rpc_resolve_barcode, which never reads outside the caller's business.
 */
export function BarcodeLookup({ code, hit }: { code: string; hit: BarcodeHit | null }) {
  return (
    <div className="space-y-2">
      <form method="get" className="flex items-center gap-2">
        <label htmlFor="barkod" className="sr-only">Barkod veya SKU</label>
        <div className="relative w-full max-w-sm">
          <ScanLine aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 stroke-[1.5] text-text-muted" />
          <Input
            id="barkod"
            name="barkod"
            defaultValue={code}
            placeholder="Barkod okutun veya SKU yazın"
            className="pl-9 font-mono"
            inputMode="text"
            autoComplete="off"
            spellCheck={false}
          />
        </div>
        <Button type="submit" size="sm" variant="outline">
          Bul
        </Button>
      </form>

      {code ? (
        hit ? (
          <p className="flex flex-wrap items-center gap-2 rounded border border-success/25 bg-success-muted px-3 py-2 text-sm">
            <Link href={`/app/urunler/${hit.product_id}`} className="font-medium underline-offset-4 hover:underline">
              {hit.product_name}
            </Link>
            <span className="text-text-secondary" data-numeric>{hit.sku}</span>
            <Badge tone={hit.variant_status === "active" ? "success" : "quiet"}>{VARIANT_STATUS_LABELS[hit.variant_status]}</Badge>
            <span className="text-2xs text-text-muted">{hit.matched_by === "barcode" ? "barkodla eşleşti" : "SKU ile eşleşti"}</span>
          </p>
        ) : (
          <p className="rounded border border-border bg-surface-muted/50 px-3 py-2 text-sm text-text-secondary">
            <span data-numeric>{code}</span> bu işletmede hiçbir barkod ya da SKU ile eşleşmiyor.
          </p>
        )
      ) : null}
    </div>
  );
}
