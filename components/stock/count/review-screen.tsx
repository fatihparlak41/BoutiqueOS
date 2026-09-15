"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Sheet } from "@/components/ui/sheet";
import { Stat, StatGrid } from "@/components/ui/stat";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell } from "@/components/ui/table";
import { Notice } from "@/components/catalog/intake/primitives";
import { BUCKET_LABELS } from "@/lib/stock/model";
import {
  COUNT_TYPE_LABELS,
  REVIEW_FILTER_LABELS,
  lineDifference,
  matchesReviewFilter,
  summarize,
  type CountLine,
  type PostSummary,
  type ReviewFilter,
  type StockCount,
} from "@/lib/stock/count-model";
import { cancelAction, postAction, reopenAction, resolveFromReviewAction, reviewAction } from "@/app/app/stok/sayim/actions";
import { ConditionBadge, Difference, VariantIdentity, useCountEvents } from "./shared";
import { cn } from "@/lib/utils";

/**
 * Review: expected (ledger at review time) against counted, per variant and condition.
 * Unresolved lines — on the shelf per the ledger, never scanned — stay open until the
 * person counts them or confirms zero; they are never treated as zero by themselves.
 * POST is one server call; a ledger that moved since review is refused and the person
 * refreshes the differences. No valuation is shown here in any role.
 */
