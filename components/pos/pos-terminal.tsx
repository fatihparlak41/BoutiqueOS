"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Minus, Plus, ScanLine, Search, Trash2, Undo2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { Notice } from "@/components/catalog/intake/primitives";
import { completeSaleAction, lookupBarcodeAction, searchCustomersAction, searchItemsAction } from "@/app/app/pos/actions";
import {
  PAYMENT_LABELS,
  PAYMENT_METHODS,
  cartTotal,
  lineTotal,
  round2,
  type CartLine,
  type PaymentMethod,
  type PosCaps,
  type PosCustomer,
  type PosItem,
  type PosMember,
  type Register,
} from "@/lib/pos/model";
import { formatMoney } from "@/lib/receiving/format";
import { cn } from "@/lib/utils";
import { SessionBar } from "./session-panel";

/**
 * The terminal. Three columns on a desktop (find → cart → pay), three stages on a phone.
 * The scan field owns focus: every Enter takes the field's value, clears it at once and
 * queues the code; codes are resolved one after another in the order they were read, so a
 * fast scanner never loses or reorders a read. A known code adds or increments the line,
 * an unknown code is a warning and creates nothing.
 *
 * The cart is a proposal. Prices shown are the server's list prices; a lowered price is
 * sent as the requested unit price and the sale RPC decides whether this person may
 * grant it. Totals here are for the eye — the database computes the ones that count.
 */

const money = (n: number) => formatMoney(n, "TRY");
type Payment = { id: string; method: PaymentMethod; amount: string };
type Stage = "items" | "cart" | "pay";

