import { redirect } from "next/navigation";
import Link from "next/link";
import { listMembers, listRegisters, loadPosContext, posItemsFor } from "@/lib/pos/queries";
import { getReservation, listActiveReservationsForBranch } from "@/lib/crm/queries";
import type { PosReservation } from "@/lib/pos/model";
import { formatDateTime } from "@/lib/receiving/format";
import { PosTerminal } from "@/components/pos/pos-terminal";
import { CreateRegisterForm, OpenSessionForm } from "@/components/pos/session-panel";

export const metadata = { title: "Kasa · BoutiqueOS" };

/**
 * Kasa. The server decides who may be here (owner, manager, sales_staff) and what the
 * branch has: no register → a manager creates one; registers without an open drawer →
 * a manager opens one (sales_staff waits); an open drawer → the terminal. Nothing
 * cost-related is loaded on this page.
 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function PosPage({ searchParams }: { searchParams: Promise<{ rezervasyon?: string }> }) {
  // caps (own discount authority) and the branch's registers / members / holds in one round
  const [{ caps, branchId, tenant }, registers, members, pending, { rezervasyon }] = await Promise.all([
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

  return (
    <div className="max-w-6xl space-y-6">
      <header>
        <h2 className="font-serif text-xl leading-tight tracking-tightish">Kasa</h2>
        <p className="mt-1 text-xs text-muted">{tenant.branch?.name ?? "—"} · barkod okutun, sepeti kurun, ödemeyi alın.</p>
      </header>

      {registers.length === 0 ? (
        caps.canManageRegisters ? (
          <CreateRegisterForm />
        ) : (
          <p className="border-l-2 border-line-strong bg-panel px-3 py-2 text-xs text-ink-70">Bu şubede henüz kasa tanımlı değil. Yönetici bir kasa oluşturmalı.</p>
        )
      ) : null}

      {registers.length > 0 && !anyOpen ? (
        <div className="space-y-4">
          <p className="border-l-2 border-line-strong bg-panel px-3 py-2 text-xs text-ink-70">
            {caps.canManageRegisters ? "Satış için açık bir kasa oturumu gerekir." : "Satış için açık bir kasa oturumu gerekir. Kasayı yönetici açar."}
          </p>
          {caps.canManageRegisters ? <OpenSessionForm registers={registers} /> : null}
        </div>
      ) : null}

      {reservationNotice ? <p className="border-l-2 border-danger bg-panel px-3 py-2 text-xs text-danger" role="alert">{reservationNotice}</p> : null}
      {anyOpen ? <PosTerminal key={reservation?.id ?? "free"} registers={registers} members={members} caps={caps} reservation={reservation} /> : null}

      {anyOpen && pending.length > 0 && !reservation ? (
        <section className="space-y-2" data-testid="pos-reservations">
          <h3 className="text-sm font-medium tracking-tightish">Bekleyen rezervasyonlar</h3>
          <ul className="divide-y divide-line border-y border-line text-sm">
            {pending.map((r) => (
              <li key={r.id} className="flex items-center justify-between gap-3 py-2">
                <div className="min-w-0">
                  <p data-numeric>{r.reservation_number} <span className="text-muted">· {r.customer?.full_name ?? "—"}</span></p>
                  <p className="truncate text-2xs text-muted" data-numeric>{r.items.map((i) => `${i.quantity}× ${i.variant.product_name}`).join(", ")} · {formatDateTime(r.expires_at)}</p>
                </div>
                <Link href={`/app/pos?rezervasyon=${r.id}`} className="inline-flex h-11 shrink-0 items-center border border-line-strong px-3 text-xs sm:h-9" data-testid="pos-fulfil">Teslim et</Link>
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
