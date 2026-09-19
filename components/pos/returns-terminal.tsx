"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Minus, Plus, ScanLine, Search, Trash2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { Notice } from "@/components/catalog/intake/primitives";
import { lookupBarcodeAction, searchItemsAction } from "@/app/app/pos/actions";
import { completeExchangeAction, completeReturnAction, eligibilityAction, findSalesAction } from "@/app/app/pos/iade/actions";
import { PAYMENT_LABELS, PAYMENT_METHODS, cartTotal, lineTotal, round2, type CartLine, type PaymentMethod, type PosCaps, type PosItem, type PosMember, type Register } from "@/lib/pos/model";
import {
  CONDITIONS, CONDITION_LABELS, LINE_STATUS_TEXT, RETURN_TYPE_LABELS, selectionCredit,
  type Condition, type Eligibility, type EligibilityLine, type FoundSale, type LookupMode, type ReturnSelection,
} from "@/lib/pos/returns-model";
import { formatDateTime, formatMoney } from "@/lib/receiving/format";
import { cn } from "@/lib/utils";

/**
 * İade / değişim. Find the sale (receipt number, a barcode on it, or the customer), pick
 * what comes back (quantity, physical condition, reason), choose the outcome the tenant's
 * policy allows — a refund, or an exchange built with the same scan/search the terminal
 * uses — and review before one atomic completion. Everything shown here is the server's
 * eligibility read; the posting RPC re-validates under lock. Completing is an
 * owner/manager act: a sales_staff prepares the case and hands the screen over.
 */

const money = (n: number) => formatMoney(n, "TRY");
type Stage = "lookup" | "items" | "exchange" | "review";
type Outcome = "exchange" | "refund";
type Payment = { id: string; method: PaymentMethod; amount: string };
const MODE_LABEL: Record<LookupMode, string> = { sale_number: "Fiş no", barcode: "Barkod", customer: "Müşteri" };
const MODE_HINT: Record<LookupMode, string> = { sale_number: "Örn. S-2026-000012", barcode: "Fişteki ürünün barkodu", customer: "Ad ya da telefon" };

