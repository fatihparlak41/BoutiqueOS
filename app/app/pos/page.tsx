import { redirect } from "next/navigation";
import Link from "next/link";
import { getPosOnlineOrder, listMembers, listRegisters, loadPosContext, posItemsFor } from "@/lib/pos/queries";
import { getReservation, listActiveReservationsForBranch } from "@/lib/crm/queries";
import type { PosOnlineOrder, PosReservation } from "@/lib/pos/model";
import { formatDateTime } from "@/lib/receiving/format";
import { PosTerminal } from "@/components/pos/pos-terminal";
import { CreateRegisterForm, OpenSessionForm } from "@/components/pos/session-panel";
import { PageHeader } from "@/components/ui/page-header";
import { Button } from "@/components/ui/button";
import { Notice } from "@/components/catalog/intake/primitives";

export const metadata = { title: "Kasa · BoutiqueOS" };

/**
 * Kasa. The server decides who may be here (owner, manager, sales_staff) and what the
 * branch has: no register → a manager creates one; registers without an open drawer →
 * a manager opens one (sales_staff waits); an open drawer → the terminal. Nothing
 * cost-related is loaded on this page.
 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function PosPage({ searchParams }: { searchParams: Promise<{ rezervasyon?: string; siparis?: string }> }) {
  // caps (own discount authority) and the branch's registers / members / holds in one round
  const [{ caps, branchId, tenant }, registers, members, pending, { rezervasyon, siparis }] = await Promise.all([
    loadPosContext(), listRegisters(), listMembers(), listActiveReservationsForBranch(10), searchParams,
  ]);
  if (!caps.canSell) redirect("/app");
  if (!branchId) redirect("/app");
  const anyOpen = registers.some((r) => r.open_session);

  // a reservation to fulfil: pre-loaded lines + its customer; the sale converts it atomically
  let reservation: PosReservation | null = null;
  let reservationNotice: string | null = null;
  if (rezervasyon && UUID.test(rezervasyon)) {
    const r = await getReservation(rezervasyon);
    if (!r) reservationNotice = "Rezervasyon bulunamadı.";
    else if (r.status !== "active" || r.is_past_due) reservationNotice = "Bu rezervasyon artık aktif değil.";
    else if (r.branch_id !== branchId) reservationNotice = "Rezervasyon başka bir şubeye ait.";
    else {
      const items = await posItemsFor(r.items.map((i) => i.variant.variant_id));
      reservation = {
        id: r.id, reservation_number: r.reservation_number, expires_at: r.expires_at,
        customer: r.customer ? { id: r.customer.id, full_name: r.customer.full_name, phone: r.customer.phone ?? "" } : null,
        lines: r.items.flatMap((i) => { const item = items.find((x) => x.variant_id === i.variant.variant_id); return item ? [{ item, quantity: i.quantity }] : []; }),
      };
    }
  }

  // an online order to complete: verified, reserved lines with the server-honoured price; the sale binds to the order
  let order: PosOnlineOrder | null = null;
  let orderNotice: string | null = null;
  if (siparis && UUID.test(siparis)) {
    const o = await getPosOnlineOrder(siparis);
    if (!o) orderNotice = "Online sipariş bulunamadı.";
    else if (o.status !== "confirmed" && o.status !== "ready") orderNotice = o.status === "completed" ? "Bu sipariş zaten teslim edilmiş." : "Bu sipariş kasada tamamlanacak durumda değil (önce onaylayın).";
    else if (!o.reservation_active) orderNotice = "Siparişin stok ayırma süresi dolmuş; sipariş sayfasından yeniden ayırın.";
    else if (o.branch_id !== branchId) orderNotice = "Sipariş başka bir şubeden teslim edilecek.";
    else {
      const items = await posItemsFor(o.lines.map((l) => l.variant_id));
      const lines = o.lines.flatMap((l) => { const item = items.find((x) => x.variant_id === l.variant_id); return item ? [{ item, quantity: l.quantity, unit_price: l.unit_price }] : []; });
      if (lines.length !== o.lines.length) orderNotice = "Siparişteki bir ürün kasada bulunamadı.";
      else order = { id: o.id, order_number: o.order_number, customer_name: o.customer_name, phone: o.phone, reservation_expires_at: o.reservation_expires_at, lines };
    }
  }

  return (
    <div className="max-w-6xl space-y-6">
      <PageHeader title="Kasa" description={`${tenant.branch?.name ?? "—"} · barkod okut, sepeti kur, ödemeyi al.`} />

      {registers.length === 0 ? (
        caps.canManageRegisters ? (
          <CreateRegisterForm />
        ) : (
          <Notice tone="info">Bu şubede henüz kasa tanımlı değil. Kasayı işletme sahibi ya da yönetici oluşturur.</Notice>
        )
      ) : null}

      {registers.length > 0 && !anyOpen ? (
        <div className="space-y-4">
          <Notice tone="info">
            {caps.canManageRegisters ? "Satış için önce kasayı aç." : "Satış için açık bir kasa gerekir; kasayı işletme sahibi ya da yönetici açar."}
          </Notice>
          {caps.canManageRegisters ? <OpenSessionForm registers={registers} /> : null}
        </div>
      ) : null}

      {reservationNotice ? <Notice tone="danger">{reservationNotice}</Notice> : null}
      {orderNotice ? <Notice tone="danger">{orderNotice}</Notice> : null}
      {anyOpen ? <PosTerminal key={order?.id ?? reservation?.id ?? "free"} registers={registers} members={members} caps={caps} reservation={reservation} order={order} /> : null}

      {anyOpen && pending.length > 0 && !reservation ? (
        <section className="space-y-2" data-testid="pos-reservations">
          <h3 className="text-sm font-medium tracking-tightish">Teslim bekleyen rezervasyonlar</h3>
          <ul className="divide-y divide-line border-y border-line text-sm">
            {pending.map((r) => (
              <li key={r.id} className="flex items-center justify-between gap-3 py-2">
                <div className="min-w-0">
                  <p data-numeric>{r.reservation_number} <span className="text-muted">· {r.customer?.full_name ?? "—"}</span></p>
                  <p className="truncate text-2xs text-muted" data-numeric>{r.items.map((i) => `${i.quantity}× ${i.variant.product_name}`).join(", ")} · son gün {formatDateTime(r.expires_at)}</p>
                </div>
                <Link href={`/app/pos?rezervasyon=${r.id}`} data-testid="pos-fulfil"><Button variant="outline" size="sm">Teslim et</Button></Link>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {anyOpen && caps.canManageRegisters && registers.some((r) => r.is_active && !r.open_session) ? (
        <details className="text-xs">
          <summary className="cursor-pointer text-muted">Başka bir kasa aç</summary>
          <div className="mt-2"><OpenSessionForm registers={registers} /></div>
        </details>
      ) : null}
      {registers.length > 0 && caps.canManageRegisters ? (
        <details className="text-xs">
          <summary className="cursor-pointer text-muted">Yeni kasa tanımla</summary>
          <div className="mt-2"><CreateRegisterForm /></div>
        </details>
      ) : null}
    </div>
  );
}
