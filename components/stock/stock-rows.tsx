import Link from "next/link";
import { formatQuantity } from "@/lib/receiving/format";
import { BUCKET_LABELS, type StockRow } from "@/lib/stock/model";
import { Badge } from "@/components/ui/badge";
import { Card, CardBody } from "@/components/ui/card";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell, rowLinkClass } from "@/components/ui/table";

/**
 * Two presentations of one array. The page fetches `rows` once and hands the same data to
 * both; nothing is queried or recomputed here.
 *
 * A 62rem table is fine at a desk and useless on a phone — checking "do we have an M?"
 * should not start with a sideways scroll. Below lg the rows become cards that lead with
 * the number a salesperson acts on (uygun), and quarantine/damaged appear only when they
 * are not zero, so the common case stays quiet.
 */

function Metric({ label, value, strong }: { label: string; value: number; strong?: boolean }) {
  return (
    <div>
      <dt className="text-2xs text-text-muted">{label}</dt>
      <dd className={strong ? "text-lg font-medium text-text-primary" : "text-sm text-text-secondary"} data-numeric>
        {formatQuantity(value)}
      </dd>
    </div>
  );
}

function Identity({ row }: { row: StockRow }) {
  return (
    <CellTitle sub={row.options}>
      <Link href={`/app/stok/${row.variant_id}`} className={rowLinkClass}>
        {row.product_name}
      </Link>
    </CellTitle>
  );
}

export function StockCards({ rows }: { rows: StockRow[] }) {
  return (
    <ul className="space-y-2 lg:hidden">
      {rows.map((row) => (
        <li key={row.variant_id}>
          <Card>
            <CardBody>
              <Identity row={row} />
              <p className="mt-1 text-2xs text-text-muted" data-numeric>
                {row.sku}
                {row.primary_barcode ? `  ${row.primary_barcode}` : ""}
              </p>

              <dl className="mt-3 grid grid-cols-4 gap-3 border-t border-border pt-3">
                <Metric label="Uygun" value={row.available} strong />
                <Metric label={BUCKET_LABELS.sellable} value={row.sellable} />
                <Metric label="Rezerve" value={row.reserved} />
                <Metric label="Toplam" value={row.on_hand} />
              </dl>

              {row.quarantine > 0 || row.damaged > 0 ? (
                <p className="mt-3 flex flex-wrap gap-2 border-t border-border pt-3">
                  {row.quarantine > 0 ? (
                    <Badge tone="warning">
                      {BUCKET_LABELS.quarantine} <span data-numeric>{formatQuantity(row.quarantine)}</span>
                    </Badge>
                  ) : null}
                  {row.damaged > 0 ? (
                    <Badge tone="danger">
                      {BUCKET_LABELS.damaged} <span data-numeric>{formatQuantity(row.damaged)}</span>
                    </Badge>
                  ) : null}
                </p>
              ) : null}
            </CardBody>
          </Card>
        </li>
      ))}
    </ul>
  );
}

export function StockTable({ rows }: { rows: StockRow[] }) {
  return (
    <div className="hidden lg:block">
      <TableShell minWidth="62rem">
        <THead>
          <TH>Ürün / varyant</TH>
          <TH>SKU / barkod</TH>
          <TH align="right">{BUCKET_LABELS.sellable}</TH>
          <TH align="right">{BUCKET_LABELS.quarantine}</TH>
          <TH align="right">{BUCKET_LABELS.damaged}</TH>
          <TH align="right">Toplam</TH>
          <TH align="right">Rezerve</TH>
          <TH align="right">Uygun</TH>
        </THead>
        <TBody>
          {rows.map((row) => (
            <TR key={row.variant_id}>
              <TD>
                <Identity row={row} />
              </TD>
              <TD muted numeric>
                {row.sku}
                {row.primary_barcode ? (
                  <span className="mt-0.5 block text-2xs text-text-muted">{row.primary_barcode}</span>
                ) : null}
              </TD>
              <TD muted numeric align="right">{formatQuantity(row.sellable)}</TD>
              <TD muted numeric align="right">{formatQuantity(row.quarantine)}</TD>
              <TD muted numeric align="right">{formatQuantity(row.damaged)}</TD>
              <TD numeric align="right" className="font-medium">{formatQuantity(row.on_hand)}</TD>
              <TD muted numeric align="right">{formatQuantity(row.reserved)}</TD>
              <TD numeric align="right" className="font-medium">{formatQuantity(row.available)}</TD>
            </TR>
          ))}
        </TBody>
      </TableShell>
    </div>
  );
}
