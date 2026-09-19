"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Sheet } from "@/components/ui/sheet";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Stat, StatGrid } from "@/components/ui/stat";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell } from "@/components/ui/table";
import { Notice } from "@/components/catalog/intake/primitives";
import { BUCKET_LABELS } from "@/lib/stock/model";
import {
  COST_SOURCE_HINTS,
  COST_SOURCE_LABELS,
  REVIEW_FILTER_LABELS,
  costPendingLines,
  formatBaseMoney,
  lineDifference,
  matchesReviewFilter,
  summarize,
  type CountCostSource,
  type CountLine,
  type PostSummary,
  type ReviewFilter,
  type StockCount,
} from "@/lib/stock/count-model";
import { cancelAction, clearLineCostAction, postAction, reopenAction, resolveFromReviewAction, reviewAction, setLineCostAction } from "@/app/app/stok/sayim/actions";
import { ConditionBadge, Difference, VariantIdentity, useCountEvents } from "./shared";
import { cn } from "@/lib/utils";

/**
 * Review: expected (ledger at review time) against counted, per variant and condition.
 * Unresolved lines — on the shelf per the ledger, never scanned — stay open until the
 * person counts them or confirms zero; they are never treated as zero by themselves.
 * POST is one server call; a ledger that moved since review — or a document changed since
 * the review this screen rendered (review_hash) — is refused and the person refreshes the
 * differences.
 *
 * Cost (Phase 15B-0): a surplus on a variant the ledger cannot price is flagged
 * `cost_required`. Owner/manager enter its unit cost here (source + optional reference)
 * and see the value it adds; every other role sees only that a manager must complete it.
 * The cost rows are never loaded for those roles, so nothing here can leak them.
 */
const STALE_MARKERS = ["sayım sırasında değişti", "incelemeden sonra değişti"];
function isStale(message: string): boolean {
  return STALE_MARKERS.some((m) => message.includes(m));
}

