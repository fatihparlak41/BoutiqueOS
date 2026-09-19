import Link from "next/link";
import { Badge } from "@/components/ui/badge";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell, rowLinkClass } from "@/components/ui/table";
import { formatQuantity } from "@/lib/receiving/format";
import type { StockRow } from "@/lib/stock/model";
import { cn } from "@/lib/utils";

/**
 * "Neyden kaç tane var?" — the stock list in a shop's words. Three numbers matter on
 * the floor: Rafta (everything on hand), Ayrılmış (held for a customer) and Satılabilir
 * (what can be sold now). Damaged / quarantine appear only when they are not zero.
 *
 * Phone: one compact row per colour · size, the sellable number first; details unfold
 * on the variant page. Desktop: a table with the same three numbers up front.
 */
function Identity({ row }: { row: StockRow }) {
  return (
    <CellTitle sub={row.options === "Seçeneksiz" ? "Tek seçenek" : row.options}>
      <Link href={`/app/stok/${row.variant_id}`} className={rowLinkClass}>
        {row.product_name}
      </Link>
      {row.product_status === "archived" ? <Badge tone="quiet" className="ml-2 align-middle">Arşivde</Badge> : null}
    </CellTitle>
  );
}

function Extras({ row, compact = false }: { row: StockRow; compact?: boolean }) {
  if (row.quarantine === 0 && row.damaged === 0) return null;
  return (
    <span className={cn("flex flex-wrap gap-1.5", compact ? "mt-1.5" : "")}>
      {row.quarantine > 0 ? <Badge tone="warning">Karantina <span data-numeric>{formatQuantity(row.quarantine)}</span></Badge> : null}
      {row.damaged > 0 ? <Badge tone="danger">Hasarlı <span data-numeric>{formatQuantity(row.damaged)}</span></Badge> : null}
    </span>
  );
}

export function StockCards({ rows }: { rows: StockRow[] }) {
  return (
    <ul className="divide-y divide-border border-y border-border lg:hidden" data-testid="stock-cards">
      {rows.map((row) => (
        <li key={row.variant_id} className="py-3">
          <Link href={`/app/stok/${row.variant_id}`} className="flex items-center gap-3 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-medium text-text-primary">
                {row.product_name}
                {row.product_status === "archived" ? <Badge tone="quiet" className="ml-2 align-middle">Arşivde</Badge> : null}
              </span>
              <span className="mt-0.5 block truncate text-xs text-text-secondary">{row.options === "Seçeneksiz" ? "Tek seçenek" : row.options}</span>
              {row.reserved > 0 ? <span className="mt-0.5 block text-2xs text-text-muted" data-numeric>Ayrılmış {formatQuantity(row.reserved)} · Rafta {formatQuantity(row.on_hand)}</span> : null}
              <Extras row={row} compact />
            </span>
            <span className="shrink-0 text-right">
              <span className={cn("block text-2xl font-medium leading-none", row.available > 0 ? "text-text-primary" : "text-warning")} data-numeric>{formatQuantity(row.available)}</span>
              <span className="mt-1 block text-2xs text-text-muted">satılabilir</span>
            </span>
          </Link>
        </li>
      ))}
    </ul>
  );
}

export function StockTable({ rows }: { rows: StockRow[] }) {
  return (
    <div className="hidden lg:block" data-testid="stock-table">
      <TableShell minWidth="52rem">
        <THead>
          <TH>Ürün</TH>
          <TH>Barkod</TH>
          <TH align="right">Rafta</TH>
          <TH align="right">Ayrılmış</TH>
          <TH align="right">Satılabilir</TH>
          <TH>Durum</TH>
        </THead>
        <TBody>
          {rows.map((row) => (
            <TR key={row.variant_id}>
              <TD><Identity row={row} /></TD>
              <TD muted numeric>{row.primary_barcode ?? <span className="text-text-muted">—</span>}</TD>
              <TD numeric align="right">{formatQuantity(row.on_hand)}</TD>
              <TD muted numeric align="right">{formatQuantity(row.reserved)}</TD>
              <TD numeric align="right" className={cn("font-medium", row.available <= 0 && "text-warning")}>{formatQuantity(row.available)}</TD>
              <TD><Extras row={row} /></TD>
            </TR>
          ))}
        </TBody>
      </TableShell>
    </div>
  );
}
