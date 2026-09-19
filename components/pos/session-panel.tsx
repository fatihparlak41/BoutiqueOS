"use client";

import { useActionState, useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { useToast } from "@/components/ui/toast";
import { Notice } from "@/components/catalog/intake/primitives";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE } from "@/lib/catalog/action-state";
import { closeSessionAction, createRegisterAction, openSessionAction } from "@/app/app/pos/actions";
import type { PosCaps, Register } from "@/lib/pos/model";
import { formatDateTime } from "@/lib/receiving/format";

/**
 * Before selling: pick a register, open a drawer (or use the one already open), close it
 * at the end of the shift. A manager can create the branch's first register here.
 */

function Pending({ label, pendingLabel, variant = "solid" }: { label: string; pendingLabel: string; variant?: "solid" | "outline" | "ghost" | "accent" }) {
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
      <h3 className="text-sm font-medium tracking-tightish">Kasayı aç</h3>
      <p className="text-xs text-muted">Çekmecedeki nakdi say ve yaz; satış bu oturumda kaydedilir.</p>
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
      <Pending label="Kasayı aç" pendingLabel="Açılıyor…" variant="accent" />
    </form>
  );
}

/** A drawer open longer than this is worth a word; sixteen hours covers any single shift. */
const LONG_OPEN_HOURS = 16;

/** "16 Eylül" in the device's own calendar; the terminal's clock is the shop's clock. */
function dayLabel(iso: string): string {
  return new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long" }).format(new Date(iso));
}

export function SessionBar({ register, caps, onSelect, selectedId, registers }: {
  register: Register;
  caps: PosCaps;
  registers: Register[];
  selectedId: string;
  onSelect: (id: string) => void;
}) {
  const router = useRouter();
  const { toast } = useToast();
  const [closeOpen, setCloseOpen] = useState(false);
  const [counted, setCounted] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  // hours are computed after mount so the server-rendered markup never disagrees with the device clock
  const [hoursOpen, setHoursOpen] = useState<number | null>(null);
  const session = register.open_session;
  const openOnes = registers.filter((r) => r.open_session);
  useEffect(() => {
    if (!session) return setHoursOpen(null);
    setHoursOpen((Date.now() - new Date(session.opened_at).getTime()) / 36e5);
  }, [session]);
  const longOpen = session !== null && hoursOpen !== null && hoursOpen >= LONG_OPEN_HOURS;

  function closeSession() {
    if (!session) return;
    setError(null);
    start(async () => {
      const fd = new FormData();
      fd.set("session_id", session.id);
      fd.set("counted_cash", counted);
      fd.set("note", note);
      const res = await closeSessionAction(IDLE, fd);
      if (!res.ok) return setError(res.error ?? "Kasa kapatılamadı.");
      setCloseOpen(false);
      toast({ tone: "success", title: "Kasa kapatıldı.", description: `${register.name} · ${session.session_number}` });
      router.refresh();
    });
  }

  return (
    <div className="space-y-2" data-testid="session-bar">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-line pb-3 text-xs">
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
            <span className="text-success">Açık</span> · {session.session_number} · {session.opened_by_name ?? "—"} · {formatDateTime(session.opened_at)}
          </span>
        ) : null}
        <span className="grow" />
        {session && caps.canManageRegisters ? (
          <button type="button" className="text-xs text-ink-70 underline-offset-2 hover:underline" onClick={() => setCloseOpen(true)} data-testid="close-session-button">
            Kasayı kapat
          </button>
        ) : null}
      </div>

      {longOpen && session ? (
        <Notice tone="warning">
          <div className="flex flex-wrap items-center justify-between gap-2" data-testid="long-open-warning">
            <span>Kasa oturumu <span data-numeric>{dayLabel(session.opened_at)}</span>&apos;den beri açık.</span>
            <details className="basis-full sm:basis-auto">
              <summary className="cursor-pointer list-none text-xs underline underline-offset-4">Detay</summary>
              <p className="mt-2 text-xs text-text-secondary">
                {session.session_number} · {register.name} · açan {session.opened_by_name ?? "—"} · <span data-numeric>{formatDateTime(session.opened_at)}</span>
                {hoursOpen !== null && hoursOpen >= 48 ? <> · <span data-numeric>{Math.floor(hoursOpen / 24)} gün</span></> : null}.
                {" "}Satış bu oturumda sürer; oturumu yalnız işletme sahibi ya da yönetici &quot;Kasayı kapat&quot; ile kapatır, kendiliğinden kapanmaz.
              </p>
            </details>
          </div>
        </Notice>
      ) : null}

      {session ? (
        <ConfirmDialog
          open={closeOpen}
          onClose={() => (pending ? undefined : setCloseOpen(false))}
          title="Kasa kapatılsın mı?"
          description={`${register.name} · ${session.session_number}. Çekmecedeki nakdi say ve yaz; oturum kapanır, fark kayda geçer. Bu geri alınamaz.`}
          confirmLabel="Kasayı kapat"
          destructive
          busy={pending}
          onConfirm={closeSession}
        >
          <div className="space-y-3" data-testid="close-session">
            <div className="space-y-1">
              <Label htmlFor="counted-cash">Sayılan nakit (TRY)</Label>
              <Input id="counted-cash" name="counted_cash" value={counted} onChange={(e) => setCounted(e.target.value)} inputMode="decimal" required className="h-11 text-right sm:h-9" autoFocus />
            </div>
            <div className="space-y-1">
              <Label htmlFor="close-note">Not</Label>
              <Input id="close-note" name="note" value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} className="h-11 sm:h-9" />
            </div>
            {error ? <p role="alert" className="text-xs text-danger">{error}</p> : null}
          </div>
        </ConfirmDialog>
      ) : null}
    </div>
  );
}
