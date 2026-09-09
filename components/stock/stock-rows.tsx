import Link from "next/link";
import { formatQuantity } from "@/lib/receiving/format";
import { BUCKET_LABELS, type StockRow } from "@/lib/stock/model";

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
      <dt className="text-2xs text-muted">{label}</dt>
      <dd className={strong ? "text-base font-medium" : "text-sm text-ink-70"} data-numeric>
        {formatQuantity(value)}
      </dd>
    </div>
  );
}

function Identity({ row }: { row: StockRow }) {
  return (
    <>
      <Link
        href={`/app/stok/${row.variant_id}`}
        className="font-medium text-ink underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
      >
        {row.product_name}
      </Link>
      <span className="mt-0.5 block text-2xs text-muted">{row.options}</span>
    </>
  );
}

export function StockCards({ rows }: { rows: StockRow[] }) {
  return (
    <ul className="space-y-3 lg:hidden">
      {rows.map((row) => (
        <li key={row.variant_id} className="border border-line p-4">
          <Identity row={row} />
          <p className="mt-1 text-2xs text-muted" data-numeric>
            {row.sku}
            {row.primary_barcode ? ` · ${row.primary_barcode}` : ""}
          </p>

          <dl className="mt-3 grid grid-cols-4 gap-3 border-t border-line pt-3">
            <Metric label="Uygun" value={row.available} strong />
            <Metric label={BUCKET_LABELS.sellable} value={row.sellable} />
            <Metric label="Rezerve" value={row.reserved} />
            <Metric label="Toplam" value={row.on_hand} />
          </dl>

          {row.quarantine > 0 || row.damaged > 0 ? (
            <p className="mt-3 flex flex-wrap gap-2 border-t border-line pt-3 text-2xs">
              {row.quarantine > 0 ? (
                <span className="rounded-sm border border-line-strong bg-panel px-1.5 py-0.5 text-ink-70">
                  {BUCKET_LABELS.quarantine} <span data-numeric>{formatQuantity(row.quarantine)}</span>
                </span>
              ) : null}
              {row.damaged > 0 ? (
                <span className="rounded-sm border border-danger/30 bg-panel px-1.5 py-0.5 text-danger">
                  {BUCKET_LABELS.damaged} <span data-numeric>{formatQuantity(row.damaged)}</span>
                </span>
              ) : null}
            </p>
          ) : null}
        </li>
      ))}
    </ul>
  );
}

export function StockTable({ rows }: { rows: StockRow[] }) {
  return (
    <div className="relative hidden overflow-x-auto lg:block">
      <table className="w-full min-w-[62rem] border-collapse text-sm">
        <thead>
          <tr className="border-y border-line text-left text-xs text-muted">
            <th scope="col" className="py-2 pr-4 font-medium">Ürün / varyant</th>
            <th scope="col" className="py-2 pr-4 font-medium">SKU / barkod</th>
            <th scope="col" className="py-2 pr-4 text-right font-medium">{BUCKET_LABELS.sellable}</th>
            <th scope="col" className="py-2 pr-4 text-right font-medium">{BUCKET_LABELS.quarantine}</th>
            <th scope="col" className="py-2 pr-4 text-right font-medium">{BUCKET_LABELS.damaged}</th>
            <th scope="col" className="py-2 pr-4 text-right font-medium">Toplam</th>
            <th scope="col" className="py-2 pr-4 text-right font-medium">Rezerve</th>
            <th scope="col" className="py-2 text-right font-medium">Uygun</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-line">
          {rows.map((row) => (
            <tr key={row.variant_id} className="transition-colors hover:bg-panel/60">
              <td className="py-2.5 pr-4">
                <Identity row={row} />
              </td>
              <td className="py-2.5 pr-4 text-ink-70" data-numeric>
                {row.sku}
                {row.primary_barcode ? (
                  <span className="mt-0.5 block text-2xs text-muted">{row.primary_barcode}</span>
                ) : null}
              </td>
              <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.sellable)}</td>
              <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.quarantine)}</td>
              <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.damaged)}</td>
              <td className="py-2.5 pr-4 text-right font-medium" data-numeric>{formatQuantity(row.on_hand)}</td>
              <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.reserved)}</td>
              <td className="py-2.5 text-right font-medium" data-numeric>{formatQuantity(row.available)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
