import Link from "next/link";
import { redirect } from "next/navigation";
import { listReceipts, listSuppliers, loadReceivingContext } from "@/lib/receiving/queries";
import { RECEIPT_STATUS_LABELS, type ReceiptStatus } from "@/lib/receiving/model";
import { formatDate, formatMoney, formatQuantity } from "@/lib/receiving/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/ui/page-header";
import { FilterBar, FilterField } from "@/components/ui/filter-bar";
import { EmptyState } from "@/components/ui/empty-state";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell, rowLinkClass } from "@/components/ui/table";
import { ReceiptStatusPill } from "@/components/receiving/receipt-status-pill";

export const metadata = { title: "Mal kabul · BoutiqueOS" };

function isStatus(value: string | undefined): value is ReceiptStatus {
  return value === "draft" || value === "posted" || value === "cancelled";
}

export default async function ReceiptsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; durum?: string; tedarikci?: string; baslangic?: string; bitis?: string }>;
}) {
  const { caps } = await loadReceivingContext();
  // pol_gr_select is fn_is_procurement: sales_staff cannot read receiving at all.
  if (!caps.canRead) redirect("/app");

  const params = await searchParams;
  const search = params.q?.trim() ?? "";
  const status = isStatus(params.durum) ? params.durum : undefined;
  const supplierId = params.tedarikci ?? "";
  const from = params.baslangic ?? "";
  const to = params.bitis ?? "";

  const [receipts, suppliers] = await Promise.all([
    listReceipts({ search, status, supplierId: supplierId || undefined, from: from || undefined, to: to || undefined }),
    listSuppliers(),
  ]);

  const hasFilter = Boolean(search || status || supplierId || from || to);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Mal kabul"
        description="Stok yalnız işlenmiş belgelerle oluşur. Taslak belgeler stoğu etkilemez."
        actions={
          caps.canWriteReceipt ? (
            <Link href="/app/mal-kabul/yeni">
              <Button size="sm">Yeni mal kabul</Button>
            </Link>
          ) : undefined
        }
      />

      <FilterBar clearHref="/app/mal-kabul" hasFilter={hasFilter}>
        <FilterField wide>
          <Label htmlFor="q">Ara</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Belge no veya referans" spellCheck={false} />
        </FilterField>
        <FilterField>
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {Object.entries(RECEIPT_STATUS_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
        </FilterField>
        <FilterField>
          <Label htmlFor="tedarikci">Tedarikçi</Label>
          <Select id="tedarikci" name="tedarikci" defaultValue={supplierId}>
            <option value="">Tümü</option>
            {suppliers.map((supplier) => (
              <option key={supplier.id} value={supplier.id}>
                {supplier.name}
              </option>
            ))}
          </Select>
        </FilterField>
        <div className="col-span-2 grid grid-cols-2 gap-2 lg:col-span-1">
          <div className="space-y-1.5">
            <Label htmlFor="baslangic">Başlangıç</Label>
            <Input id="baslangic" name="baslangic" type="date" defaultValue={from} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="bitis">Bitiş</Label>
            <Input id="bitis" name="bitis" type="date" defaultValue={to} />
          </div>
        </div>
      </FilterBar>

      {receipts.length === 0 ? (
        hasFilter ? (
          <EmptyState
            compact
            title="Bu filtrelere uyan belge yok"
            description="Aramayı daraltmayı ya da filtreleri temizlemeyi deneyin."
          />
        ) : (
          <EmptyState
            editorial
            title="Henüz mal kabul yok"
            description="Yeni bir belge açıp satırları girdikten sonra işleyerek stoğa alabilirsiniz."
            action={
              caps.canWriteReceipt ? (
                <Link href="/app/mal-kabul/yeni">
                  <Button>İlk belgeyi aç</Button>
                </Link>
              ) : undefined
            }
          />
        )
      ) : (
        <TableShell minWidth="56rem" footer={`${receipts.length} belge listeleniyor.`}>
          <THead>
            <TH>Belge</TH>
            <TH>Tarih</TH>
            <TH>Tedarikçi</TH>
            <TH>Şube</TH>
            <TH align="right">Satır</TH>
            <TH align="right">Adet</TH>
            {caps.canManageCost ? <TH align="right">Tutar</TH> : null}
            <TH>Durum</TH>
          </THead>
          <TBody>
            {receipts.map((receipt) => (
              <TR key={receipt.id}>
                <TD>
                  <CellTitle sub={receipt.document_ref ?? undefined}>
                    <Link href={`/app/mal-kabul/${receipt.id}`} className={rowLinkClass} data-numeric>
                      {receipt.receipt_number}
                    </Link>
                  </CellTitle>
                </TD>
                <TD muted numeric nowrap>{formatDate(receipt.received_at)}</TD>
                <TD muted>{receipt.supplier_name}</TD>
                <TD muted nowrap>{receipt.branch_name}</TD>
                <TD muted numeric align="right">{receipt.line_count}</TD>
                <TD muted numeric align="right">{formatQuantity(receipt.total_quantity)}</TD>
                {caps.canManageCost ? (
                  <TD muted numeric align="right">
                    {receipt.total_original === null || receipt.missing_cost_lines > 0 ? "—" : formatMoney(receipt.total_original, receipt.invoice_currency)}
                    {receipt.missing_cost_lines > 0 ? (
                      <span className="mt-0.5 block text-2xs text-danger">{receipt.missing_cost_lines} satır fiyat bekliyor</span>
                    ) : null}
                  </TD>
                ) : null}
                <TD>
                  <ReceiptStatusPill status={receipt.status} />
                  {receipt.posted_at ? (
                    <span className="mt-0.5 block text-2xs text-text-muted" data-numeric>
                      {formatDate(receipt.posted_at)}
                    </span>
                  ) : null}
                </TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
      )}
    </div>
  );
}