export function PosTerminal({ registers, members, caps }: { registers: Register[]; members: PosMember[]; caps: PosCaps }) {
  const router = useRouter();
  const openRegisters = registers.filter((r) => r.open_session);
  const [registerId, setRegisterId] = useState(openRegisters[0]?.id ?? "");
  const register = openRegisters.find((r) => r.id === registerId) ?? openRegisters[0];
  const session = register?.open_session ?? null;

  const [stage, setStage] = useState<Stage>("items");
  const [lines, setLines] = useState<CartLine[]>([]);
  const [last, setLast] = useState<PosItem | null>(null);
  const [history, setHistory] = useState<string[]>([]);
  const [warning, setWarning] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [term, setTerm] = useState("");
  const [results, setResults] = useState<PosItem[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [customer, setCustomer] = useState<PosCustomer | null>(null);
  const [customerTerm, setCustomerTerm] = useState("");
  const [customerResults, setCustomerResults] = useState<PosCustomer[] | null>(null);
  const self = members.find((m) => m.is_self);
  const [salespersonId, setSalespersonId] = useState(self?.user_id ?? "");
  const [payments, setPayments] = useState<Payment[]>([{ id: crypto.randomUUID(), method: "cash", amount: "" }]);
  const [note, setNote] = useState("");
  const [ctid, setCtid] = useState(() => crypto.randomUUID());
  const [submitting, setSubmitting] = useState(false);
  const [pending, start] = useTransition();
  const scanRef = useRef<HTMLInputElement>(null);
  const queueRef = useRef<string[]>([]);
  const sendingRef = useRef(false);

  const total = cartTotal(lines);
  const paid = round2(payments.reduce((s, p) => s + (parseAmount(p.amount) ?? 0), 0));
  const remaining = round2(total - paid);
  const hasCash = payments.some((p) => p.method === "cash" && (parseAmount(p.amount) ?? 0) > 0);
  const change = remaining < 0 && hasCash ? -remaining : 0;
  const payable = lines.length > 0 && (remaining === 0 || (remaining < 0 && hasCash));
  const count = lines.reduce((s, l) => s + l.quantity, 0);

  // A changed cart or payment set is a different sale: give it a fresh idempotency key.
  // An unchanged retry (network hiccup) keeps the key and replays the first result.
  const signature = useMemo(
    () => JSON.stringify([lines.map((l) => [l.item.variant_id, l.quantity, l.unit_price]), payments.map((p) => [p.method, p.amount]), customer?.id, salespersonId]),
    [lines, payments, customer, salespersonId],
  );
  useEffect(() => {
    setCtid(crypto.randomUUID());
  }, [signature]);

  const focusScan = () => window.setTimeout(() => scanRef.current?.focus(), 0);

  function addItem(item: PosItem, delta = 1) {
    setLines((prev) => {
      const i = prev.findIndex((l) => l.item.variant_id === item.variant_id);
      if (i === -1) return [...prev, { item, quantity: Math.max(1, delta), unit_price: item.price }];
      const next = [...prev];
      next[i] = { ...next[i], quantity: Math.max(1, next[i].quantity + delta), item: { ...next[i].item, available: item.available } };
      return next;
    });
    setLast(item);
    setHistory((h) => [item.variant_id, ...h].slice(0, 50));
    setError(null);
  }
  function setQty(variantId: string, quantity: number) {
    setLines((prev) => prev.map((l) => (l.item.variant_id === variantId ? { ...l, quantity: Math.max(1, Math.min(9999, quantity)) } : l)));
  }
  function setPrice(variantId: string, raw: string) {
    const v = parseAmount(raw);
    setLines((prev) => prev.map((l) => (l.item.variant_id === variantId ? { ...l, unit_price: v === null ? l.unit_price : Math.min(l.item.price, v) } : l)));
  }
  function removeLine(variantId: string) {
    setLines((prev) => prev.filter((l) => l.item.variant_id !== variantId));
  }
  function undoLast() {
    const id = history[0];
    if (!id) return;
    setHistory((h) => h.slice(1));
    setLines((prev) =>
      prev
        .map((l) => (l.item.variant_id === id ? { ...l, quantity: l.quantity - 1 } : l))
        .filter((l) => l.quantity > 0),
    );
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
        else {
          setWarning(null);
          addItem(res.data);
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
    queueRef.current.push(value);
    start(() => drain());
  }

  async function search() {
    const t = term.trim();
    if (t.length < 2) return;
    setSearching(true);
    const res = await searchItemsAction(t);
    setSearching(false);
    if (!res.ok) setError(res.error);
    else setResults(res.data);
  }
  async function findCustomer() {
    const res = await searchCustomersAction(customerTerm);
    if (res.ok) setCustomerResults(res.data);
  }

  function fillRemaining(method: PaymentMethod) {
    setPayments([{ id: crypto.randomUUID(), method, amount: total.toFixed(2) }]);
  }
  function setPayment(id: string, patch: Partial<Payment>) {
    setPayments((prev) => prev.map((p) => (p.id === id ? { ...p, ...patch } : p)));
  }

  function complete() {
    if (!session || submitting || !payable) return;
    setSubmitting(true);
    setError(null);
    start(async () => {
      const res = await completeSaleAction({
        register_session_id: session.id,
        client_transaction_id: ctid,
        lines: lines.map((l) => ({ variant_id: l.item.variant_id, quantity: l.quantity, unit_price: l.unit_price, expected_list_price: l.item.price })),
        payments: payments.map((p) => ({ method: p.method, amount: parseAmount(p.amount) ?? 0 })).filter((p) => p.amount > 0),
        customer_id: customer?.id ?? null,
        salesperson_id: salespersonId || null,
        note: note || null,
      });
      if (!res.ok) {
        setError(res.error);
        setSubmitting(false);
        return;
      }
      router.push(`/app/pos/satis/${res.data.sale_id}`);
    });
  }

  if (!session || !register) return null;

  // ------------------------------------------------------------------ panels
  const findPanel = (
    <section className="space-y-3" data-testid="pos-find">
      <form
        onSubmit={(e) => {
          e.preventDefault();
          scan();
        }}
        className="flex items-end gap-2"
      >
        <div className="flex-1">
          <Label htmlFor="pos-scan" className="text-2xs">Barkod okut</Label>
          <div className="relative">
            <ScanLine aria-hidden className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
            <Input
              id="pos-scan"
              ref={scanRef}
              value={code}
              onChange={(e) => setCode(e.target.value)}
              autoFocus
              autoComplete="off"
              inputMode="numeric"
              placeholder="Barkodu okutun ve Enter"
              className="h-12 pl-8 text-base sm:h-10"
            />
          </div>
        </div>
        <Button type="submit" variant="outline" size="md" disabled={!code.trim()}>Ekle</Button>
      </form>
      {warning ? <Notice tone="warning">{warning}</Notice> : null}
      {last ? (
        <div className="flex items-center gap-3 border border-success/30 bg-success-muted/40 px-3 py-2 text-xs" data-testid="last-added">
          <ProductThumb url={last.thumbnail_url} alt={last.product_name} size="sm" />
          <div className="min-w-0 flex-1">
            <p className="truncate font-medium text-ink">{last.product_name}</p>
            <p className="truncate text-muted">{last.options || "Tek varyant"} · <span data-numeric>{last.sku}</span></p>
          </div>
          <span className="text-sm font-medium" data-numeric>{money(last.price)}</span>
          <button type="button" onClick={undoLast} className="text-xs text-ink-70 underline-offset-2 hover:underline" aria-label="Son eklemeyi geri al">
            <Undo2 className="h-4 w-4" />
          </button>
        </div>
      ) : null}
      <form
        onSubmit={(e) => {
          e.preventDefault();
          search();
        }}
        className="flex items-end gap-2"
      >
        <div className="flex-1">
          <Label htmlFor="pos-search" className="text-2xs">Ürün ara</Label>
          <div className="relative">
            <Search aria-hidden className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
            <Input id="pos-search" value={term} onChange={(e) => setTerm(e.target.value)} placeholder="Ürün adı, SKU veya barkod" className="h-11 pl-8 sm:h-9" autoComplete="off" />
          </div>
        </div>
        <Button type="submit" variant="outline" size="sm" disabled={searching || term.trim().length < 2}>{searching ? "…" : "Ara"}</Button>
      </form>
      {results ? (
        results.length === 0 ? (
          <p className="text-xs text-muted">Eşleşen ürün yok.</p>
        ) : (
          <ul className="divide-y divide-line border-y border-line" data-testid="search-results">
            {results.map((it) => (
              <li key={it.variant_id} className="flex items-center gap-3 py-2">
                <ProductThumb url={it.thumbnail_url} alt={it.product_name} size="sm" />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-ink">{it.product_name}</p>
                  <p className="truncate text-2xs text-muted">
                    {[it.color, it.size].filter(Boolean).join(" / ") || it.options || "Tek varyant"} · <span data-numeric>{it.sku}</span>
                    {it.primary_barcode ? <> · <span data-numeric>{it.primary_barcode}</span></> : null}
                  </p>
                  <p className={cn("text-2xs", it.available > 0 ? "text-muted" : "text-danger")} data-numeric>
                    {it.available > 0 ? `${it.available} adet mevcut` : "stokta yok"}
                  </p>
                </div>
                <span className="text-sm" data-numeric>{money(it.price)}</span>
                <Button type="button" variant="outline" size="sm" onClick={() => addItem(it)} disabled={it.available <= 0} aria-label={`${it.sku} sepete ekle`}>
                  <Plus className="h-4 w-4" />
                </Button>
              </li>
            ))}
          </ul>
        )
      ) : null}
    </section>
  );

  const cartPanel = (
    <section className="space-y-2" data-testid="pos-cart">
      <div className="flex items-baseline justify-between">
        <h3 className="text-sm font-medium tracking-tightish">Sepet</h3>
        <span className="text-xs text-muted" data-numeric>{count} adet · {lines.length} satır</span>
      </div>
      {lines.length === 0 ? (
        <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">Sepet boş. Barkod okutun ya da ürün arayın.</p>
      ) : (
        <ul className="divide-y divide-line border-y border-line">
          {lines.map((l) => {
            const short = l.quantity > l.item.available;
            const minPrice = round2(l.item.price * (1 - caps.maxDiscountPct / 100));
            return (
              <li key={l.item.variant_id} className="space-y-1.5 py-2.5" data-cart-line={l.item.sku} data-qty={l.quantity}>
                <div className="flex items-start gap-3">
                  <ProductThumb url={l.item.thumbnail_url} alt={l.item.product_name} size="sm" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-ink">{l.item.product_name}</p>
                    <p className="truncate text-2xs text-muted">
                      {[l.item.color, l.item.size].filter(Boolean).join(" / ") || l.item.options || "Tek varyant"} · <span data-numeric>{l.item.sku}</span>
                    </p>
                    {short ? <p className="text-2xs text-danger" data-numeric>Stokta {l.item.available} adet var</p> : null}
                  </div>
                  <span className="text-sm font-medium" data-numeric>{money(lineTotal(l))}</span>
                </div>
                <div className="flex flex-wrap items-center gap-2 pl-[3.25rem]">
                  <div className="flex items-center border border-line-strong">
                    <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => (l.quantity === 1 ? removeLine(l.item.variant_id) : setQty(l.item.variant_id, l.quantity - 1))} aria-label="Bir azalt">
                      <Minus className="h-4 w-4" />
                    </button>
                    <input
                      aria-label="Adet"
                      inputMode="numeric"
                      value={l.quantity}
                      onChange={(e) => setQty(l.item.variant_id, Number(e.target.value.replace(/\D/g, "")) || 1)}
                      className="h-11 w-12 border-x border-line-strong bg-transparent text-center text-sm sm:h-8"
                      data-numeric
                    />
                    <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => setQty(l.item.variant_id, l.quantity + 1)} aria-label="Bir artır">
                      <Plus className="h-4 w-4" />
                    </button>
                  </div>
                  {caps.canDiscount ? (
                    <label className="flex items-center gap-1 text-2xs text-muted">
                      Birim
                      <input
                        aria-label="Birim fiyat"
                        inputMode="decimal"
                        defaultValue={l.unit_price.toFixed(2)}
                        onBlur={(e) => setPrice(l.item.variant_id, e.target.value)}
                        className={cn("h-11 w-24 border border-line-strong bg-transparent px-2 text-right text-sm sm:h-8", l.unit_price < minPrice && "border-danger text-danger")}
                        data-numeric
                      />
                      {l.unit_price < l.item.price ? <span className="text-danger" data-numeric>−{money(round2((l.item.price - l.unit_price) * l.quantity))}</span> : null}
                    </label>
                  ) : (
                    <span className="text-2xs text-muted" data-numeric>{money(l.unit_price)} / adet</span>
                  )}
                  <span className="grow" />
                  <button type="button" onClick={() => removeLine(l.item.variant_id)} className="flex h-11 w-11 items-center justify-center text-muted hover:text-danger sm:h-8 sm:w-8" aria-label="Satırı kaldır">
                    <Trash2 className="h-4 w-4" />
                  </button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );

  const payPanel = (
    <section className="space-y-4" data-testid="pos-pay">
      <dl className="divide-y divide-line border-y border-line text-sm">
        <div className="flex justify-between py-2"><dt className="text-muted">Ara toplam</dt><dd data-numeric>{money(round2(lines.reduce((s, l) => s + l.quantity * l.item.price, 0)))}</dd></div>
        {lines.some((l) => l.unit_price < l.item.price) ? (
          <div className="flex justify-between py-2"><dt className="text-muted">İndirim</dt><dd className="text-danger" data-numeric>−{money(round2(lines.reduce((s, l) => s + (l.item.price - l.unit_price) * l.quantity, 0)))}</dd></div>
        ) : null}
        <div className="flex justify-between py-2 text-base font-medium"><dt>Toplam</dt><dd data-numeric data-testid="pos-total">{money(total)}</dd></div>
      </dl>

      <div className="space-y-2" data-testid="pos-payments">
        <div className="flex flex-wrap gap-2">
          <Button type="button" variant="outline" size="sm" onClick={() => fillRemaining("cash")} disabled={total <= 0}>Tamamı nakit</Button>
          <Button type="button" variant="outline" size="sm" onClick={() => fillRemaining("card")} disabled={total <= 0}>Tamamı kart</Button>
          <Button type="button" variant="ghost" size="sm" onClick={() => setPayments((p) => [...p, { id: crypto.randomUUID(), method: "card", amount: remaining > 0 ? remaining.toFixed(2) : "" }])}>Bölünmüş ödeme +</Button>
        </div>
        {payments.map((p) => (
          <div key={p.id} className="flex items-center gap-2">
            <Select value={p.method} onChange={(e) => setPayment(p.id, { method: e.target.value as PaymentMethod })} className="h-11 w-28 sm:h-9" aria-label="Ödeme yöntemi">
              {PAYMENT_METHODS.map((m) => (
                <option key={m} value={m}>{PAYMENT_LABELS[m]}</option>
              ))}
            </Select>
            <Input value={p.amount} onChange={(e) => setPayment(p.id, { amount: e.target.value })} inputMode="decimal" placeholder="0,00" className="h-11 flex-1 text-right sm:h-9" aria-label="Tutar" />
            {payments.length > 1 ? (
              <button type="button" onClick={() => setPayments((prev) => prev.filter((x) => x.id !== p.id))} className="flex h-11 w-11 items-center justify-center text-muted sm:h-9 sm:w-9" aria-label="Ödemeyi kaldır">
                <X className="h-4 w-4" />
              </button>
            ) : null}
          </div>
        ))}
        <p className="text-xs" data-testid="pos-remaining">
          {remaining > 0 ? (
            <span className="text-danger">Kalan: <span data-numeric>{money(remaining)}</span></span>
          ) : remaining < 0 && hasCash ? (
            <span className="text-success">Para üstü: <span data-numeric>{money(change)}</span></span>
          ) : remaining < 0 ? (
            <span className="text-danger">Fazla ödeme yalnız nakitle para üstü olarak verilebilir.</span>
          ) : total > 0 ? (
            <span className="text-success">Ödeme tam.</span>
          ) : null}
        </p>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="pos-salesperson">Satışı yapan</Label>
          <Select id="pos-salesperson" value={salespersonId} onChange={(e) => setSalespersonId(e.target.value)} className="h-11 sm:h-9">
            {members.filter((m) => m.can_sell).map((m) => (
              <option key={m.user_id} value={m.user_id}>{m.full_name ?? "—"}{m.is_self ? " (ben)" : ""}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="pos-customer">Müşteri (isteğe bağlı)</Label>
          {customer ? (
            <div className="flex h-11 items-center justify-between border border-line-strong px-2 text-sm sm:h-9" data-testid="pos-customer">
              <span className="truncate">{customer.full_name ?? customer.phone}</span>
              <button type="button" onClick={() => setCustomer(null)} aria-label="Müşteriyi kaldır"><X className="h-4 w-4" /></button>
            </div>
          ) : (
            <div className="flex gap-2">
              <Input id="pos-customer" value={customerTerm} onChange={(e) => setCustomerTerm(e.target.value)} placeholder="Ad ya da telefon" className="h-11 sm:h-9" autoComplete="off" onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); findCustomer(); } }} />
              <Button type="button" variant="outline" size="sm" onClick={findCustomer} disabled={customerTerm.trim().length < 2}>Ara</Button>
            </div>
          )}
          {!customer && customerResults ? (
            customerResults.length === 0 ? <p className="text-2xs text-muted">Müşteri bulunamadı.</p> : (
              <ul className="divide-y divide-line border border-line text-sm">
                {customerResults.map((c) => (
                  <li key={c.id}>
                    <button type="button" className="flex w-full items-center justify-between px-2 py-2 text-left hover:bg-panel" onClick={() => { setCustomer(c); setCustomerResults(null); setCustomerTerm(""); }}>
                      <span>{c.full_name ?? "—"}</span><span className="text-xs text-muted" data-numeric>{c.phone}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )
          ) : null}
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="pos-note">Not</Label>
          <Input id="pos-note" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} className="h-11 sm:h-9" />
        </div>
      </div>

      {error ? <Notice tone="danger">{error}</Notice> : null}
      <Button type="button" size="lg" className="w-full" onClick={complete} disabled={!payable || submitting || pending} data-testid="pos-complete">
        {submitting ? "Satış işleniyor…" : `Satışı tamamla · ${money(total)}`}
      </Button>
    </section>
  );

  return (
    <div className="space-y-4">
      <SessionBar register={register} registers={registers} selectedId={register.id} onSelect={setRegisterId} caps={caps} />

      {/* desktop / tablet */}
      <div className="hidden gap-6 lg:grid lg:grid-cols-[1fr_1.15fr_1fr]">
        <div>{findPanel}</div>
        <div>{cartPanel}</div>
        <div>{payPanel}</div>
      </div>

      {/* phone: one stage at a time */}
      <div className="lg:hidden">
        <div className="mb-3 grid grid-cols-3 border border-line text-xs" role="tablist" aria-label="Adımlar">
          {(["items", "cart", "pay"] as Stage[]).map((s) => (
            <button
              key={s}
              role="tab"
              aria-selected={stage === s}
              onClick={() => setStage(s)}
              className={cn("h-11 border-r border-line last:border-r-0", stage === s ? "bg-primary text-primary-foreground" : "text-ink-70")}
            >
              {s === "items" ? "Ürün" : s === "cart" ? `Sepet (${count})` : "Ödeme"}
            </button>
          ))}
        </div>
        <div className="pb-24">
          {stage === "items" ? findPanel : stage === "cart" ? cartPanel : payPanel}
        </div>
        {stage !== "pay" ? (
          <div className="fixed inset-x-0 bottom-0 z-20 border-t border-line bg-surface px-4 py-3">
            <Button type="button" size="lg" className="w-full" onClick={() => setStage(stage === "items" ? "cart" : "pay")} disabled={lines.length === 0} data-testid="pos-next">
              {stage === "items" ? `Sepete git · ${count} adet · ${money(total)}` : `Ödemeye geç · ${money(total)}`}
            </Button>
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
