import * as React from "react";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { fmtInt, fmtMoney, fmtPct } from "@/components/reports/format";
import { METRIC_DEFINITIONS, type DailyPoint, type ProductRow, type StaffRow } from "@/lib/reports/model";
import { formatDayShort } from "@/lib/reports/period";

/** Shared numeric columns of a ranked row (product, variant, category, size, colour, salesperson). */
type RankedRow = Pick<ProductRow | StaffRow, "units" | "transactions" | "net_sales" | "returns_value" | "net_sales_after_returns" | "gross_profit" | "gross_margin_pct"> & {
  returned_units: number;
};

export function RankedTable({
  rows,
  financial,
  header,
  title,
  sub,
  emptyText = "Bu dönemde satış yok.",
  showTransactions = true,
}: {
  rows: RankedRow[];
  financial: boolean;
  header: string;
  title: (row: RankedRow, i: number) => React.ReactNode;
  sub?: (row: RankedRow) => React.ReactNode;
  emptyText?: string;
  showTransactions?: boolean;
}) {
  if (rows.length === 0) return <EmptyState compact title={emptyText} />;
  return (
    <TableShell minWidth={financial ? "52rem" : "36rem"}>
      <THead>
        <TH>{header}</TH>
        <TH align="right">Adet</TH>
        {showTransactions ? <TH align="right">İşlem</TH> : null}
        <TH align="right">Net satış</TH>
        <TH align="right">İade</TH>
        <TH align="right">İade sonrası</TH>
        {financial ? <TH align="right">Brüt kâr</TH> : null}
        {financial ? <TH align="right">Marj</TH> : null}
      </THead>
      <TBody>
        {rows.map((r, i) => (
          <TR key={i}>
            <TD>
              <CellTitle sub={sub?.(r)}>{title(r, i)}</CellTitle>
            </TD>
            <TD align="right" numeric>{fmtInt(r.units)}</TD>
            {showTransactions ? <TD align="right" numeric muted>{fmtInt(r.transactions)}</TD> : null}
            <TD align="right" numeric>{fmtMoney(r.net_sales)}</TD>
            <TD align="right" numeric muted>
              {r.returned_units > 0 ? `${fmtInt(r.returned_units)} · ${fmtMoney(r.returns_value)}` : "—"}
            </TD>
            <TD align="right" numeric>{fmtMoney(r.net_sales_after_returns)}</TD>
            {financial ? <TD align="right" numeric>{fmtMoney(r.gross_profit)}</TD> : null}
            {financial ? <TD align="right" numeric muted>{fmtPct(r.gross_margin_pct)}</TD> : null}
          </TR>
        ))}
      </TBody>
    </TableShell>
  );
}

export function DailyTable({ daily, financial }: { daily: DailyPoint[]; financial: boolean }) {
  if (daily.length === 0) return <EmptyState compact title="Bu dönemde satış ya da iade yok." />;
  return (
    <TableShell minWidth="34rem">
      <THead>
        <TH>Gün</TH>
        <TH align="right">İşlem</TH>
        <TH align="right">Adet</TH>
        <TH align="right">Net satış</TH>
        <TH align="right">İade</TH>
        {financial ? <TH align="right">Brüt kâr</TH> : null}
      </THead>
      <TBody>
        {[...daily].reverse().map((d) => (
          <TR key={d.date}>
            <TD nowrap>{formatDayShort(d.date)}</TD>
            <TD align="right" numeric>{fmtInt(d.transactions)}</TD>
            <TD align="right" numeric>{fmtInt(d.units)}</TD>
            <TD align="right" numeric>{fmtMoney(d.net_sales)}</TD>
            <TD align="right" numeric muted>{d.returns_count > 0 ? `${fmtInt(d.returns_count)} · ${fmtMoney(d.returns_value)}` : "—"}</TD>
            {financial ? <TD align="right" numeric>{fmtMoney(d.gross_profit)}</TD> : null}
          </TR>
        ))}
      </TBody>
    </TableShell>
  );
}

/** The definitions, folded away: a reader who wonders what "net satış" means finds it on the page. */
export function MetricDefinitions({ financial }: { financial: boolean }) {
  return (
    <details className="rounded border border-border bg-background/60 px-4 py-3 text-xs">
      <summary className="cursor-pointer text-text-secondary hover:text-text-primary">Bu rakamlar nasıl hesaplanır?</summary>
      <dl className="mt-3 grid gap-x-6 gap-y-2 sm:grid-cols-2">
        {METRIC_DEFINITIONS.filter((m) => financial || !m.financial).map((m) => (
          <div key={m.key}>
            <dt className="font-medium text-text-primary">{m.label}</dt>
            <dd className="text-text-muted">{m.definition}</dd>
          </div>
        ))}
        <div className="sm:col-span-2">
          <dt className="font-medium text-text-primary">Gün</dt>
          <dd className="text-text-muted">Satış, satışın anına; iade, iadenin anına; mal kabul, işleme anına göre işletme saat dilimindeki takvim gününe yazılır. İptal edilmiş satışlar ve taslak belgeler hiçbir toplama girmez.</dd>
        </div>
      </dl>
    </details>
  );
}