export function ReviewScreen({ count, canPost, canCost = false }: { count: StockCount; canPost: boolean; canCost?: boolean }) {
  const router = useRouter();
  const event = useCountEvents();
  const [pending, start] = useTransition();
  const [filter, setFilter] = useState<ReviewFilter>("all");
  const [error, setError] = useState<string | null>(null);
  const [stale, setStale] = useState(false);
  const [posted, setPosted] = useState<PostSummary | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [cancelReason, setCancelReason] = useState("");
  const [editing, setEditing] = useState<CountLine | null>(null);
  const [editQty, setEditQty] = useState("");
  const [costing, setCosting] = useState<CountLine | null>(null);
  const [costUnit, setCostUnit] = useState("");
  const [costSource, setCostSource] = useState<CountCostSource>("documented_purchase");
  const [costNote, setCostNote] = useState("");

  const s = summarize(count.lines);
  const costPending = costPendingLines(count.lines);
  const costRequired = count.lines.filter((l) => l.cost_required);
  const addedValue = count.lines.reduce((sum, l) => (l.cost_required && l.cost ? sum + (lineDifference(l) ?? 0) * l.cost.unit_cost_base : sum), 0);
  const money = (v: number) => formatBaseMoney(v, count.base_currency);
  const visible = count.lines.filter((l) => matchesReviewFilter(l, filter));
  const filterCounts: Record<ReviewFilter, number> = {
    all: count.lines.length,
    differences: s.differences,
    shortages: count.lines.filter((l) => (lineDifference(l) ?? 0) < 0).length,
    surpluses: count.lines.filter((l) => (lineDifference(l) ?? 0) > 0).length,
    zero: count.lines.filter((l) => l.zero_confirmed).length,
    unresolved: s.unresolved,
  };

  function run(fn: () => Promise<{ ok: boolean; error?: string }>, after?: () => void) {
    setError(null);
    start(async () => {
      const res = await fn();
      if (!res.ok) {
        setError(res.error ?? "İşlem tamamlanamadı.");
        setStale(!!res.error && isStale(res.error));
        return;
      }
      after?.();
      router.refresh();
    });
  }

  function openCost(line: CountLine) {
    setCosting(line);
    setCostUnit(line.cost ? String(line.cost.unit_cost_base) : "");
    setCostSource(line.cost?.cost_source ?? "documented_purchase");
    setCostNote(line.cost?.note ?? "");
  }

  function saveCost() {
    if (!costing) return;
    const unit = Number(costUnit.replace(",", "."));
    if (!Number.isFinite(unit) || unit <= 0) { setError("Birim maliyet sıfırdan büyük olmalı."); return; }
    const line = costing;
    setCosting(null);
    run(() => setLineCostAction({ count_id: count.id, line_id: line.id, unit_cost: unit, source: costSource, note: costNote }));
  }

  function resolve(line: CountLine, quantity: number) {
    setEditing(null);
    run(() => resolveFromReviewAction({ count_id: count.id, variant_id: line.variant_id, bucket: line.bucket, quantity, ...event() }));
  }

  function post() {
    setConfirmOpen(false);
    setError(null);
    start(async () => {
      const res = await postAction(count.id, count.review_hash);
      if (!res.ok) {
        setError(res.error);
        setStale(isStale(res.error));
        return;
      }
      setPosted(res.data);
      router.refresh();
    });
  }

  if (posted) {
    return (
      <Notice tone="success">
        {posted.count_number} tamamlandı: {posted.lines} ürün, {posted.adjustments} stok farkı, −{posted.shortage_units} eksik, +{posted.surplus_units} fazla. Sayfa yenileniyor…
      </Notice>
    );
  }

  return (
    <div className="space-y-6 pb-28">
      <p className="text-sm text-text-muted">
        &quot;Sistemde&quot; inceleme anındaki stoktur; tamamlarken yeniden doğrulanır.
      </p>

      <StatGrid>
        <Stat label="Sayılan" value={s.counted} hint={s.unresolved > 0 ? `${s.unresolved} sayılmadı` : undefined} />
        <Stat label="Fark olan" value={s.differences} />
        <Stat label="Eksik adet" value={s.shortage} />
        <Stat label="Fazla adet" value={s.surplus} />
      </StatGrid>

      {s.unresolved > 0 ? (
        <Notice tone="warning">
          <span className="font-medium">{s.unresolved} ürün sayılmadı.</span> Sisteme göre rafta olması gerekenler; sayılmadı diye 0 sayılmaz. Her birini say ya da &quot;0 adet olarak doğrula&quot; ile onayla.
        </Notice>
      ) : null}

      {costRequired.length > 0 ? (
        canCost ? (
          <Notice tone={costPending.length > 0 ? "warning" : "info"}>
            <span className="font-medium">{costRequired.length} ürün için alış maliyeti gerekli.</span>{" "}
            Bu ürünler stoğa yeni giriyor ve sistemde maliyetleri yok; alış maliyeti girilmeden sayım tamamlanamaz.
            {costPending.length === 0 ? <> Tüm maliyetler girildi — eklenen değer <span data-numeric>{money(addedValue)}</span>.</> : <> Bekleyen: <span data-numeric>{costPending.length}</span>.</>}
          </Notice>
        ) : (
          <Notice tone="info">
            <span className="font-medium">{costRequired.length} ürün için alış maliyeti gerekli.</span> Bu ürünler stoğa yeni giriyor; maliyeti işletme sahibi ya da yönetici girer, girilmeden sayım tamamlanamaz.
          </Notice>
        )
      ) : null}

      {error ? (
        <Notice tone="danger">
          {error}
          {stale ? (
            <div className="mt-2">
              <Button size="sm" variant="outline" onClick={() => run(() => reviewAction(count.id), () => setStale(false))} disabled={pending}>
                Farkları yeniden hesapla
              </Button>
            </div>
          ) : null}
        </Notice>
      ) : null}

      <div className="flex flex-wrap gap-1.5" role="tablist" aria-label="Filtre">
        {(Object.keys(REVIEW_FILTER_LABELS) as ReviewFilter[]).map((f) => (
          <button
            key={f}
            type="button"
            role="tab"
            aria-selected={filter === f}
            onClick={() => setFilter(f)}
            className={cn(
              "min-h-9 rounded border px-2.5 text-xs transition-colors",
              filter === f ? "border-accent bg-accent-muted text-accent" : "border-border-strong bg-surface text-text-secondary",
            )}
          >
            {REVIEW_FILTER_LABELS[f]} <span data-numeric className="ml-1 opacity-70">{filterCounts[f]}</span>
          </button>
        ))}
      </div>

      {visible.length === 0 ? (
        <p className="text-sm text-text-muted">Bu filtrede satır yok.</p>
      ) : (
        <>
          {/* phone: cards */}
          <ul className="space-y-2 lg:hidden">
            {visible.map((l) => (
              <li key={l.id} className={cn("rounded border bg-surface p-3", l.counted_quantity === null ? "border-warning/40" : "border-border")} data-sku={l.sku} data-bucket={l.bucket} data-expected={l.expected_quantity ?? ""} data-counted={l.counted_quantity ?? ""}>
                <VariantIdentity v={l} size="sm" />
                <div className="mt-3 flex items-center justify-between gap-3">
                  <ConditionBadge bucket={l.bucket} />
                  <dl className="flex items-center gap-4 text-sm">
                    <div className="text-center"><dt className="text-2xs text-text-muted">Sayılan</dt><dd data-numeric className={cn("text-base font-medium", l.counted_quantity === null ? "text-warning" : "text-text-primary")}>{l.counted_quantity ?? "—"}</dd></div>
                    <div className="text-center"><dt className="text-2xs text-text-muted">Sistemde</dt><dd data-numeric>{l.expected_quantity ?? "—"}</dd></div>
                    <div className="text-center"><dt className="text-2xs text-text-muted">Fark</dt><dd><Difference value={lineDifference(l)} /></dd></div>
                  </dl>
                </div>
                {l.counted_quantity === null ? (
                  <div className="mt-3 grid grid-cols-2 gap-2">
                    <Button size="sm" variant="outline" onClick={() => resolve(l, 0)} disabled={pending}>0 adet olarak doğrula</Button>
                    <Button size="sm" variant="outline" onClick={() => { setEditing(l); setEditQty(""); }} disabled={pending}>Miktar gir</Button>
                  </div>
                ) : null}
                {l.cost_required ? <CostCell line={l} canCost={canCost} money={money} onEdit={() => openCost(l)} pending={pending} /> : null}
              </li>
            ))}
          </ul>

          {/* desktop: table */}
          <div className="hidden lg:block">
            <TableShell minWidth="40rem">
              <THead>
                <TH>Ürün</TH>
                <TH>Renk / beden</TH>
                <TH>Durum</TH>
                <TH align="right">Sayılan</TH>
                <TH align="right">Sistemde</TH>
                <TH align="right">Fark</TH>
                {costRequired.length > 0 ? <TH>Maliyet</TH> : null}
                <TH></TH>
              </THead>
              <TBody>
                {visible.map((l) => (
                  <TR key={l.id}>
                    <TD><CellTitle sub={l.sku}>{l.product_name}</CellTitle></TD>
                    <TD>{l.options || "Tek seçenek"}</TD>
                    <TD><ConditionBadge bucket={l.bucket} /></TD>
                    <TD numeric align="right" className={l.counted_quantity === null ? "text-warning" : "font-medium text-text-primary"}>{l.counted_quantity ?? "sayılmadı"}</TD>
                    <TD numeric align="right">{l.expected_quantity ?? "—"}</TD>
                    <TD align="right"><Difference value={lineDifference(l)} /></TD>
                    {costRequired.length > 0 ? <TD>{l.cost_required ? <CostCell line={l} canCost={canCost} money={money} onEdit={() => openCost(l)} pending={pending} compact /> : null}</TD> : null}
                    <TD>
                      {l.counted_quantity === null ? (
                        <span className="flex gap-1">
                          <Button size="sm" variant="outline" onClick={() => resolve(l, 0)} disabled={pending}>0 adet olarak doğrula</Button>
                          <Button size="sm" variant="ghost" onClick={() => { setEditing(l); setEditQty(""); }} disabled={pending}>Miktar gir</Button>
                        </span>
                      ) : null}
                    </TD>
                  </TR>
                ))}
              </TBody>
            </TableShell>
          </div>
        </>
      )}

      <div className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-background/95 px-4 py-3 backdrop-blur sm:sticky sm:inset-auto sm:px-0">
        <div className="mx-auto flex max-w-3xl flex-wrap items-center justify-between gap-2">
          <div className="flex gap-2">
            <Button variant="ghost" onClick={() => run(() => reopenAction(count.id))} disabled={pending}>Sayıma dön</Button>
            {canPost ? <Button variant="ghost" onClick={() => setCancelOpen(true)} disabled={pending}>İptal et</Button> : null}
          </div>
          {canPost ? (
            <Button size="lg" variant="accent" onClick={() => setConfirmOpen(true)} disabled={pending || s.unresolved > 0 || count.lines.length === 0 || costPending.length > 0} data-testid="post-button">
              {pending ? "…" : costPending.length > 0 ? `${costPending.length} ürün için maliyet bekleniyor` : "Sayımı tamamla"}
            </Button>
          ) : (
            <span className="text-xs text-text-muted">Sayımı işletme sahibi ya da yönetici tamamlar</span>
          )}
        </div>
      </div>

      <Sheet open={confirmOpen} onClose={() => setConfirmOpen(false)} title="Sayımı tamamla" side="right" className="w-[min(26rem,94vw)]">
        <div className="space-y-4 p-4 text-sm">
          <p>Stok bu sayıma göre güncellenir; bu geri alınamaz. Sonraki düzeltme yeni bir sayımla yapılır.</p>
          <dl className="divide-y divide-border border-y border-border">
            <div className="flex justify-between py-2"><dt className="text-text-muted">Sayılan ürün</dt><dd data-numeric>{s.counted}</dd></div>
            <div className="flex justify-between py-2"><dt className="text-text-muted">Fark olan</dt><dd data-numeric>{s.differences}</dd></div>
            <div className="flex justify-between py-2"><dt className="text-text-muted">Eksik adet</dt><dd data-numeric>−{s.shortage}</dd></div>
            <div className="flex justify-between py-2"><dt className="text-text-muted">Fazla adet</dt><dd data-numeric>+{s.surplus}</dd></div>
            {canCost && costRequired.length > 0 ? (
              <div className="flex justify-between py-2"><dt className="text-text-muted">Girilen maliyetle eklenen değer</dt><dd data-numeric>{money(addedValue)}</dd></div>
            ) : null}
          </dl>
          <p className="text-2xs text-text-muted">Eksikler şubenin ortalama maliyetiyle düşer; fazlalar aynı ortalamayı devralır. Sistemde maliyeti olmayan bir ürünün fazlası yalnız girdiğin alış maliyetiyle işlenir; girilmemişse sayım tamamlanmaz.</p>
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setConfirmOpen(false)}>Vazgeç</Button>
            <Button variant="accent" onClick={post} disabled={pending}>Evet, tamamla</Button>
          </div>
        </div>
      </Sheet>

      <Sheet open={!!editing} onClose={() => setEditing(null)} title="Miktar gir" side="right" className="w-[min(24rem,94vw)]">
        {editing ? (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              const q = Number(editQty);
              if (Number.isInteger(q) && q >= 0) resolve(editing, q);
            }}
            className="space-y-4 p-4"
          >
            <VariantIdentity v={editing} />
            <p className="text-xs text-text-muted">{BUCKET_LABELS[editing.bucket]} · sistemde {editing.expected_quantity ?? "—"}</p>
            <Input value={editQty} onChange={(e) => setEditQty(e.target.value)} inputMode="numeric" pattern="[0-9]*" placeholder="Sayılan adet" autoFocus aria-label="Sayılan adet" />
            <div className="flex justify-end gap-2">
              <Button type="button" variant="ghost" onClick={() => setEditing(null)}>Vazgeç</Button>
              <Button type="submit" disabled={pending || editQty.trim() === ""}>Kaydet</Button>
            </div>
          </form>
        ) : null}
      </Sheet>

      <Sheet open={!!costing} onClose={() => setCosting(null)} title="Birim alış maliyeti" side="right" className="w-[min(26rem,94vw)]">
        {costing ? (
          <form onSubmit={(e) => { e.preventDefault(); saveCost(); }} className="space-y-4 p-4" data-testid="cost-form">
            <VariantIdentity v={costing} />
            <p className="text-xs text-text-secondary">Bu ürün için sistemde alış maliyeti yok. Stoğa eklenecek adetler için birim alış maliyetini gir.</p>
            <dl className="grid grid-cols-3 gap-2 border-y border-border py-2 text-center text-sm">
              <div><dt className="text-2xs text-text-muted">Sayılan</dt><dd data-numeric>{costing.counted_quantity ?? "—"}</dd></div>
              <div><dt className="text-2xs text-text-muted">Sistemde</dt><dd data-numeric>{costing.expected_quantity ?? "—"}</dd></div>
              <div><dt className="text-2xs text-text-muted">Fark</dt><dd><Difference value={lineDifference(costing)} /></dd></div>
            </dl>
            <div className="space-y-1.5">
              <Label htmlFor="cost-unit">Birim maliyet ({count.base_currency})</Label>
              <Input id="cost-unit" value={costUnit} onChange={(e) => setCostUnit(e.target.value)} inputMode="decimal" placeholder="0,00" autoFocus aria-label="Birim maliyet" />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="cost-source">Maliyet kaynağı</Label>
              <Select id="cost-source" value={costSource} onChange={(e) => setCostSource(e.target.value as CountCostSource)}>
                {(Object.keys(COST_SOURCE_LABELS) as CountCostSource[]).map((k) => <option key={k} value={k}>{COST_SOURCE_LABELS[k]}</option>)}
              </Select>
              <p className="text-2xs text-text-muted">{COST_SOURCE_HINTS[costSource]}</p>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="cost-note">Açıklama / referans (isteğe bağlı)</Label>
              <Input id="cost-note" value={costNote} onChange={(e) => setCostNote(e.target.value)} maxLength={500} placeholder="Fatura no, satır, kaynak…" />
            </div>
            {(() => {
              const unit = Number(costUnit.replace(",", "."));
              const diff = lineDifference(costing) ?? 0;
              return Number.isFinite(unit) && unit > 0 ? (
                <p className="text-sm">Toplam eklenen değer: <span data-numeric className="font-medium">{money(diff * unit)}</span> <span className="text-text-muted">({diff} × {money(unit)})</span></p>
              ) : null;
            })()}
            <div className="flex justify-between gap-2">
              {costing.cost ? (
                <Button type="button" variant="ghost" onClick={() => { const line = costing; setCosting(null); run(() => clearLineCostAction({ count_id: count.id, line_id: line.id })); }} disabled={pending}>Maliyeti kaldır</Button>
              ) : <span />}
              <span className="flex gap-2">
                <Button type="button" variant="ghost" onClick={() => setCosting(null)}>Vazgeç</Button>
                <Button type="submit" disabled={pending || costUnit.trim() === ""}>Kaydet</Button>
              </span>
            </div>
          </form>
        ) : null}
      </Sheet>

      <ConfirmDialog
        open={cancelOpen}
        onClose={() => (pending ? undefined : setCancelOpen(false))}
        title="Bu sayım iptal edilsin mi?"
        description="Sayılanlar kayıt için saklanır; stok değişmez. Yeniden saymak için yeni bir sayım açılır."
        confirmLabel="Sayımı iptal et"
        destructive
        busy={pending}
        onConfirm={() => run(() => cancelAction(count.id, cancelReason), () => setCancelOpen(false))}
      >
        <Input value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="Neden (isteğe bağlı)" aria-label="İptal nedeni" maxLength={500} />
      </ConfirmDialog>
    </div>
  );
}

