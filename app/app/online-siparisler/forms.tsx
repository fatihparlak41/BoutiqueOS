"use client";

import { useActionState, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { cancelOrderAction, confirmOrderAction, readyOrderAction, rereserveOrderAction } from "@/app/app/online-siparisler/actions";
import { ORDER_IDLE } from "@/lib/orders/model";

function Feedback({ error, ok, okText }: { error: string | null; ok: boolean; okText: string }) {
  if (error) return <p className="text-xs text-danger" role="alert">{error}</p>;
  if (ok) return <p className="text-xs text-text-secondary" role="status">{okText}</p>;
  return null;
}

/** One-click transitions armed by a first click; cancellation asks for the reason. */
export function ConfirmOrderForm({ orderId }: { orderId: string }) {
  const [state, formAction, pending] = useActionState(confirmOrderAction, ORDER_IDLE);
  return (
    <form action={formAction} className="space-y-1">
      <input type="hidden" name="order_id" value={orderId} />
      <Button type="submit" size="sm" disabled={pending}>{pending ? "Onaylanıyor…" : "Onayla"}</Button>
      <p className="text-2xs text-text-muted">Onay, ayırma süresini yeniden başlatır.</p>
      <Feedback error={state.error} ok={state.ok} okText="Onaylandı." />
    </form>
  );
}

export function ReadyOrderForm({ orderId }: { orderId: string }) {
  const [state, formAction, pending] = useActionState(readyOrderAction, ORDER_IDLE);
  return (
    <form action={formAction} className="space-y-1">
      <input type="hidden" name="order_id" value={orderId} />
      <Button type="submit" size="sm" variant="outline" disabled={pending}>{pending ? "…" : "Teslime hazır işaretle"}</Button>
      <Feedback error={state.error} ok={state.ok} okText="Hazır olarak işaretlendi." />
    </form>
  );
}

export function RereserveOrderForm({ orderId }: { orderId: string }) {
  const [state, formAction, pending] = useActionState(rereserveOrderAction, ORDER_IDLE);
  return (
    <form action={formAction} className="space-y-1">
      <input type="hidden" name="order_id" value={orderId} />
      <Button type="submit" size="sm" variant="outline" disabled={pending}>{pending ? "…" : "Stok uygunsa yeniden ayır"}</Button>
      <p className="text-2xs text-text-muted">Stok yeniden kontrol edilir; yeterliyse yeni bir ayırma açılır ve sipariş onay bekler.</p>
      <Feedback error={state.error} ok={state.ok} okText="Yeniden ayrıldı." />
    </form>
  );
}

export function CancelOrderForm({ orderId }: { orderId: string }) {
  const [state, formAction, pending] = useActionState(cancelOrderAction, ORDER_IDLE);
  const [arm, setArm] = useState(false);
  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="order_id" value={orderId} />
      {!arm ? (
        <Button type="button" variant="outline" size="sm" onClick={() => setArm(true)}>İptal et…</Button>
      ) : (
        <div className="space-y-2">
          <div className="space-y-1.5">
            <Label htmlFor={`cancel-${orderId}`}>Neden</Label>
            <Input id={`cancel-${orderId}`} name="reason" maxLength={300} required />
          </div>
          <p className="text-2xs text-text-muted">Ayrılan ürünler serbest kalır; stok hareketi olmaz; sipariş geçmişte kalır.</p>
          <div className="flex items-center gap-2">
            <Button type="submit" variant="danger" size="sm" disabled={pending}>{pending ? "İptal ediliyor…" : "Evet, iptal et"}</Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setArm(false)}>Vazgeç</Button>
          </div>
        </div>
      )}
      <Feedback error={state.error} ok={state.ok} okText="İptal edildi." />
    </form>
  );
}
