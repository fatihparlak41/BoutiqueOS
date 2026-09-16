import { redirect } from "next/navigation";
import { listMembers, listRegisters, loadPosContext } from "@/lib/pos/queries";
import { PosTerminal } from "@/components/pos/pos-terminal";
import { CreateRegisterForm, OpenSessionForm } from "@/components/pos/session-panel";

export const metadata = { title: "Kasa · BoutiqueOS" };

/**
 * Kasa. The server decides who may be here (owner, manager, sales_staff) and what the
 * branch has: no register → a manager creates one; registers without an open drawer →
 * open one; an open drawer → the terminal. Nothing cost-related is loaded on this page.
 */
export default async function PosPage() {
  const { caps, branchId, tenant } = await loadPosContext();
  if (!caps.canSell) redirect("/app");
  if (!branchId) redirect("/app");

  const [registers, members] = await Promise.all([listRegisters(), listMembers()]);
  const anyOpen = registers.some((r) => r.open_session);

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
          <p className="border-l-2 border-line-strong bg-panel px-3 py-2 text-xs text-ink-70">Satış için açık bir kasa oturumu gerekir.</p>
          <OpenSessionForm registers={registers} />
        </div>
      ) : null}

      {anyOpen ? <PosTerminal registers={registers} members={members} caps={caps} /> : null}

      {anyOpen && registers.some((r) => r.is_active && !r.open_session) ? (
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
