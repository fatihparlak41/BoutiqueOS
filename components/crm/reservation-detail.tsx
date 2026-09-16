"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Minus, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { Notice } from "@/components/catalog/intake/primitives";
import { cancelReservationAction, updateReservationAction } from "@/app/app/rezervasyonlar/actions";
import { RESERVATION_STATUS_LABELS, type Reservation } from "@/lib/crm/model";
import { formatDateTime, formatMoney } from "@/lib/receiving/format";
import { cn } from "@/lib/utils";

/**
 * One reservation. While ACTIVE (and not past due) the quantities and the expiry can be
 * edited — the server re-locks and re-checks availability — or the hold cancelled with an
 * optional reason; fulfilment is a link into the POS, which completes the sale and
 * converts the hold in one transaction. Everything else is history.
 */
const money = (n: number) => formatMoney(n, "TRY");

function toLocal(iso: string): string {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function ReservationDetail({ reservation: r, canFulfil }: { reservation: Reservation; canFulfil: boolean }) {
  const router = useRouter();
  const editable = r.status === "active" && !r.is_past_due;
  const [editing, setEditing] = useState(false);
  const [qty, setQty] = useState<Record<string, number>>(Object.fromEntries(r.items.map((i) => [i.variant.variant_id, i.quantity])));
  const [expiry, setExpiry] = useState(toLocal(r.expires_at));
  const [note, setNote] = useState(r.note ?? "");
  const [cancelOpen, setCancelOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const tone = r.status === "active" ? (r.is_past_due ? "text-danger" : "text-success") : "text-muted";

  function save() {
    setError(null);
    start(async () => {
      const items = Object.entries(qty).filter(([, q]) => q > 0).map(([variant_id, quantity]) => ({ variant_id, quantity }));
      const res = await updateReservationAction(r.id, { items, expires_at: expiry ? new Date(expiry).toISOString() : null, note: note || null });
      if (!res.ok) { setError(res.error); return; }
      setEditing(false); router.refresh();
    });
  }
  function cancel() {
    setError(null);
    start(async () => {
      const res = await cancelReservationAction(r.id, reason || null);
      if (!res.ok) { setError(res.error); return; }
      setCancelOpen(false); router.refresh();
    });
  }

  return (
    <div className="max-w-2xl space-y-6" data-testid="reservation-detail">
      <header className="space-y-1">
        <Link href="/app/rezervasyonlar" className="text-xs text-muted underline-offset-2 hover:underline">← Rezervasyonlar</Link>
        <div className="flex flex-wrap items-center gap-3">
          <h2 className="font-serif text-xl leading-tight tracking-tightish" data-numeric>{r.reservation_number}</h2>
          <span className={cn("border px-1.5 py-0.5 text-2xs", r.status === "active" && !r.is_past_due ? "border-success/40 text-success" : r.is_past_due ? "border-danger/40 text-danger" : "border-line-strong text-muted")} data-testid="rsv-status">
            {r.is_past_due ? "Süresi geçti (bekliyor)" : RESERVATION_STATUS_LABELS[r.status]}
          </span>
        </div>
        <p className="text-xs text-muted" data-numeric>{formatDateTime(r.created_at)} · {r.branch_name}{r.created_by_name ? ` · ${r.created_by_name}` : ""}</p>
      </header>

      <dl className="divide-y divide-line border-y border-line text-sm">
        <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Müşteri</dt><dd className="text-right">{r.customer ? <Link href={`/app/musteriler/${r.customer.id}`} className="underline-offset-2 hover:underline">{r.customer.full_name}</Link> : "—"}{r.customer?.phone ? <span className="text-muted" data-numeric> · {r.customer.phone}</span> : null}</dd></div>
        <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Ayrılma süresi</dt><dd className={cn("text-right", tone)} data-numeric data-testid="rsv-expires">{formatDateTime(r.expires_at)}</dd></div>
        {r.source ? <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Kanal</dt><dd>{r.source}</dd></div> : null}
        {r.note && !editing ? <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Not</dt><dd className="text-right">{r.note}</dd></div> : null}
        {r.status === "converted" ? <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Teslim satışı</dt><dd className="text-right"><Link href={`/app/pos/satis/${r.converted_to_sale_id}`} className="underline-offset-2 hover:underline" data-numeric>{r.converted_sale_number ?? "—"}</Link>{r.fulfilled_at ? <span className="text-muted" data-numeric> · {formatDateTime(r.fulfilled_at)}</span> : null}</dd></div> : null}
        {r.status === "cancelled" || r.status === "expired" ? <div className="flex justify-between gap-6 py-2"><dt className="text-muted">{r.status === "cancelled" ? "İptal" : "Süre doldu"}</dt><dd className="text-right" data-numeric>{r.cancelled_at ? formatDateTime(r.cancelled_at) : "—"}{r.cancel_reason ? ` · ${r.cancel_reason}` : ""}</dd></div> : null}
      </dl>

      <ul className="divide-y divide-line border-y border-line" data-testid="rsv-detail-lines">
        {r.items.map((it) => {
          const q = editing ? (qty[it.variant.variant_id] ?? 0) : it.quantity;
          const max = it.available + it.quantity;   // this hold's own quantity is not counted against it
          return (
            <li key={it.variant.variant_id} className="flex items-center gap-3 py-2.5" data-rsv-line={it.variant.sku} data-qty={q}>
              <ProductThumb url={it.variant.thumbnail_url} alt={it.variant.product_name} size="sm" />
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-medium text-ink">{it.variant.product_name}</p>
                <p className="truncate text-2xs text-muted">{[it.variant.color, it.variant.size].filter(Boolean).join(" / ") || it.variant.options || "Tek varyant"} · <span data-numeric>{it.variant.sku}</span></p>
                {editable ? <p className="text-2xs text-muted" data-numeric>{it.available} adet başka müsait</p> : null}
              </div>
              {editing ? (
                <div className="flex items-center border border-line-strong">
                  <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => setQty((p) => ({ ...p, [it.variant.variant_id]: Math.max(0, q - 1) }))} aria-label="Bir azalt">{q <= 1 ? <Trash2 className="h-4 w-4" /> : <Minus className="h-4 w-4" />}</button>
                  <span className="w-10 text-center text-sm" data-numeric>{q}</span>
                  <button type="button" className="flex h-11 w-11 items-center justify-center sm:h-8 sm:w-8" onClick={() => setQty((p) => ({ ...p, [it.variant.variant_id]: Math.min(max, q + 1) }))} aria-label="Bir artır" disabled={q >= max}><Plus className="h-4 w-4" /></button>
                </div>
              ) : (
                <span className="text-sm" data-numeric>{it.quantity} × {money(it.price)}</span>
              )}
            </li>
          );
        })}
      </ul>

      {editing ? (
        <div className="space-y-3 border border-line bg-panel/40 p-3" data-testid="rsv-edit">
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1.5"><Label htmlFor="rsv-edit-expiry">Şu tarihe kadar</Label><Input id="rsv-edit-expiry" type="datetime-local" value={expiry} onChange={(e) => setExpiry(e.target.value)} className="h-11 sm:h-9" /></div>
            <div className="space-y-1.5"><Label htmlFor="rsv-edit-note">Not</Label><Input id="rsv-edit-note" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} className="h-11 sm:h-9" /></div>
          </div>
          {error ? <Notice tone="danger">{error}</Notice> : null}
          <div className="flex flex-wrap gap-2">
            <Button type="button" onClick={save} disabled={pending || Object.values(qty).every((q) => q <= 0)} data-testid="rsv-save">{pending ? "Kaydediliyor…" : "Kaydet"}</Button>
            <Button type="button" variant="outline" onClick={() => { setEditing(false); setError(null); }}>Vazgeç</Button>
          </div>
        </div>
      ) : null}

      {cancelOpen ? (
        <div className="space-y-3 border border-danger/30 bg-danger-muted/30 p-3" data-testid="rsv-cancel">
          <div className="space-y-1.5"><Label htmlFor="rsv-cancel-reason">İptal nedeni (isteğe bağlı)</Label><Input id="rsv-cancel-reason" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} className="h-11 sm:h-9" /></div>
          {error ? <Notice tone="danger">{error}</Notice> : null}
          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="outline" onClick={cancel} disabled={pending} data-testid="rsv-cancel-confirm">{pending ? "İptal ediliyor…" : "Rezervasyonu iptal et"}</Button>
            <Button type="button" variant="ghost" onClick={() => setCancelOpen(false)}>Vazgeç</Button>
          </div>
        </div>
      ) : null}

      {!editing && !cancelOpen && error ? <Notice tone="danger">{error}</Notice> : null}
      {r.status === "active" && !editing && !cancelOpen ? (
        <div className="flex flex-wrap gap-2">
          {canFulfil && editable ? <Link href={`/app/pos?rezervasyon=${r.id}`} className="inline-flex h-11 items-center bg-primary px-4 text-sm text-primary-foreground sm:h-9" data-testid="rsv-fulfil">Kasada teslim et</Link> : null}
          {editable ? <Button type="button" variant="outline" onClick={() => setEditing(true)} data-testid="rsv-edit-open">Düzenle</Button> : null}
          <Button type="button" variant="outline" onClick={() => setCancelOpen(true)} data-testid="rsv-cancel-open">{r.is_past_due ? "Süresi doldu olarak kapat" : "İptal et"}</Button>
        </div>
      ) : null}
      {r.is_past_due ? <Notice tone="warning">Ayrılma süresi geçti: ürünler artık müsait sayılıyor. Kapatın ya da müşteriyle yeni bir rezervasyon açın.</Notice> : null}
    </div>
  );
}