export function ReturnsTerminal({ registers, members, caps, initialSaleId }: { registers: Register[]; members: PosMember[]; caps: PosCaps; initialSaleId?: string }) {
  const router = useRouter();
  const session = registers.find((r) => r.open_session)?.open_session ?? null;

  const [stage, setStage] = useState<Stage>("lookup");
  const [mode, setMode] = useState<LookupMode>("sale_number");
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<FoundSale[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [elig, setElig] = useState<Eligibility | null>(null);
  const [selection, setSelection] = useState<ReturnSelection[]>([]);
  const [reason, setReason] = useState("");
  const [note, setNote] = useState("");
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [refundMethod, setRefundMethod] = useState<PaymentMethod>("cash");
  const [error, setError] = useState<string | null>(null);
  const [warning, setWarning] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [pending, start] = useTransition();
  // exchange cart
  const [lines, setLines] = useState<CartLine[]>([]);
  const [code, setCode] = useState("");
  const [term, setTerm] = useState("");
  const [results, setResults] = useState<PosItem[] | null>(null);
  const [payments, setPayments] = useState<Payment[]>([{ id: crypto.randomUUID(), method: "cash", amount: "" }]);
  const self = members.find((m) => m.is_self);
  const [salespersonId, setSalespersonId] = useState(self?.user_id ?? "");
  const [ctid, setCtid] = useState(() => crypto.randomUUID());
  const scanRef = useRef<HTMLInputElement>(null);
  const queueRef = useRef<string[]>([]);
  const sendingRef = useRef(false);

  const policy = elig?.policy ?? null;
  const credit = elig ? selectionCredit(elig.lines, selection) : 0;
  const newTotal = cartTotal(lines);
  const difference = round2(newTotal - credit);           // > 0 customer pays, < 0 credit left over
  const paid = round2(payments.reduce((s, p) => s + (parseAmount(p.amount) ?? 0), 0));
  const remaining = round2(difference - paid);
  const hasCash = payments.some((p) => p.method === "cash" && (parseAmount(p.amount) ?? 0) > 0);
  const change = remaining < 0 && hasCash ? -remaining : 0;
  const downgradeRefund = difference < 0 && policy?.downgrade_treatment === "cash_refund" && policy.allow_cash_refund;
  const downgradeBlocked = difference < 0 && !downgradeRefund;
  const reasonMissing = Boolean(policy?.reason_required) && !reason;
  const selectionOk = selection.length > 0 && selection.every((s) => s.quantity > 0);
  const exchangeReady = outcome === "exchange" && lines.length > 0 && !downgradeBlocked && (difference <= 0 || remaining === 0 || (remaining < 0 && hasCash));
  const refundReady = outcome === "refund" && Boolean(policy?.allow_cash_refund) && (refundMethod !== "cash" || Boolean(session));
  const canComplete = selectionOk && !reasonMissing && (exchangeReady || refundReady) && !submitting && !pending;

  // A changed selection / cart / payment is a different document: fresh idempotency key.
  const signature = useMemo(
    () => JSON.stringify([elig?.sale.id, selection, outcome, refundMethod, reason, lines.map((l) => [l.item.variant_id, l.quantity, l.unit_price]), payments.map((p) => [p.method, p.amount]), salespersonId]),
    [elig, selection, outcome, refundMethod, reason, lines, payments, salespersonId],
  );
  useEffect(() => { setCtid(crypto.randomUUID()); }, [signature]);
  useEffect(() => { if (initialSaleId) void openSale(initialSaleId); /* eslint-disable-line react-hooks/exhaustive-deps */ }, [initialSaleId]);

  async function search() {
    const q = query.trim();
    if (q.length < 2) return;
    setSearching(true); setError(null);
    const res = await findSalesAction(mode, q);
    setSearching(false);
    if (!res.ok) { setError(res.error); return; }
    setFound(res.data);
    if (res.data.length === 1 && mode === "sale_number") void openSale(res.data[0].id);
  }
  async function openSale(saleId: string) {
    setError(null);
    const res = await eligibilityAction(saleId);
    if (!res.ok) { setError(res.error); return; }
    if (!res.data) { setError("Satış bulunamadı."); return; }
    setElig(res.data); setSelection([]); setOutcome(null); setLines([]); setReason(""); setNote("");
    setPayments([{ id: crypto.randomUUID(), method: "cash", amount: "" }]);
    setStage("items");
  }
  function setQty(line: EligibilityLine, qty: number) {
    const q = Math.max(0, Math.min(line.returnable_quantity, qty));
    setSelection((prev) => {
      const rest = prev.filter((s) => s.sale_item_id !== line.sale_item_id);
      const cur = prev.find((s) => s.sale_item_id === line.sale_item_id);
      return q === 0 ? rest : [...rest, { sale_item_id: line.sale_item_id, quantity: q, condition: cur?.condition ?? "quarantine" }];
    });
  }
  function setCondition(saleItemId: string, condition: Condition) {
    setSelection((prev) => prev.map((s) => (s.sale_item_id === saleItemId ? { ...s, condition } : s)));
  }

  // ---- exchange cart (same discipline as the terminal: queued scans, server lookups)
  const focusScan = () => window.setTimeout(() => scanRef.current?.focus(), 0);
  function addItem(item: PosItem, delta = 1) {
    setLines((prev) => {
      const i = prev.findIndex((l) => l.item.variant_id === item.variant_id);
      if (i === -1) return [...prev, { item, quantity: Math.max(1, delta), unit_price: item.price }];
      const next = [...prev];
      next[i] = { ...next[i], quantity: Math.max(1, next[i].quantity + delta), item: { ...next[i].item, available: item.available } };
      return next;
    });
    setError(null);
  }
  async function drain() {
    if (sendingRef.current) return;
    sendingRef.current = true;
    try {
      while (queueRef.current.length > 0) {
        const next = queueRef.current.shift()!;
        const res = await lookupBarcodeAction(next);
        if (!res.ok) setWarning(res.error);
        else if (!res.data) setWarning(`Barkod tanınmadı: ${next}`);
        else { setWarning(null); addItem(res.data); }
      }
    } finally { sendingRef.current = false; focusScan(); }
  }
  function scan() {
    const value = code.trim();
    setCode("");
    if (!value) return;
    queueRef.current.push(value);
    start(() => drain());
  }
  async function searchItems() {
    const t = term.trim();
    if (t.length < 2) return;
    const res = await searchItemsAction(t);
    if (!res.ok) setError(res.error); else setResults(res.data);
  }
  function setCartQty(variantId: string, quantity: number) {
    setLines((prev) => prev.map((l) => (l.item.variant_id === variantId ? { ...l, quantity: Math.max(1, Math.min(9999, quantity)) } : l)));
  }
  function setPrice(variantId: string, raw: string) {
    const v = parseAmount(raw);
    setLines((prev) => prev.map((l) => (l.item.variant_id === variantId ? { ...l, unit_price: v === null ? l.unit_price : Math.min(l.item.price, v) } : l)));
  }
  function setPayment(id: string, patch: Partial<Payment>) {
    setPayments((prev) => prev.map((p) => (p.id === id ? { ...p, ...patch } : p)));
  }
  function fillDifference(method: PaymentMethod) {
    setPayments([{ id: crypto.randomUUID(), method, amount: difference > 0 ? difference.toFixed(2) : "" }]);
  }

  function complete() {
    if (!elig || !canComplete) return;
    setSubmitting(true); setError(null);
    start(async () => {
      if (outcome === "refund") {
        const res = await completeReturnAction({
          sale_id: elig.sale.id, client_transaction_id: ctid, items: selection, refund_method: refundMethod,
          reason_code: reason || null, note: note || null, register_session_id: session?.id ?? null,
        });
        if (!res.ok) { setError(res.error); setSubmitting(false); return; }
        router.push(`/app/pos/iade/${res.data.return_id}`);
        return;
      }
      if (!session) { setError("Değişim için açık bir kasa oturumu gerekir."); setSubmitting(false); return; }
      const res = await completeExchangeAction({
        register_session_id: session.id, sale_id: elig.sale.id, client_transaction_id: ctid, return_items: selection,
        new_lines: lines.map((l) => ({ variant_id: l.item.variant_id, quantity: l.quantity, unit_price: l.unit_price, expected_list_price: l.item.price })),
        payments: payments.map((p) => ({ method: p.method, amount: parseAmount(p.amount) ?? 0 })).filter((p) => p.amount > 0),
        reason_code: reason || null, note: note || null, customer_id: elig.sale.customer_id, salesperson_id: salespersonId || null,
      });
      if (!res.ok) { setError(res.error); setSubmitting(false); return; }
      router.push(`/app/pos/iade/${res.data.return_id}`);
    });
  }

  // ------------------------------------------------------------------ panels
  const lookupPanel = (
    <section className="space-y-3" data-testid="ret-lookup">
      <div className="grid grid-cols-3 border border-line text-xs" role="tablist" aria-label="Arama türü">
        {(Object.keys(MODE_LABEL) as LookupMode[]).map((m) => (
          <button key={m} role="tab" aria-selected={mode === m} onClick={() => { setMode(m); setFound(null); }}
            className={cn("h-10 border-r border-line last:border-r-0", mode === m ? "bg-primary text-primary-foreground" : "text-ink-70")}>
            {MODE_LABEL[m]}
          </button>
        ))}
      </div>
      <form onSubmit={(e) => { e.preventDefault(); void search(); }} className="flex items-end gap-2">
        <div className="flex-1">
          <Label htmlFor="ret-query" className="text-2xs">Satışı bul</Label>
          <div className="relative">
            {mode === "barcode" ? <ScanLine aria-hidden className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" /> : <Search aria-hidden className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />}
            <Input id="ret-query" value={query} onChange={(e) => setQuery(e.target.value)} placeholder={MODE_HINT[mode]} autoFocus autoComplete="off" inputMode={mode === "barcode" ? "numeric" : "text"} className="h-12 pl-8 text-base sm:h-10" />
          </div>
        </div>
        <Button type="submit" variant="outline" size="md" disabled={searching || query.trim().length < 2}>{searching ? "…" : "Ara"}</Button>
      </form>
      {found ? (
        found.length === 0 ? <p className="text-xs text-muted">Eşleşen satış yok.</p> : (
          <ul className="divide-y divide-line border-y border-line" data-testid="ret-results">
            {found.map((s) => (
              <li key={s.id}>
                <button type="button" onClick={() => openSale(s.id)} className="flex w-full items-center gap-3 px-1 py-2.5 text-left hover:bg-panel">
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium text-ink" data-numeric>{s.sale_number} {s.status === "voided" ? <span className="text-danger">· iptal</span> : null}{s.is_exchange_replacement ? <span className="text-muted"> · değişim fişi</span> : null}</p>
                    <p className="truncate text-2xs text-muted" data-numeric>{formatDateTime(s.occurred_at)} · {s.item_count} adet{s.returned_count > 0 ? ` · ${s.returned_count} iade edildi` : ""}{s.customer_name ? ` · ${s.customer_name}` : ""}</p>
                  </div>
                  <span className="text-sm" data-numeric>{money(s.total)}</span>
                </button>
              </li>
            ))}
          </ul>
        )
      ) : null}
    </section>
  );

  const itemsPanel = elig ? (
    <section className="space-y-4" data-testid="ret-items">
      <div className="border border-line bg-panel/40 px-3 py-2 text-xs" data-testid="ret-sale">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <span className="text-sm font-medium text-ink" data-numeric>{elig.sale.sale_number}</span>
          <button type="button" className="text-ink-70 underline-offset-2 hover:underline" onClick={() => { setElig(null); setStage("lookup"); }}>Başka satış</button>
        </div>
        <p className="text-muted" data-numeric>{formatDateTime(elig.sale.occurred_at)} · {elig.sale.branch_name} · {money(elig.sale.total)}{elig.sale.customer_name ? ` · ${elig.sale.customer_name}` : " · kayıtsız müşteri"}</p>
        <p className={cn("mt-1", elig.policy.window_expired ? "text-danger" : "text-success")} data-testid="ret-policy">
          {elig.policy.window_expired ? "Değişim süresi dolmuş" : `Değişim süresi içinde · ${elig.policy.days_left} gün kaldı (${elig.policy.exchange_window_days} gün)`}
          {!elig.policy.allow_cash_refund ? " · para iadesi yok, yalnız değişim" : ""}
        </p>
        {elig.returns.length > 0 ? <p className="mt-1 text-muted">Önceki iadeler: {elig.returns.map((r) => r.return_number).join(", ")}</p> : null}
      </div>

      <ul className="divide-y divide-line border-y border-line">
        {elig.lines.map((l) => {
          const sel = selection.find((s) => s.sale_item_id === l.sale_item_id);
          const qty = sel?.quantity ?? 0;
          const eligible = l.status === "ELIGIBLE";
          return (
            <li key={l.sale_item_id} className="space-y-1.5 py-2.5" data-ret-line={l.sku} data-qty={qty}>
              <div className="flex items-start gap-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-ink">{l.product_name}</p>
                  <p className="truncate text-2xs text-muted">{l.options || "Tek seçenek"} · <span data-numeric>{l.sku}</span> · <span data-numeric>{l.quantity} × {money(l.unit_price_at_sale)}</span>{l.returned_quantity > 0 ? ` · ${l.returned_quantity} iade edildi` : ""}</p>
                  <p className={cn("text-2xs", eligible ? "text-success" : "text-danger")} data-testid="ret-line-status">{LINE_STATUS_TEXT[l.status]}{eligible ? ` · ${l.returnable_quantity} adet iade edilebilir` : ""}</p>
                </div>
              </div>
              {eligible ? (
                <div className="flex flex-wrap items-center gap-2 pl-0">
                  <div className="flex items-center border border-line-strong">
                    <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => setQty(l, qty - 1)} aria-label="Bir azalt"><Minus className="h-4 w-4" /></button>
                    <input aria-label="İade adedi" inputMode="numeric" value={qty} onChange={(e) => setQty(l, Number(e.target.value.replace(/\D/g, "")) || 0)} className="h-11 w-12 border-x border-line-strong bg-transparent text-center text-sm sm:h-8" data-numeric />
                    <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => setQty(l, qty + 1)} aria-label="Bir artır" disabled={qty >= l.returnable_quantity}><Plus className="h-4 w-4" /></button>
                  </div>
                  {qty > 0 ? (
                    <Select value={sel?.condition ?? "quarantine"} onChange={(e) => setCondition(l.sale_item_id, e.target.value as Condition)} className="h-11 w-52 sm:h-8" aria-label="Ürün durumu">
                      {CONDITIONS.filter((c) => c === "quarantine" || caps.canCompleteReturns).map((c) => <option key={c} value={c}>{CONDITION_LABELS[c]}</option>)}
                    </Select>
                  ) : null}
                </div>
              ) : null}
            </li>
          );
        })}
      </ul>

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="ret-reason">İade nedeni{elig.policy.reason_required ? "" : " (isteğe bağlı)"}</Label>
          <Select id="ret-reason" value={reason} onChange={(e) => setReason(e.target.value)} className="h-11 sm:h-9">
            <option value="">Seçin</option>
            {elig.reasons.map((r) => <option key={r.code} value={r.code}>{r.label}</option>)}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="ret-note">Not</Label>
          <Input id="ret-note" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} className="h-11 sm:h-9" />
        </div>
      </div>

      <div className="space-y-2" data-testid="ret-outcome">
        <p className="text-xs text-muted">Seçilen iade değeri: <span className="font-medium text-ink" data-numeric>{money(credit)}</span></p>
        <div className="flex flex-wrap gap-2">
          <Button type="button" variant={outcome === "exchange" ? "solid" : "outline"} size="sm" onClick={() => { setOutcome("exchange"); setStage("exchange"); focusScan(); }} disabled={!selectionOk || !elig.policy.allow_exchange || !session} data-testid="ret-choose-exchange">Değişim</Button>
          <Button type="button" variant={outcome === "refund" ? "solid" : "outline"} size="sm" onClick={() => { setOutcome("refund"); setStage("review"); }} disabled={!selectionOk || !elig.policy.allow_cash_refund} data-testid="ret-choose-refund">Para iadesi</Button>
        </div>
        {!elig.policy.allow_cash_refund ? <p className="text-2xs text-muted">Bu işletmede para iadesi yapılmaz; ürün yalnız değişimle geri alınır.</p> : null}
        {!session ? <p className="text-2xs text-danger">Açık kasa oturumu yok: değişim ve nakit iade için yönetici kasayı açmalı.</p> : null}
      </div>
    </section>
  ) : null;

  const exchangePanel = elig ? (
    <section className="space-y-3" data-testid="ret-exchange">
      <form onSubmit={(e) => { e.preventDefault(); scan(); }} className="flex items-end gap-2">
        <div className="flex-1">
          <Label htmlFor="ret-scan" className="text-2xs">Yeni ürünü okut</Label>
          <div className="relative">
            <ScanLine aria-hidden className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
            <Input id="ret-scan" ref={scanRef} value={code} onChange={(e) => setCode(e.target.value)} autoComplete="off" inputMode="numeric" placeholder="Barkodu okutun ve Enter" className="h-12 pl-8 text-base sm:h-10" />
          </div>
        </div>
        <Button type="submit" variant="outline" size="md" disabled={!code.trim()}>Ekle</Button>
      </form>
      {warning ? <Notice tone="warning">{warning}</Notice> : null}
      <form onSubmit={(e) => { e.preventDefault(); void searchItems(); }} className="flex items-end gap-2">
        <div className="flex-1">
          <Label htmlFor="ret-search" className="text-2xs">Ürün ara</Label>
          <Input id="ret-search" value={term} onChange={(e) => setTerm(e.target.value)} placeholder="Ürün adı, SKU veya barkod" className="h-11 sm:h-9" autoComplete="off" />
        </div>
        <Button type="submit" variant="outline" size="sm" disabled={term.trim().length < 2}>Ara</Button>
      </form>
      {results ? (
        results.length === 0 ? <p className="text-xs text-muted">Eşleşen ürün yok.</p> : (
          <ul className="divide-y divide-line border-y border-line" data-testid="ret-search-results">
            {results.map((it) => (
              <li key={it.variant_id} className="flex items-center gap-3 py-2">
                <ProductThumb url={it.thumbnail_url} alt={it.product_name} size="sm" />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-ink">{it.product_name}</p>
                  <p className="truncate text-2xs text-muted">{[it.color, it.size].filter(Boolean).join(" / ") || it.options || "Tek seçenek"} · <span data-numeric>{it.sku}</span></p>
                  <p className={cn("text-2xs", it.available > 0 ? "text-muted" : "text-danger")} data-numeric>{it.available > 0 ? `${it.available} adet mevcut` : "stokta yok"}</p>
                </div>
                <span className="text-sm" data-numeric>{money(it.price)}</span>
                <Button type="button" variant="outline" size="sm" onClick={() => addItem(it)} disabled={it.available <= 0} aria-label={`${it.sku} sepete ekle`}><Plus className="h-4 w-4" /></Button>
              </li>
            ))}
          </ul>
        )
      ) : null}

      <div className="space-y-2" data-testid="ret-cart">
        <div className="flex items-baseline justify-between"><h3 className="text-sm font-medium tracking-tightish">Yeni ürünler</h3><span className="text-xs text-muted" data-numeric>{lines.reduce((s, l) => s + l.quantity, 0)} adet</span></div>
        {lines.length === 0 ? <p className="border border-dashed border-line-strong px-4 py-6 text-center text-xs text-muted">Değişim için ürün okutun ya da arayın.</p> : (
          <ul className="divide-y divide-line border-y border-line">
            {lines.map((l) => (
              <li key={l.item.variant_id} className="space-y-1.5 py-2.5" data-cart-line={l.item.sku} data-qty={l.quantity}>
                <div className="flex items-start gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-ink">{l.item.product_name}</p>
                    <p className="truncate text-2xs text-muted">{[l.item.color, l.item.size].filter(Boolean).join(" / ") || l.item.options || "Tek seçenek"} · <span data-numeric>{l.item.sku}</span></p>
                    {l.quantity > l.item.available ? <p className="text-2xs text-danger" data-numeric>Stokta {l.item.available} adet var</p> : null}
                  </div>
                  <span className="text-sm font-medium" data-numeric>{money(lineTotal(l))}</span>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  <div className="flex items-center border border-line-strong">
                    <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => (l.quantity === 1 ? setLines((p) => p.filter((x) => x.item.variant_id !== l.item.variant_id)) : setCartQty(l.item.variant_id, l.quantity - 1))} aria-label="Bir azalt"><Minus className="h-4 w-4" /></button>
                    <input aria-label="Adet" inputMode="numeric" value={l.quantity} onChange={(e) => setCartQty(l.item.variant_id, Number(e.target.value.replace(/\D/g, "")) || 1)} className="h-11 w-12 border-x border-line-strong bg-transparent text-center text-sm sm:h-8" data-numeric />
                    <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => setCartQty(l.item.variant_id, l.quantity + 1)} aria-label="Bir artır"><Plus className="h-4 w-4" /></button>
                  </div>
                  {caps.canDiscount ? (
                    <label className="flex items-center gap-1 text-2xs text-muted">Birim
                      <input aria-label="Birim fiyat" inputMode="decimal" defaultValue={l.unit_price.toFixed(2)} onBlur={(e) => setPrice(l.item.variant_id, e.target.value)} className="h-11 w-24 border border-line-strong bg-transparent px-2 text-right text-sm sm:h-8" data-numeric />
                    </label>
                  ) : null}
                  <span className="grow" />
                  <button type="button" onClick={() => setLines((p) => p.filter((x) => x.item.variant_id !== l.item.variant_id))} className="flex h-11 w-11 items-center justify-center text-muted sm:h-8 sm:w-8" aria-label="Satırı kaldır"><Trash2 className="h-4 w-4" /></button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  ) : null;

  const reviewPanel = elig ? (
    <section className="space-y-4" data-testid="ret-review">
      <dl className="divide-y divide-line border-y border-line text-sm">
        <div className="flex justify-between py-2"><dt className="text-muted">İşlem</dt><dd>{outcome ? RETURN_TYPE_LABELS[outcome] : "—"}</dd></div>
        <div className="flex justify-between py-2"><dt className="text-muted">İade edilen</dt><dd className="text-right" data-numeric>
          {selection.map((s) => { const l = elig.lines.find((x) => x.sale_item_id === s.sale_item_id)!; return <div key={s.sale_item_id}>{s.quantity} × {l.product_name} · {CONDITION_LABELS[s.condition]}</div>; })}
        </dd></div>
        <div className="flex justify-between py-2"><dt className="text-muted">İade değeri</dt><dd data-numeric data-testid="ret-credit">{money(credit)}</dd></div>
        {outcome === "exchange" ? (
          <>
            <div className="flex justify-between py-2"><dt className="text-muted">Yeni ürünler</dt><dd data-numeric data-testid="ret-new-total">{money(newTotal)}</dd></div>
            <div className="flex justify-between py-2 text-base font-medium"><dt>{difference > 0 ? "Müşteri öder" : difference < 0 ? "Müşteriye kalan" : "Fark"}</dt><dd data-numeric data-testid="ret-difference">{money(Math.abs(difference))}</dd></div>
          </>
        ) : (
          <div className="flex justify-between py-2 text-base font-medium"><dt>İade tutarı</dt><dd data-numeric data-testid="ret-refund">{money(credit)}</dd></div>
        )}
        {reason ? <div className="flex justify-between py-2"><dt className="text-muted">Neden</dt><dd>{elig.reasons.find((r) => r.code === reason)?.label ?? reason}</dd></div> : null}
      </dl>

      {outcome === "refund" ? (
        <div className="space-y-1.5">
          <Label htmlFor="ret-refund-method">İade yöntemi</Label>
          <Select id="ret-refund-method" value={refundMethod} onChange={(e) => setRefundMethod(e.target.value as PaymentMethod)} className="h-11 sm:h-9">
            {PAYMENT_METHODS.map((m) => <option key={m} value={m}>{m === "cash" ? "Nakit (kasadan)" : m === "card" ? "Kart (orijinal ödemeye)" : PAYMENT_LABELS[m]}</option>)}
          </Select>
          {refundMethod === "cash" && !session ? <p className="text-2xs text-danger">Nakit iade için açık bir kasa oturumu gerekir.</p> : null}
          {refundMethod !== "cash" ? <p className="text-2xs text-muted">Kayıt olarak işlenir; ödeme sağlayıcısı iadesi bu sürümde yapılmaz.</p> : null}
        </div>
      ) : null}

      {outcome === "exchange" && difference > 0 ? (
        <div className="space-y-2" data-testid="ret-payments">
          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="outline" size="sm" onClick={() => fillDifference("cash")}>Farkı nakit</Button>
            <Button type="button" variant="outline" size="sm" onClick={() => fillDifference("card")}>Farkı kart</Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setPayments((p) => [...p, { id: crypto.randomUUID(), method: "card", amount: remaining > 0 ? remaining.toFixed(2) : "" }])}>Bölünmüş ödeme +</Button>
          </div>
          {payments.map((p) => (
            <div key={p.id} className="flex items-center gap-2">
              <Select value={p.method} onChange={(e) => setPayment(p.id, { method: e.target.value as PaymentMethod })} className="h-11 w-28 sm:h-9" aria-label="Ödeme yöntemi">
                {PAYMENT_METHODS.map((m) => <option key={m} value={m}>{PAYMENT_LABELS[m]}</option>)}
              </Select>
              <Input value={p.amount} onChange={(e) => setPayment(p.id, { amount: e.target.value })} inputMode="decimal" placeholder="0,00" className="h-11 flex-1 text-right sm:h-9" aria-label="Tutar" />
              {payments.length > 1 ? <button type="button" onClick={() => setPayments((prev) => prev.filter((x) => x.id !== p.id))} className="flex h-11 w-11 items-center justify-center text-muted sm:h-9 sm:w-9" aria-label="Ödemeyi kaldır"><X className="h-4 w-4" /></button> : null}
            </div>
          ))}
          <p className="text-xs" data-testid="ret-remaining">
            {remaining > 0 ? <span className="text-danger">Kalan: <span data-numeric>{money(remaining)}</span></span>
              : remaining < 0 && hasCash ? <span className="text-success">Para üstü: <span data-numeric>{money(change)}</span></span>
              : remaining < 0 ? <span className="text-danger">Fazla ödeme yalnız nakitle para üstü olarak verilebilir.</span>
              : <span className="text-success">Ödeme tam.</span>}
          </p>
        </div>
      ) : null}
      {outcome === "exchange" && difference < 0 ? (
        downgradeRefund
          ? <Notice tone="info">Yeni ürün daha ucuz: fark <strong data-numeric>{money(-difference)}</strong> kasadan nakit iade edilir.</Notice>
          : <Notice tone="danger">Yeni ürün iade edilen üründen ucuz; bu işletmede fark iadesi yapılamıyor. Eşit ya da daha pahalı bir ürün seçin.</Notice>
      ) : null}
      {outcome === "exchange" ? (
        <div className="space-y-1.5">
          <Label htmlFor="ret-salesperson">Satışı yapan</Label>
          <Select id="ret-salesperson" value={salespersonId} onChange={(e) => setSalespersonId(e.target.value)} className="h-11 sm:h-9">
            {members.filter((m) => m.can_sell).map((m) => <option key={m.user_id} value={m.user_id}>{m.full_name ?? "—"}{m.is_self ? " (ben)" : ""}</option>)}
          </Select>
        </div>
      ) : null}
      {reasonMissing ? <Notice tone="warning">Bu işletmede iade nedeni zorunlu.</Notice> : null}
      {error ? <Notice tone="danger">{error}</Notice> : null}
      {caps.canCompleteReturns ? (
        <Button type="button" size="lg" className="w-full" onClick={complete} disabled={!canComplete} data-testid="ret-complete">
          {submitting ? "İşleniyor…" : outcome === "refund" ? `İadeyi tamamla · ${money(credit)}` : `Değişimi tamamla${difference > 0 ? ` · ${money(difference)}` : ""}`}
        </Button>
      ) : (
        <Notice tone="info">Yönetici onayı gerekir: iade ve değişimi işletme sahibi ya da yönetici tamamlar. Ekranı yöneticiye devredin.</Notice>
      )}
    </section>
  ) : null;

  const stages: Stage[] = ["lookup", "items", "exchange", "review"];
  const stageLabel: Record<Stage, string> = { lookup: "Satış", items: "Ürünler", exchange: "Değişim", review: "Özet" };
  const stageEnabled = (s: Stage) => s === "lookup" || (Boolean(elig) && (s === "items" || (s === "exchange" && outcome === "exchange") || (s === "review" && outcome !== null)));
  const next = stage === "items" ? null : stage === "exchange" ? "review" : null;

  return (
    <div className="space-y-4">
      {error && stage !== "review" ? <Notice tone="danger">{error}</Notice> : null}

      {/* desktop / tablet: case on the left, outcome on the right */}
      <div className="hidden gap-6 lg:grid lg:grid-cols-[1.1fr_1fr]">
        <div>{stage === "lookup" || !elig ? lookupPanel : itemsPanel}</div>
        <div>{outcome === "exchange" && stage !== "review" ? exchangePanel : outcome ? reviewPanel : <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">Satışı bulun, iade edilecek ürünleri ve işlemi seçin.</p>}
          {outcome === "exchange" && stage !== "review" ? <div className="mt-4"><Button type="button" size="lg" className="w-full" onClick={() => setStage("review")} disabled={lines.length === 0} data-testid="ret-next">Özete geç · {money(newTotal)}</Button></div> : null}
        </div>
      </div>

      {/* phone: one stage at a time */}
      <div className="lg:hidden">
        <div className="mb-3 grid grid-cols-4 border border-line text-xs" role="tablist" aria-label="Adımlar">
          {stages.map((s) => (
            <button key={s} role="tab" aria-selected={stage === s} onClick={() => stageEnabled(s) && setStage(s)} disabled={!stageEnabled(s)}
              className={cn("h-11 border-r border-line last:border-r-0", stage === s ? "bg-primary text-primary-foreground" : stageEnabled(s) ? "text-ink-70" : "text-muted/50")}>
              {stageLabel[s]}
            </button>
          ))}
        </div>
        <div className="pb-24">{stage === "lookup" ? lookupPanel : stage === "items" ? itemsPanel : stage === "exchange" ? exchangePanel : reviewPanel}</div>
        {next ? (
          <div className="fixed inset-x-0 bottom-0 z-20 border-t border-line bg-surface px-4 py-3">
            <Button type="button" size="lg" className="w-full" onClick={() => setStage(next)} disabled={lines.length === 0} data-testid="ret-next">Özete geç · {money(newTotal)}</Button>
          </div>
        ) : null}
      </div>
    </div>
  );
}

function parseAmount(raw: string): number | null {
  const t = raw.trim();
  if (!t) return null;
  const n = Number(t.includes(",") ? t.replace(/\./g, "").replace(",", ".") : t);
  return Number.isFinite(n) && n >= 0 ? round2(n) : null;
}