export function ReviewScreen({ count, canPost }: { count: StockCount; canPost: boolean }) {
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

  const s = summarize(count.lines);
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
        setStale(!!res.error && res.error.includes("sayım sırasında değişti"));
        return;
      }
      after?.();
      router.refresh();
    });
  }

  function resolve(line: CountLine, quantity: number) {
    setEditing(null);
    run(() => resolveFromReviewAction({ count_id: count.id, variant_id: line.variant_id, bucket: line.bucket, quantity, ...event() }));
  }

  function post() {
    setConfirmOpen(false);
    setError(null);
    start(async () => {
      const res = await postAction(count.id);
      if (!res.ok) {
        setError(res.error);
        setStale(res.error.includes("sayım sırasında değişti"));
        return;
      }
      setPosted(res.data);
      router.refresh();
    });
  }

  if (posted) {
    return (
      <Notice tone="success">
        {posted.count_number} işlendi: {posted.lines} satır, {posted.adjustments} düzeltme hareketi, −{posted.shortage_units} eksik, +{posted.surplus_units} fazla. Sayfa yenileniyor…
      </Notice>
    );
  }

  return (
    <div className="space-y-6 pb-28">
      <p className="text-sm text-text-muted">
        {COUNT_TYPE_LABELS[count.count_type]} · {count.branch_name}. Beklenen miktarlar inceleme anındaki stok defteridir; işlerken yeniden doğrulanır.
      </p>

      <StatGrid>
        <Stat label="Sayılan varyant" value={s.counted} hint={s.unresolved > 0 ? `${s.unresolved} sayılmamış` : undefined} />
        <Stat label="Fark olan" value={s.differences} />
        <Stat label="Eksik adet" value={s.shortage} />
        <Stat label="Fazla adet" value={s.surplus} />
      </StatGrid>

      {s.unresolved > 0 ? (
        <Notice tone="warning">
          <span className="font-medium">{s.unresolved} satır sayılmadı.</span> Deftere göre rafta olması gereken ürünler; sayılmadı diye 0 sayılmaz. Her birini sayın ya da &quot;0 adet olarak doğrula&quot; ile onaylayın.
        </Notice>
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
              <li key={l.id} className={cn("rounded border bg-surface p-3", l.counted_quantity === null ? "border-warning/40" : "border-border")}>
                <VariantIdentity v={l} size="sm" />
                <div className="mt-3 flex items-center justify-between gap-3">
                  <ConditionBadge bucket={l.bucket} />
                  <dl className="flex items-center gap-4 text-sm">
                    <div className="text-center"><dt className="text-2xs text-text-muted">Beklenen</dt><dd data-numeric>{l.expected_quantity ?? "—"}</dd></div>
                    <div className="text-center"><dt className="text-2xs text-text-muted">Sayılan</dt><dd data-numeric className={l.counted_quantity === null ? "text-warning" : ""}>{l.counted_quantity ?? "sayılmadı"}</dd></div>
                    <div className="text-center"><dt className="text-2xs text-text-muted">Fark</dt><dd><Difference value={lineDifference(l)} /></dd></div>
                  </dl>
                </div>
                {l.counted_quantity === null ? (
                  <div className="mt-3 grid grid-cols-2 gap-2">
                    <Button size="sm" variant="outline" onClick={() => resolve(l, 0)} disabled={pending}>0 adet olarak doğrula</Button>
                    <Button size="sm" variant="outline" onClick={() => { setEditing(l); setEditQty(""); }} disabled={pending}>Miktar gir</Button>
                  </div>
                ) : null}
              </li>
            ))}
          </ul>

          {/* desktop: table */}
          <div className="hidden lg:block">
            <TableShell minWidth="56rem">
              <THead>
                <TH>Ürün</TH>
                <TH>Varyant</TH>
                <TH>Durum</TH>
                <TH align="right">Beklenen</TH>
                <TH align="right">Sayılan</TH>
                <TH align="right">Fark</TH>
                <TH></TH>
              </THead>
              <TBody>
                {visible.map((l) => (
                  <TR key={l.id}>
                    <TD><CellTitle sub={l.sku}>{l.product_name}</CellTitle></TD>
                    <TD>{l.options || "Tek varyant"}</TD>
                    <TD><ConditionBadge bucket={l.bucket} /></TD>
                    <TD numeric align="right">{l.expected_quantity ?? "—"}</TD>
                    <TD numeric align="right" className={l.counted_quantity === null ? "text-warning" : ""}>{l.counted_quantity ?? "sayılmadı"}</TD>
                    <TD align="right"><Difference value={lineDifference(l)} /></TD>
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
            <Button size="lg" onClick={() => setConfirmOpen(true)} disabled={pending || s.unresolved > 0 || count.lines.length === 0}>
              {pending ? "…" : "Sayımı işle"}
            </Button>
          ) : (
            <span className="text-xs text-text-muted">İşleme yetkisi: işletme sahibi ya da yönetici</span>
          )}
        </div>
      </div>

      <Sheet open={confirmOpen} onClose={() => setConfirmOpen(false)} title="Sayımı işle" side="right" className="w-[min(26rem,94vw)]">
        <div className="space-y-4 p-4 text-sm">
          <p>Bu işlem stok defterine düzeltme hareketleri yazar ve geri alınamaz. Sonraki düzeltme yeni bir sayımla yapılır.</p>
          <dl className="divide-y divide-border border-y border-border">
            <div className="flex justify-between py-2"><dt className="text-text-muted">Sayılan varyant</dt><dd data-numeric>{s.counted}</dd></div>
            <div className="flex justify-between py-2"><dt className="text-text-muted">Fark olan satır</dt><dd data-numeric>{s.differences}</dd></div>
            <div className="flex justify-between py-2"><dt className="text-text-muted">Eksik adet</dt><dd data-numeric>−{s.shortage}</dd></div>
            <div className="flex justify-between py-2"><dt className="text-text-muted">Fazla adet</dt><dd data-numeric>+{s.surplus}</dd></div>
          </dl>
          <p className="text-2xs text-text-muted">Eksikler şubenin hareketli ortalama maliyetiyle düşer; fazlalar aynı ortalamayı devralır. Şubede stoğu olmayan bir varyantta fazla çıkarsa işlem durur ve maliyet çözümü istenir.</p>
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setConfirmOpen(false)}>Vazgeç</Button>
            <Button onClick={post} disabled={pending}>Evet, işle</Button>
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
            <p className="text-xs text-text-muted">{BUCKET_LABELS[editing.bucket]} · beklenen {editing.expected_quantity ?? "—"}</p>
            <Input value={editQty} onChange={(e) => setEditQty(e.target.value)} inputMode="numeric" pattern="[0-9]*" placeholder="Sayılan adet" autoFocus aria-label="Sayılan adet" />
            <div className="flex justify-end gap-2">
              <Button type="button" variant="ghost" onClick={() => setEditing(null)}>Vazgeç</Button>
              <Button type="submit" disabled={pending || editQty.trim() === ""}>Kaydet</Button>
            </div>
          </form>
        ) : null}
      </Sheet>

      <Sheet open={cancelOpen} onClose={() => setCancelOpen(false)} title="Sayımı iptal et" side="right" className="w-[min(24rem,94vw)]">
        <div className="space-y-3 p-4">
          <p className="text-sm text-text-secondary">Sayım iptal edilir; satırlar ve taramalar kayıt için saklanır. Stok değişmez.</p>
          <Input value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="Neden (isteğe bağlı)" aria-label="İptal nedeni" maxLength={500} />
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setCancelOpen(false)}>Vazgeç</Button>
            <Button variant="danger" onClick={() => run(() => cancelAction(count.id, cancelReason), () => setCancelOpen(false))} disabled={pending}>İptal et</Button>
          </div>
        </div>
      </Sheet>
    </div>
  );
}