/**
 * What a flagged line shows about its cost. Owner/manager: the entered unit cost, the value
 * it adds and an edit button; everyone else: only that a manager must complete it. The
 * `cost` field is null for those roles because the query never loads it for them.
 */
function CostCell({ line, canCost, money, onEdit, pending, compact = false }: { line: CountLine; canCost: boolean; money: (v: number) => string; onEdit: () => void; pending: boolean; compact?: boolean }) {
  const diff = lineDifference(line) ?? 0;
  if (!canCost) {
    return <p className={cn("text-2xs text-text-muted", compact ? "" : "mt-3 border-t border-border pt-2")} data-testid="cost-staff-note">Bu ürün için alış maliyeti gerekli — yönetici girer.</p>;
  }
  return (
    <div className={cn("text-xs", compact ? "" : "mt-3 border-t border-border pt-2")} data-testid="cost-cell" data-has-cost={line.cost ? "1" : "0"}>
      {line.cost ? (
        <p>
          <span data-numeric>{money(line.cost.unit_cost_base)}</span> × {diff} = <span data-numeric className="font-medium">{money(diff * line.cost.unit_cost_base)}</span>
          <span className="block text-2xs text-text-muted">{COST_SOURCE_LABELS[line.cost.cost_source]}{line.cost.note ? ` · ${line.cost.note}` : ""}</span>
        </p>
      ) : (
        <p className="text-warning">Bu ürün için alış maliyeti gerekli.</p>
      )}
      <Button size="sm" variant={line.cost ? "ghost" : "outline"} className="mt-1" onClick={onEdit} disabled={pending}>{line.cost ? "Maliyeti düzenle" : "Alış maliyeti gir"}</Button>
    </div>
  );
}
