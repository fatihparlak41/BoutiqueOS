import { Badge } from "@/components/ui/badge";
import { Card, CardBody } from "@/components/ui/card";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell } from "@/components/ui/table";
import { ColorSwatch } from "@/components/catalog/color-swatch";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { formatPrice } from "@/lib/catalog/format";
import { VARIANT_STATUS_LABELS, type ProductImage, type VariantRow } from "@/lib/catalog/model";
import type { StockRow } from "@/lib/stock/model";
import { formatQuantity } from "@/lib/receiving/format";

/**
 * Operational view of a product's sellable variants: combination, SKU, barcodes, status,
 * stock on the active branch (when the caller could read it) and the variant's own
 * image when one exists. Read-only; editing lives in VariantManager below it.
 *
 * Purchase cost never appears here — it is not in VariantRow to begin with.
 */
function Combination({ variant }: { variant: VariantRow }) {
  if (variant.options.length === 0) return <span className="text-text-muted">Tek varyant</span>;
  return (
    <span className="flex flex-wrap items-center gap-x-2 gap-y-0.5">
      {variant.options.map((o) =>
        o.option_kind === "color" ? (
          <ColorSwatch key={o.value_id} hex={o.color_hex} label={o.value} />
        ) : (
          <span key={o.value_id}>{o.value}</span>
        ),
      )}
    </span>
  );
}

function Codes({ variant }: { variant: VariantRow }) {
  if (variant.barcodes.length === 0) return <span className="text-2xs text-text-muted">barkod yok</span>;
  return (
    <span className="flex flex-col gap-0.5" data-numeric>
      {variant.barcodes.map((b) => (
        <span key={b.id} className={b.is_primary ? "text-text-primary" : "text-text-muted"}>
          {b.barcode}
          {b.is_primary ? "" : " (alternatif)"}
        </span>
      ))}
    </span>
  );
}

export function VariantMatrix({
  variants,
  images,
  stock,
  defaultPrice,
}: {
  variants: VariantRow[];
  images: ProductImage[];
  /** Rows of the stock screen for this product's variants, or null when the role may not read them. */
  stock: StockRow[] | null;
  defaultPrice: number;
}) {
  const imageFor = (variantId: string) => images.find((i) => i.role === "variant" && i.variant_id === variantId) ?? null;
  const stockFor = (variantId: string) => stock?.find((r) => r.variant_id === variantId) ?? null;

  if (variants.length === 0) return null;

  // Fashion order: colour run first, then the size run as the boutique ordered it,
  // never alphabetical SKU order (which would put "L" before "M").
  const sorted = [...variants].sort((a, b) => {
    for (let i = 0; i < Math.max(a.options.length, b.options.length); i++) {
      const oa = a.options[i], ob = b.options[i];
      if (!oa || !ob) return a.options.length - b.options.length;
      if (oa.sort_order !== ob.sort_order) return oa.sort_order - ob.sort_order;
      if (oa.value !== ob.value) return oa.value.localeCompare(ob.value, "tr");
    }
    return a.sku.localeCompare(b.sku, "tr");
  });

  return (
    <>
      <ul className="space-y-2 lg:hidden">
        {sorted.map((v) => {
          const img = imageFor(v.id);
          const st = stockFor(v.id);
          return (
            <li key={v.id}>
              <Card>
                <CardBody className="flex gap-3">
                  {img ? <ProductThumb url={img.url} alt={v.sku} size="md" /> : null}
                  <div className="min-w-0 flex-1">
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0 text-sm font-medium">
                        <Combination variant={v} />
                      </div>
                      <Badge tone={v.status === "active" ? "success" : "quiet"}>{VARIANT_STATUS_LABELS[v.status]}</Badge>
                    </div>
                    <p className="mt-1 text-2xs text-text-muted" data-numeric>{v.sku}</p>
                    <p className="mt-1 text-2xs"><Codes variant={v} /></p>
                    <p className="mt-2 flex flex-wrap gap-x-4 text-xs text-text-secondary" data-numeric>
                      <span>{formatPrice(v.sale_price_override ?? defaultPrice)}</span>
                      {st ? <span>uygun {formatQuantity(st.available)}</span> : null}
                    </p>
                  </div>
                </CardBody>
              </Card>
            </li>
          );
        })}
      </ul>

      <div className="hidden lg:block">
        <TableShell minWidth="52rem">
          <THead>
            <TH>Varyant</TH>
            <TH>SKU</TH>
            <TH>Barkod</TH>
            <TH align="right">Fiyat</TH>
            {stock ? <TH align="right">Uygun</TH> : null}
            <TH>Durum</TH>
          </THead>
          <TBody>
            {sorted.map((v) => {
              const img = imageFor(v.id);
              const st = stockFor(v.id);
              return (
                <TR key={v.id}>
                  <TD>
                    <span className="flex items-center gap-3">
                      {img ? <ProductThumb url={img.url} alt={v.sku} /> : null}
                      <CellTitle>
                        <Combination variant={v} />
                      </CellTitle>
                    </span>
                  </TD>
                  <TD muted numeric nowrap>{v.sku}</TD>
                  <TD muted><Codes variant={v} /></TD>
                  <TD muted numeric align="right" nowrap>
                    {formatPrice(v.sale_price_override ?? defaultPrice)}
                    {v.sale_price_override !== null ? <span className="ml-1 text-2xs text-text-muted">özel</span> : null}
                  </TD>
                  {stock ? (
                    <TD numeric align="right" className="font-medium">{st ? formatQuantity(st.available) : "—"}</TD>
                  ) : null}
                  <TD>
                    <Badge tone={v.status === "active" ? "success" : "quiet"}>{VARIANT_STATUS_LABELS[v.status]}</Badge>
                  </TD>
                </TR>
              );
            })}
          </TBody>
        </TableShell>
      </div>
    </>
  );
}
