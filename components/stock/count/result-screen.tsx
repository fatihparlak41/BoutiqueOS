import { Stat, StatGrid } from "@/components/ui/stat";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell } from "@/components/ui/table";
import { Notice } from "@/components/catalog/intake/primitives";
import { COUNT_TYPE_LABELS, formatWhen, lineDifference, summarize, type CountLine, type StockCount } from "@/lib/stock/count-model";
import { ConditionBadge, Difference, VariantIdentity } from "./shared";

/**
 * Posted or cancelled: read-only, forever. A posted count is the record of what was on
 * the shelf and what the ledger was corrected by; a wrong count is answered with a new
 * count, never by editing this one. Cancelled counts keep their scans for audit.
 */
function shownDelta(line: CountLine, posted: boolean): number | null {
  return posted ? line.posted_delta : lineDifference(line);
}

export function ResultScreen({ count }: { count: StockCount }) {
  const s = summarize(count.lines);
  const adjustments = count.lines.filter((l) => (l.posted_delta ?? 0) !== 0).length;
  const posted = count.status === "posted";

  return (
    <div className="space-y-6">
      {posted ? (
        <Notice tone="success">Bu sayım işlendi ve değiştirilemez. Düzeltme gerekiyorsa yeni bir sayım açın.</Notice>
      ) : (
        <Notice tone="info">Bu sayım iptal edildi{count.cancel_reason ? `: ${count.cancel_reason}` : ""}. Stok değişmedi; satırlar kayıt için saklanıyor.</Notice>
      )}

      <dl className="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
        <div className="flex justify-between gap-4 border-b border-border py-2"><dt className="text-text-muted">Sayım</dt><dd data-numeric>{count.count_number}</dd></div>
        <div className="flex justify-between gap-4 border-b border-border py-2"><dt className="text-text-muted">Tür / şube</dt><dd>{COUNT_TYPE_LABELS[count.count_type]} · {count.branch_name}</dd></div>
        <div className="flex justify-between gap-4 border-b border-border py-2"><dt className="text-text-muted">Açan</dt><dd>{count.created_by_name ?? "—"} · <span data-numeric>{formatWhen(count.created_at)}</span></dd></div>
        <div className="flex justify-between gap-4 border-b border-border py-2"><dt className="text-text-muted">İnceleme</dt><dd data-numeric>{formatWhen(count.reviewed_at)}</dd></div>
        {posted ? (
          <div className="flex justify-between gap-4 border-b border-border py-2"><dt className="text-text-muted">İşleyen</dt><dd>{count.posted_by_name ?? "—"} · <span data-numeric>{formatWhen(count.posted_at)}</span></dd></div>
        ) : (
          <div className="flex justify-between gap-4 border-b border-border py-2"><dt className="text-text-muted">İptal</dt><dd data-numeric>{formatWhen(count.cancelled_at)}</dd></div>
        )}
        {count.note ? <div className="flex justify-between gap-4 border-b border-border py-2"><dt className="text-text-muted">Not</dt><dd>{count.note}</dd></div> : null}
      </dl>

      <StatGrid>
        <Stat label="Satır" value={count.lines.length} />
        <Stat label="Düzeltme hareketi" value={posted ? adjustments : 0} />
        <Stat label="Eksik adet" value={s.shortage} />
        <Stat label="Fazla adet" value={s.surplus} />
      </StatGrid>

      <ul className="space-y-2 lg:hidden">
        {count.lines.map((l) => (
          <li key={l.id} className="rounded border border-border bg-surface p-3">
            <VariantIdentity v={l} size="sm" />
            <div className="mt-3 flex items-center justify-between gap-3">
              <ConditionBadge bucket={l.bucket} />
              <dl className="flex items-center gap-4 text-sm">
                <div className="text-center"><dt className="text-2xs text-text-muted">Beklenen</dt><dd data-numeric>{l.expected_quantity ?? "—"}</dd></div>
                <div className="text-center"><dt className="text-2xs text-text-muted">Sayılan</dt><dd data-numeric>{l.counted_quantity ?? "—"}</dd></div>
                <div className="text-center"><dt className="text-2xs text-text-muted">{posted ? "İşlenen" : "Fark"}</dt><dd><Difference value={shownDelta(l, posted)} /></dd></div>
              </dl>
            </div>
          </li>
        ))}
      </ul>
      <div className="hidden lg:block">
        <TableShell minWidth="52rem">
          <THead>
            <TH>Ürün</TH>
            <TH>Varyant</TH>
            <TH>Durum</TH>
            <TH align="right">Beklenen</TH>
            <TH align="right">Sayılan</TH>
            <TH align="right">{posted ? "İşlenen fark" : "Fark"}</TH>
          </THead>
          <TBody>
            {count.lines.map((l) => (
              <TR key={l.id}>
                <TD><CellTitle sub={l.sku}>{l.product_name}</CellTitle></TD>
                <TD>{l.options || "Tek varyant"}</TD>
                <TD><ConditionBadge bucket={l.bucket} /></TD>
                <TD numeric align="right">{l.expected_quantity ?? "—"}</TD>
                <TD numeric align="right">{l.counted_quantity ?? "—"}</TD>
                <TD align="right"><Difference value={shownDelta(l, posted)} /></TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
      </div>
    </div>
  );
}
