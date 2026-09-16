"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE } from "@/lib/catalog/action-state";
import { closeSessionAction, createRegisterAction, openSessionAction } from "@/app/app/pos/actions";
import type { PosCaps, Register } from "@/lib/pos/model";
import { formatDateTime } from "@/lib/receiving/format";

/**
 * Before selling: pick a register, open a drawer (or use the one already open), close it
 * at the end of the shift. A manager can create the branch's first register here.
 */

function Pending({ label, pendingLabel, variant = "solid" }: { label: string; pendingLabel: string; variant?: "solid" | "outline" | "ghost" }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" variant={variant} disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

export function CreateRegisterForm() {
  const [state, action] = useActionState(createRegisterAction, IDLE);
  return (
    <form action={action} className="space-y-3 border border-line bg-panel/40 p-4" data-testid="create-register">
      <h3 className="text-sm font-medium tracking-tightish">Kasa tanımla</h3>
      <p className="text-xs text-muted">Bu şubede henüz kasa yok. Satış için önce bir kasa gerekir.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="register-name">Kasa adı</Label>
          <Input id="register-name" name="name" required maxLength={60} placeholder="Örn. Kasa 1" className="h-11 sm:h-9" />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="register-device">Cihaz (isteğe bağlı)</Label>
          <Input id="register-device" name="device_ref" maxLength={80} placeholder="Örn. tablet-1" className="h-11 sm:h-9" />
        </div>
      </div>
      <FormMessage state={state} successText="Kasa oluşturuldu." />
      <Pending label="Kasayı oluştur" pendingLabel="Oluşturuluyor…" />
    </form>
  );
}

export function OpenSessionForm({ registers }: { registers: Register[] }) {
  const [state, action] = useActionState(openSessionAction, IDLE);
  const closed = registers.filter((r) => r.is_active && !r.open_session);
  if (closed.length === 0) return null;
  return (
    <form action={action} className="space-y-3 border border-line bg-panel/40 p-4" data-testid="open-session">
      <h3 className="text-sm font-medium tracking-tightish">Kasa aç</h3>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="open-register">Kasa</Label>
          <Select id="open-register" name="register_id" defaultValue={closed[0].id} className="h-11 sm:h-9">
            {closed.map((r) => (
              <option key={r.id} value={r.id}>{r.name}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="opening-cash">Açılış nakdi (TRY)</Label>
          <Input id="opening-cash" name="opening_cash" inputMode="decimal" defaultValue="0" className="h-11 text-right sm:h-9" />
        </div>
      </div>
      <FormMessage state={state} successText="Kasa açıldı." />
      <Pending label="Kasayı aç" pendingLabel="Açılıyor…" />
    </form>
  );
}

export function SessionBar({ register, caps, onSelect, selectedId, registers }: {
  register: Register;
  caps: PosCaps;
  registers: Register[];
  selectedId: string;
  onSelect: (id: string) => void;
}) {
  const [closeOpen, setCloseOpen] = useState(false);
  const [state, action] = useActionState(closeSessionAction, IDLE);
  const session = register.open_session;
  const openOnes = registers.filter((r) => r.open_session);
  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-line pb-3 text-xs" data-testid="session-bar">
      {openOnes.length > 1 ? (
        <label className="flex items-center gap-2">
          <span className="text-muted">Kasa</span>
          <Select value={selectedId} onChange={(e) => onSelect(e.target.value)} className="h-9 w-40 sm:h-8">
            {openOnes.map((r) => (
              <option key={r.id} value={r.id}>{r.name}</option>
            ))}
          </Select>
        </label>
      ) : (
        <span className="font-medium text-ink">{register.name}</span>
      )}
      {session ? (
        <span className="text-muted" data-numeric>
          {session.session_number} · açan {session.opened_by_name ?? "—"} · {formatDateTime(session.opened_at)}
        </span>
      ) : null}
      <span className="grow" />
      {session ? (
        <button type="button" className="text-xs text-ink-70 underline-offset-2 hover:underline" onClick={() => setCloseOpen((v) => !v)}>
          {closeOpen ? "Vazgeç" : "Kasayı kapat"}
        </button>
      ) : null}
      {closeOpen && session ? (
        <form action={action} className="basis-full space-y-2 border border-line bg-panel/40 p-3" data-testid="close-session">
          <input type="hidden" name="session_id" value={session.id} />
          <div className="flex flex-wrap items-end gap-2">
            <div className="w-40 space-y-1">
              <Label htmlFor="counted-cash">Sayılan nakit (TRY)</Label>
              <Input id="counted-cash" name="counted_cash" inputMode="decimal" required className="h-11 text-right sm:h-9" />
            </div>
            <div className="min-w-[12rem] flex-1 space-y-1">
              <Label htmlFor="close-note">Not</Label>
              <Input id="close-note" name="note" maxLength={200} className="h-11 sm:h-9" />
            </div>
            <Pending label="Kapat" pendingLabel="Kapatılıyor…" variant="outline" />
          </div>
          {!caps.canManageRegisters ? <p className="text-2xs text-muted">Kasa sayımı kayda geçer; fark yönetici tarafından incelenir.</p> : null}
          <FormMessage state={state} successText="Kasa kapatıldı." />
        </form>
      ) : null}
    </div>
  );
}
