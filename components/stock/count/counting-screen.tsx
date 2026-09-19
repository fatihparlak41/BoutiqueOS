"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ScanLine, Search, Undo2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Sheet } from "@/components/ui/sheet";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Notice } from "@/components/catalog/intake/primitives";
import { BUCKET_LABELS, type Bucket } from "@/lib/stock/model";
import { COUNT_TYPE_LABELS, type CountLine, type CountVariant, type StockCount } from "@/lib/stock/count-model";
import { adjustLineAction, cancelAction, reviewAction, scanCodeAction, searchVariantsAction, setQuantityAction } from "@/app/app/stok/sayim/actions";
import { ConditionBadge, VariantIdentity, useCountEvents } from "./shared";
import { cn } from "@/lib/utils";

/**
 * Active counting, phone in hand. The scan field owns focus: a scanner (or the phone's
 * scanner keyboard) types the code and sends Enter, the line for the chosen condition
 * gets +1, the field is cleared and focused again. Nothing here opens the product page.
 *
 * Everything shown is what the server returned for the last event; the running list is
 * the count's lines ordered by last touch. Expected quantities are not shown while
 * counting — the difference is a review question, and showing the book quantity to the
 * person counting invites counting the book instead of the shelf.
 */

const BUCKETS: Bucket[] = ["sellable", "damaged", "quarantine"];
const LAST_BORDER: Record<Bucket, string> = {
  sellable: "border-success/40",
  quarantine: "border-warning/40",
  damaged: "border-danger/40",
};
const BUCKET_ACTIVE: Record<Bucket, string> = {
  sellable: "border-success bg-success-muted text-success",
  quarantine: "border-warning bg-warning-muted text-warning",
  damaged: "border-danger bg-danger-muted text-danger",
};

