"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Minus, Plus, ScanLine, Search, Trash2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { Notice } from "@/components/catalog/intake/primitives";
import { lookupBarcodeAction, searchItemsAction } from "@/app/app/pos/actions";
import { searchCustomersAction } from "@/app/app/musteriler/actions";
import { createReservationAction } from "@/app/app/rezervasyonlar/actions";
import type { CustomerHit, CustomerSource } from "@/lib/crm/model";
import type { PosItem } from "@/lib/pos/model";
import { formatDateTime, formatMoney } from "@/lib/receiving/format";
import { cn } from "@/lib/utils";

/**
 * A hold in under a minute on a phone: pick the customer (search, or the one handed over
 * from the customer page), scan / search the item, choose the exact variant, set the
 * quantity against what is AVAILABLE (sellable − active holds), confirm the expiry and
 * reserve. Availability shown here is the server's read; rpc_pos_reservation_create
 * re-checks it under lock and writes all or nothing. No cost appears anywhere.
 */
const money = (n: number) => formatMoney(n, "TRY");
type Line = { item: PosItem; quantity: number };
type Stage = "customer" | "items" | "review";

function defaultExpiry(hours: number): string {
  const d = new Date(Date.now() + hours * 3600000);
  d.setSeconds(0, 0);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function ReservationForm({ branchId, branchName, sources, defaultHours, initialCustomer }: {
  branchId: string; branchName: string; sources: CustomerSource[]; defaultHours: number; initialCustomer: CustomerHit | null;
}) {
  const router = useRouter();
  const [stage, setStage] = useState<Stage>(initialCustomer ? "items" : "customer");
  const [customer, setCustomer] = useState<CustomerHit | null>(initialCustomer);
  const [customerTerm, setCustomerTerm] = useState("");
  const [customerResults, setCustomerResults] = useState<CustomerHit[] | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [code, setCode] = useState("");
  const [term, setTerm] = useState("");
  const [results, setResults] = useState<PosItem[] | null>(null);
  const [warning, setWarning] = useState<string | null>(null);
  const [expiry, setExpiry] = useState(() => defaultExpiry(defaultHours));
  const [note, setNote] = useState("");
  const [source, setSource] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [pending, start] = useTransition();
  const scanRef = useRef<HTMLInputElement>(null);
  const queueRef = useRef<string[]>([]);
  const sendingRef = useRef(false);
  const focusScan = () => window.setTimeout(() => scanRef.current?.focus(), 0);
  useEffect(() => { if (stage === "items") focusScan(); }, [stage]);

  const count = lines.reduce((s, l) => s + l.quantity, 0);
  const total = lines.reduce((s, l) => s + l.quantity * l.item.price, 0);
  const short = lines.some((l) => l.quantity > l.item.available);
  const canReserve = Boolean(customer) && lines.length > 0 && !short && !submitting && !pending;

  async function findCustomer() {
    const res = await searchCustomersAction(customerTerm);
    if (res.ok) setCustomerResults(res.data); else setError(res.error);
  }
  function addItem(item: PosItem, delta = 1) {
    setLines((prev) => {
      const i = prev.findIndex((l) => l.item.variant_id === item.variant_id);
      if (i === -1) return [...prev, { item, quantity: Math.max(1, delta) }];
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
  async function search() {
    const t = term.trim();
    if (t.length < 2) return;
    const res = await searchItemsAction(t);
    if (!res.ok) setError(res.error); else setResults(res.data);
  }
  function setQty(variantId: string, quantity: number) {
    setLines((prev) => prev.map((l) => (l.item.variant_id === variantId ? { ...l, quantity: Math.max(1, Math.min(999, quantity)) } : l)));
  }
  function reserve() {
    if (!customer || !canReserve) return;
    setSubmitting(true); setError(null);
    start(async () => {
      const res = await createReservationAction({
        branch_id: branchId, customer_id: customer.id, items: lines.map((l) => ({ variant_id: l.item.variant_id, quantity: l.quantity })),
        expires_at: expiry ? new Date(expiry).toISOString() : null, note: note || null, source: source || null,
      });
      if (!res.ok) { setError(res.error); setSubmitting(false); return; }
      router.push(`/app/rezervasyonlar/${res.data.id}`);
    });
  }

  const customerPanel = (
    <section className="space-y-3" data-testid="rsv-customer">
      {customer ? (
        <div className="flex items-center justify-between border border-line-strong px-3 py-2 text-sm" data-testid="rsv-customer-picked">
          <div className="min-w-0">
            <p className="truncate font-medium text-ink">{customer.full_name}</p>
            <p className="truncate text-2xs text-muted" data-numeric>{customer.phone ?? customer.email ?? (customer.instagram ? `@${customer.instagram}` : "iletişim yok")}</p>
          </div>
          <button type="button" onClick={() => setCustomer(null)} aria-label="Müşteriyi değiştir" className="flex h-11 w-11 items-center justify-center sm:h-9 sm:w-9"><X className="h-4 w-4" /></button>
        </div>
      ) : (
        <>
          <form onSubmit={(e) => { e.preventDefault(); void findCustomer(); }} className="flex items-end gap-2">
            <div className="flex-1">
              <Label htmlFor="rsv-customer-q" className="text-2xs">Müşteri</Label>
              <div className="relative">
                <Search aria-hidden className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
                <Input id="rsv-customer-q" value={customerTerm} onChange={(e) => setCustomerTerm(e.target.value)} placeholder="Ad, telefon ya da Instagram" className="h-12 pl-8 text-base sm:h-10" autoComplete="off" autoFocus />
              </div>
            </div>
            <Button type="submit" variant="outline" size="md" disabled={customerTerm.trim().length < 2}>Ara</Button>
          </form>
          {customerResults ? (
            customerResults.length === 0 ? <p className="text-xs text-muted">Müşteri bulunamadı.</p> : (
              <ul className="divide-y divide-line border-y border-line" data-testid="rsv-customer-results">
                {customerResults.map((c) => (
                  <li key={c.id}>
                    <button type="button" onClick={() => { setCustomer(c); setCustomerResults(null); setStage("items"); }} className="flex w-full items-center justify-between px-1 py-3 text-left hover:bg-panel">
                      <span className="text-sm font-medium text-ink">{c.full_name}</span><span className="text-2xs text-muted" data-numeric>{c.phone ?? c.email ?? (c.instagram ? `@${c.instagram}` : "")}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )
          ) : null}
          <Link href="/app/musteriler/yeni?geri=/app/rezervasyonlar/yeni" className="inline-flex h-11 items-center border border-line-strong px-3 text-sm sm:h-9">Yeni müşteri</Link>
        </>
      )}
    </section>
  );

  const itemsPanel = (
    <section className="space-y-3" data-testid="rsv-items">
      <form onSubmit={(e) => { e.preventDefault(); scan(); }} className="flex items-end gap-2">
        <div className="flex-1">
          <Label htmlFor="rsv-scan" className="text-2xs">Barkod okut</Label>
          <div className="relative">
            <ScanLine aria-hidden className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
            <Input id="rsv-scan" ref={scanRef} value={code} onChange={(e) => setCode(e.target.value)} autoComplete="off" inputMode="numeric" placeholder="Barkodu okutun ve Enter" className="h-12 pl-8 text-base sm:h-10" />
          </div>
        </div>
        <Button type="submit" variant="outline" size="md" disabled={!code.trim()}>Ekle</Button>
      </form>
      {warning ? <Notice tone="warning">{warning}</Notice> : null}
      <form onSubmit={(e) => { e.preventDefault(); void search(); }} className="flex items-end gap-2">
        <div className="flex-1">
          <Label htmlFor="rsv-search" className="text-2xs">Ürün ara</Label>
          <Input id="rsv-search" value={term} onChange={(e) => setTerm(e.target.value)} placeholder="Ürün adı, SKU veya barkod" className="h-11 sm:h-9" autoComplete="off" />
        </div>
        <Button type="submit" variant="outline" size="sm" disabled={term.trim().length < 2}>Ara</Button>
      </form>
      {results ? (
        results.length === 0 ? <p className="text-xs text-muted">Eşleşen ürün yok.</p> : (
          <ul className="divide-y divide-line border-y border-line" data-testid="rsv-search-results">
            {results.map((it) => (
              <li key={it.variant_id} className="flex items-center gap-3 py-2">
                <ProductThumb url={it.thumbnail_url} alt={it.product_name} size="sm" />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-ink">{it.product_name}</p>
                  <p className="truncate text-2xs text-muted">{[it.color, it.size].filter(Boolean).join(" / ") || it.options || "Tek varyant"} · <span data-numeric>{it.sku}</span></p>
                  <p className={cn("text-2xs", it.available > 0 ? "text-muted" : "text-danger")} data-numeric>{it.available > 0 ? `${it.available} adet müsait` : "müsait değil"}</p>
                </div>
                <span className="text-sm" data-numeric>{money(it.price)}</span>
                <Button type="button" variant="outline" size="sm" onClick={() => addItem(it)} disabled={it.available <= 0} aria-label={`${it.sku} rezerve et`}><Plus className="h-4 w-4" /></Button>
              </li>
            ))}
          </ul>
        )
      ) : null}
      <div className="space-y-2" data-testid="rsv-lines">
        <div className="flex items-baseline justify-between"><h3 className="text-sm font-medium tracking-tightish">Ayrılacak ürünler</h3><span className="text-xs text-muted" data-numeric>{count} adet</span></div>
        {lines.length === 0 ? <p className="border border-dashed border-line-strong px-4 py-6 text-center text-xs text-muted">Barkod okutun ya da ürün arayın.</p> : (
          <ul className="divide-y divide-line border-y border-line">
            {lines.map((l) => (
              <li key={l.item.variant_id} className="space-y-1.5 py-2.5" data-rsv-line={l.item.sku} data-qty={l.quantity}>
                <div className="flex items-start gap-3">
                  <ProductThumb url={l.item.thumbnail_url} alt={l.item.product_name} size="sm" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-ink">{l.item.product_name}</p>
                    <p className="truncate text-2xs text-muted">{[l.item.color, l.item.size].filter(Boolean).join(" / ") || l.item.options || "Tek varyant"} · <span data-numeric>{l.item.sku}</span></p>
                    <p className={cn("text-2xs", l.quantity > l.item.available ? "text-danger" : "text-muted")} data-numeric>{l.item.available} adet müsait</p>
                  </div>
                  <span className="text-sm" data-numeric>{money(l.item.price)}</span>
                </div>
                <div className="flex items-center gap-2 pl-[3.25rem]">
                  <div className="flex items-center border border-line-strong">
                    <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => (l.quantity === 1 ? setLines((p) => p.filter((x) => x.item.variant_id !== l.item.variant_id)) : setQty(l.item.variant_id, l.quantity - 1))} aria-label="Bir azalt"><Minus className="h-4 w-4" /></button>
                    <input aria-label="Adet" inputMode="numeric" value={l.quantity} onChange={(e) => setQty(l.item.variant_id, Number(e.target.value.replace(/\D/g, "")) || 1)} className="h-11 w-12 border-x border-line-strong bg-transparent text-center text-sm sm:h-8" data-numeric />
                    <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => setQty(l.item.variant_id, l.quantity + 1)} aria-label="Bir artır" disabled={l.quantity >= l.item.available}><Plus className="h-4 w-4" /></button>
                  </div>
                  <span className="grow" />
                  <button type="button" onClick={() => setLines((p) => p.filter((x) => x.item.variant_id !== l.item.variant_id))} className="flex h-11 w-11 items-center justify-center text-muted sm:h-8 sm:w-8" aria-label="Satırı kaldır"><Trash2 className="h-4 w-4" /></button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );

  const reviewPanel = (
    <section className="space-y-4" data-testid="rsv-review">
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="rsv-expiry">Şu tarihe kadar ayrılsın</Label>
          <Input id="rsv-expiry" type="datetime-local" value={expiry} onChange={(e) => setExpiry(e.target.value)} className="h-11 sm:h-9" />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="rsv-source">Kanal</Label>
          <Select id="rsv-source" value={source} onChange={(e) => setSource(e.target.value)} className="h-11 sm:h-9">
            <option value="">—</option>
            {sources.map((s) => <option key={s.code} value={s.code}>{s.label}</option>)}
          </Select>
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="rsv-note">Not</Label>
          <Input id="rsv-note" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} className="h-11 sm:h-9" />
        </div>
      </div>
      <dl className="divide-y divide-line border-y border-line text-sm">
        <div className="flex justify-between py-2"><dt className="text-muted">Müşteri</dt><dd>{customer?.full_name ?? "—"}</dd></div>
        <div className="flex justify-between py-2"><dt className="text-muted">Şube</dt><dd>{branchName}</dd></div>
        <div className="flex justify-between py-2"><dt className="text-muted">Ürünler</dt><dd className="text-right" data-numeric>{lines.map((l) => <div key={l.item.variant_id}>{l.quantity} × {l.item.product_name} {l.item.options ? `(${l.item.options})` : ""}</div>)}</dd></div>
        <div className="flex justify-between py-2"><dt className="text-muted">Liste değeri</dt><dd data-numeric data-testid="rsv-total">{money(total)}</dd></div>
        <div className="flex justify-between py-2 text-base font-medium"><dt>Ayrılma süresi</dt><dd data-numeric data-testid="rsv-until">{expiry ? formatDateTime(new Date(expiry).toISOString()) : "—"}</dd></div>
      </dl>
      {short ? <Notice tone="danger">Bir satır müsait adedin üstünde.</Notice> : null}
      {error ? <Notice tone="danger">{error}</Notice> : null}
      <Button type="button" size="lg" className="w-full" onClick={reserve} disabled={!canReserve} data-testid="rsv-reserve">{submitting ? "Ayrılıyor…" : `Rezerve et · ${count} adet`}</Button>
    </section>
  );

  const stages: Stage[] = ["customer", "items", "review"];
  const label: Record<Stage, string> = { customer: "Müşteri", items: `Ürün (${count})`, review: "Onay" };
  const enabled = (s: Stage) => s === "customer" || (Boolean(customer) && (s === "items" || lines.length > 0));
  return (
    <div className="space-y-4">
      {/* desktop: three columns */}
      <div className="hidden gap-6 lg:grid lg:grid-cols-[1fr_1.2fr_1fr]">
        <div>{customerPanel}</div>
        <div>{customer ? itemsPanel : <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">Önce müşteriyi seçin.</p>}</div>
        <div>{reviewPanel}</div>
      </div>
      {/* phone: one stage at a time */}
      <div className="lg:hidden">
        <div className="mb-3 grid grid-cols-3 border border-line text-xs" role="tablist" aria-label="Adımlar">
          {stages.map((s) => (
            <button key={s} role="tab" aria-selected={stage === s} onClick={() => enabled(s) && setStage(s)} disabled={!enabled(s)}
              className={cn("h-11 border-r border-line last:border-r-0", stage === s ? "bg-primary text-primary-foreground" : enabled(s) ? "text-ink-70" : "text-muted/50")}>
              {label[s]}
            </button>
          ))}
        </div>
        <div className="pb-24">{stage === "customer" ? customerPanel : stage === "items" ? itemsPanel : reviewPanel}</div>
        {stage !== "review" ? (
          <div className="fixed inset-x-0 bottom-0 z-20 border-t border-line bg-surface px-4 py-3">
            <Button type="button" size="lg" className="w-full" onClick={() => setStage(stage === "customer" ? "items" : "review")} disabled={stage === "customer" ? !customer : lines.length === 0} data-testid="rsv-next">
              {stage === "customer" ? "Ürünlere geç" : `Onaya geç · ${count} adet`}
            </Button>
          </div>
        ) : null}
      </div>
    </div>
  );
}