export function CountingScreen({ count, canPost }: { count: StockCount; canPost: boolean }) {
  const router = useRouter();
  const event = useCountEvents();
  const [pending, start] = useTransition();
  const [bucket, setBucket] = useState<Bucket>("sellable");
  const [code, setCode] = useState("");
  const [lines, setLines] = useState<CountLine[]>(count.lines);
  const [last, setLast] = useState<CountLine | null>(count.lines[0] ?? null);
  const [history, setHistory] = useState<Array<{ variant_id: string; bucket: Bucket }>>([]);
  const [error, setError] = useState<string | null>(null);
  const [manualQty, setManualQty] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [term, setTerm] = useState("");
  const [results, setResults] = useState<CountVariant[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [cancelReason, setCancelReason] = useState("");
  const scanRef = useRef<HTMLInputElement>(null);
  // A scanner types the next code while the previous one is still on its way to the
  // server. Every Enter takes the field's current value, clears the field at once and
  // queues the code; codes are sent one after another in the order they were read.
  const queueRef = useRef<Array<{ code: string; bucket: Bucket }>>([]);
  const sendingRef = useRef(false);

  useEffect(() => {
    setLines(count.lines);
  }, [count.lines]);

  const focusScan = () => window.setTimeout(() => scanRef.current?.focus(), 0);

  function merge(line: CountLine) {
    setLines((prev) => [line, ...prev.filter((l) => l.id !== line.id)]);
    setLast(line);
    setManualQty("");
  }

  async function drain() {
    if (sendingRef.current) return;
    sendingRef.current = true;
    try {
      while (queueRef.current.length > 0) {
        const next = queueRef.current.shift()!;
        const res = await scanCodeAction({ count_id: count.id, code: next.code, bucket: next.bucket, ...event() });
        if (!res.ok) {
          setError(res.error);
        } else {
          setError(null);
          merge(res.data);
          setHistory((h) => [{ variant_id: res.data.variant_id, bucket: next.bucket }, ...h].slice(0, 50));
        }
      }
    } finally {
      sendingRef.current = false;
      focusScan();
    }
  }

  function scan() {
    const value = code.trim();
    setCode("");
    if (!value) return;
    queueRef.current.push({ code: value, bucket });
    start(() => drain());
  }

  function bump(v: CountVariant, b: Bucket, delta: number) {
    if (pending) return;
    setError(null);
    start(async () => {
      const res = await adjustLineAction({ count_id: count.id, variant_id: v.variant_id, bucket: b, delta, ...event() });
      if (!res.ok) setError(res.error);
      else {
        merge(res.data);
        if (delta > 0) setHistory((h) => [{ variant_id: v.variant_id, bucket: b }, ...h].slice(0, 50));
      }
      focusScan();
    });
  }

  function setExact(v: CountVariant, b: Bucket, quantity: number) {
    if (pending) return;
    setError(null);
    start(async () => {
      const res = await setQuantityAction({ count_id: count.id, variant_id: v.variant_id, bucket: b, quantity, ...event() });
      if (!res.ok) setError(res.error);
      else merge(res.data);
      focusScan();
    });
  }

  function undoLast() {
    const h = history[0];
    if (!h || pending) return;
    setHistory((rest) => rest.slice(1));
    const v = lines.find((l) => l.variant_id === h.variant_id && l.bucket === h.bucket);
    if (v) bump(v, h.bucket, -1);
  }

  async function search() {
    setSearching(true);
    const res = await searchVariantsAction(term);
    setSearching(false);
    if (!res.ok) return setError(res.error);
    setResults(res.data);
  }

  function goReview() {
    setError(null);
    start(async () => {
      const res = await reviewAction(count.id);
      if (!res.ok) return setError(res.error);
      router.refresh();
    });
  }

  function doCancel() {
    start(async () => {
      const res = await cancelAction(count.id, cancelReason);
      if (!res.ok) return setError(res.error);
      setCancelOpen(false);
      router.refresh();
    });
  }

  const countedUnits = lines.reduce((n, l) => n + (l.counted_quantity ?? 0), 0);

  return (
    <div className="space-y-5 pb-28">
      {/* condition switch — the state the next scan lands in, impossible to miss */}
      <div className="sticky top-14 z-10 -mx-4 space-y-3 border-b border-border bg-background/95 px-4 py-3 backdrop-blur lg:top-0 lg:mx-0 lg:rounded lg:border lg:px-4">
        <div className="grid grid-cols-3 gap-2" role="radiogroup" aria-label="Sayılan durum">
          {BUCKETS.map((b) => (
            <button
              key={b}
              type="button"
              role="radio"
              aria-checked={bucket === b}
              onClick={() => {
                setBucket(b);
                focusScan();
              }}
              className={cn(
                "min-h-11 rounded border px-2 text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                bucket === b ? BUCKET_ACTIVE[b] : "border-border-strong bg-surface text-text-secondary",
              )}
            >
              {BUCKET_LABELS[b]}
            </button>
          ))}
        </div>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            scan();
          }}
          className="flex items-center gap-2"
        >
          <label htmlFor="count-scan" className="sr-only">Barkod</label>
          <div className="relative w-full">
            <ScanLine aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 stroke-[1.5] text-text-muted" />
            <Input
              ref={scanRef}
              id="count-scan"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder={`Barkod okutun → ${BUCKET_LABELS[bucket]} +1`}
              className="h-12 pl-9 font-mono text-base sm:h-11"
              autoFocus
              autoComplete="off"
              autoCapitalize="off"
              spellCheck={false}
              inputMode="text"
              enterKeyHint="done"
            />
          </div>
          <Button type="button" variant="outline" size="icon" aria-label="Ürün ara" onClick={() => { setSearchOpen(true); setResults(null); }}>
            <Search aria-hidden className="h-4 w-4 stroke-[1.5]" />
          </Button>
        </form>
        {error ? <Notice tone="danger">{error}</Notice> : null}
      </div>

      {/* last scanned */}
      {last ? (
        <section className={cn("rounded border p-4", LAST_BORDER[last.bucket])} aria-live="polite" data-last-sku={last.sku} data-last-bucket={last.bucket} data-last-qty={last.counted_quantity ?? ""}>
          <div className="flex items-start justify-between gap-3">
            <VariantIdentity v={last} />
            <div className="shrink-0 text-right">
              <p className="text-3xl font-medium leading-none" data-numeric>{last.counted_quantity ?? 0}</p>
              <div className="mt-1"><ConditionBadge bucket={last.bucket} /></div>
            </div>
          </div>
          <div className="mt-4 grid grid-cols-2 gap-2">
            <Button variant="outline" onClick={() => bump(last, last.bucket, -1)} disabled={pending || (last.counted_quantity ?? 0) === 0} aria-label="Bir azalt">−1</Button>
            <Button onClick={() => bump(last, last.bucket, 1)} disabled={pending} aria-label="Bir artır">+1</Button>
            <Button variant="outline" onClick={() => setExact(last, last.bucket, 0)} disabled={pending} className="col-span-2 text-xs">0 adet olarak doğrula</Button>
          </div>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              const q = Number(manualQty);
              if (Number.isInteger(q) && q >= 0) setExact(last, last.bucket, q);
            }}
            className="mt-2 flex items-center gap-2"
          >
            <label htmlFor="count-manual" className="sr-only">Miktar gir</label>
            <Input id="count-manual" value={manualQty} onChange={(e) => setManualQty(e.target.value)} inputMode="numeric" pattern="[0-9]*" placeholder="Elle miktar" className="h-10 sm:h-9" />
            <Button type="submit" variant="outline" size="sm" disabled={pending || manualQty.trim() === ""}>Kaydet</Button>
          </form>
        </section>
      ) : (
        <p className="text-sm text-text-muted">
          {COUNT_TYPE_LABELS[count.count_type]} · {count.branch_name}. İlk ürünü okutun; barkodu olmayan ürünü büyüteçle arayın.
        </p>
      )}

      {/* running list */}
      <section className="space-y-2">
        <div className="flex items-baseline justify-between">
          <h2 className="text-sm font-medium">Sayılanlar <span className="ml-1 text-xs font-normal text-text-muted" data-numeric>{lines.length} ürün · {countedUnits} adet</span></h2>
          <button type="button" onClick={undoLast} disabled={pending || history.length === 0} className="inline-flex min-h-11 items-center gap-1 text-xs text-text-secondary underline underline-offset-4 disabled:opacity-40 sm:min-h-8">
            <Undo2 aria-hidden className="h-3.5 w-3.5" /> Son taramayı geri al
          </button>
        </div>
        {lines.length === 0 ? null : (
          <ul className="divide-y divide-border border-y border-border">
            {lines.map((l) => (
              <li key={l.id} className="flex items-center justify-between gap-3 py-2.5" data-sku={l.sku} data-bucket={l.bucket} data-qty={l.counted_quantity ?? ""}>
                <VariantIdentity v={l} size="sm" />
                <div className="flex shrink-0 items-center gap-2">
                  <ConditionBadge bucket={l.bucket} />
                  <span className="w-8 text-right text-base font-medium" data-numeric>{l.counted_quantity ?? "—"}</span>
                  <Button variant="outline" size="sm" onClick={() => bump(l, l.bucket, 1)} disabled={pending} aria-label={`${l.product_name} ${l.options} bir artır`}>+1</Button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* sticky actions */}
      <div className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-background/95 px-4 py-3 backdrop-blur sm:sticky sm:inset-auto sm:px-0">
        <div className="mx-auto flex max-w-3xl items-center justify-between gap-3">
          {canPost ? (
            <Button variant="ghost" onClick={() => setCancelOpen(true)} disabled={pending}>İptal et</Button>
          ) : <span />}
          <Button variant="accent" onClick={goReview} disabled={pending || lines.length === 0} size="lg">
            {pending ? "…" : "İncelemeye geç"}
          </Button>
        </div>
      </div>

      <Sheet open={searchOpen} onClose={() => { setSearchOpen(false); focusScan(); }} title="Ürün ara" side="right" className="w-[min(28rem,94vw)]">
        <div className="space-y-3 p-4">
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void search();
            }}
            className="flex items-center gap-2"
          >
            <Input value={term} onChange={(e) => setTerm(e.target.value)} placeholder="Ad, model kodu, SKU, barkod, renk, beden" autoFocus autoComplete="off" aria-label="Ürün ara" />
            <Button type="submit" variant="outline" disabled={searching || term.trim().length < 2}>{searching ? "…" : "Ara"}</Button>
          </form>
          <p className="text-2xs text-text-muted">Seçilen ürün <span className="font-medium">{BUCKET_LABELS[bucket]}</span> durumuna +1 sayılır.</p>
          {results ? (
            results.length === 0 ? (
              <p className="text-sm text-text-muted">Eşleşen ürün yok.</p>
            ) : (
              <ul className="divide-y divide-border border-y border-border">
                {results.map((v) => (
                  <li key={v.variant_id} className="flex items-center justify-between gap-3 py-2.5">
                    <VariantIdentity v={v} size="sm" />
                    <Button size="sm" onClick={() => { bump(v, bucket, 1); setSearchOpen(false); }} disabled={pending}>+1</Button>
                  </li>
                ))}
              </ul>
            )
          ) : null}
        </div>
      </Sheet>

      <ConfirmDialog
        open={cancelOpen}
        onClose={() => (pending ? undefined : setCancelOpen(false))}
        title="Bu sayım iptal edilsin mi?"
        description="Sayılanlar kayıt için saklanır; stok değişmez. Yeniden saymak için yeni bir sayım açılır."
        confirmLabel="Sayımı iptal et"
        destructive
        busy={pending}
        onConfirm={doCancel}
      >
        <Input value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="Neden (isteğe bağlı)" aria-label="İptal nedeni" maxLength={500} />
      </ConfirmDialog>
    </div>
  );
}
