"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { Notice } from "@/components/catalog/intake/primitives";
import { createCustomerAction, duplicateProbeAction, updateCustomerAction } from "@/app/app/musteriler/actions";
import type { CrmCaps, Customer, CustomerSource, DuplicateHit } from "@/lib/crm/model";

/**
 * Short on purpose: name, phone, e-mail, Instagram, source, note. While the person types
 * a phone / e-mail / Instagram the server probes the tenant for the same normalised value
 * and shows who already has it; saving over a match needs a manager's explicit
 * confirmation and never merges anything.
 */
const MATCH_LABEL: Record<DuplicateHit["match"], string> = { phone: "aynı telefon", email: "aynı e-posta", instagram: "aynı Instagram" };

export function CustomerForm({ sources, caps, initial, redirectTo }: { sources: CustomerSource[]; caps: CrmCaps; initial?: Customer; redirectTo?: string }) {
  const router = useRouter();
  const [fullName, setFullName] = useState(initial?.full_name ?? "");
  const [phone, setPhone] = useState(initial?.phone ?? "");
  const [email, setEmail] = useState(initial?.email ?? "");
  const [instagram, setInstagram] = useState(initial?.instagram ?? "");
  const [source, setSource] = useState(initial?.source ?? (initial ? "" : "walk_in"));
  const [notes, setNotes] = useState(initial?.notes ?? "");
  const [confirm, setConfirm] = useState(false);
  const [dups, setDups] = useState<DuplicateHit[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const timer = useRef<number | null>(null);

  // probe duplicates a moment after the contact fields settle
  useEffect(() => {
    if (timer.current) window.clearTimeout(timer.current);
    if (!phone.trim() && !email.trim() && !instagram.trim()) { setDups([]); return; }
    timer.current = window.setTimeout(async () => {
      const res = await duplicateProbeAction({ phone: phone || null, email: email || null, instagram: instagram || null, excludeId: initial?.id ?? null });
      if (res.ok) setDups(res.data);
    }, 400);
    return () => { if (timer.current) window.clearTimeout(timer.current); };
  }, [phone, email, instagram, initial?.id]);

  function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    start(async () => {
      const input = { full_name: fullName, phone: phone || null, email: email || null, instagram: instagram || null, source: source || null, notes: notes || null, confirm_duplicate: confirm };
      const res = initial ? await updateCustomerAction(initial.id, input) : await createCustomerAction(input);
      if (!res.ok) { setError(res.error); return; }
      router.push(redirectTo ? `${redirectTo}${redirectTo.includes("?") ? "&" : "?"}musteri=${res.data.id}` : `/app/musteriler/${res.data.id}`);
    });
  }

  const blocked = dups.length > 0 && !(confirm && caps.canManage);
  return (
    <form onSubmit={submit} className="max-w-xl space-y-4" data-testid="customer-form">
      <div className="space-y-1.5">
        <Label htmlFor="c-name">Ad Soyad</Label>
        <Input id="c-name" value={fullName} onChange={(e) => setFullName(e.target.value)} required maxLength={120} autoFocus={!initial} className="h-11 sm:h-9" />
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="c-phone">Telefon</Label>
          <Input id="c-phone" value={phone} onChange={(e) => setPhone(e.target.value)} inputMode="tel" placeholder="0555 123 45 67" maxLength={32} className="h-11 sm:h-9" autoComplete="off" />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="c-email">E-posta (isteğe bağlı)</Label>
          <Input id="c-email" value={email} onChange={(e) => setEmail(e.target.value)} inputMode="email" maxLength={120} className="h-11 sm:h-9" autoComplete="off" />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="c-instagram">Instagram (isteğe bağlı)</Label>
          <Input id="c-instagram" value={instagram} onChange={(e) => setInstagram(e.target.value)} placeholder="@kullanici" maxLength={60} className="h-11 sm:h-9" autoComplete="off" />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="c-source">Kaynak</Label>
          <Select id="c-source" value={source} onChange={(e) => setSource(e.target.value)} className="h-11 sm:h-9">
            <option value="">—</option>
            {sources.map((s) => <option key={s.code} value={s.code}>{s.label}</option>)}
          </Select>
        </div>
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="c-notes">Not</Label>
        <Textarea id="c-notes" value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={500} rows={2} />
      </div>

      {dups.length > 0 ? (
        <div className="space-y-2 border border-warning/40 bg-warning-muted px-3 py-2 text-xs" role="status" data-testid="customer-duplicates">
          <p className="font-medium text-ink">Benzer kayıt var:</p>
          <ul className="space-y-1">
            {dups.map((d) => (
              <li key={d.id}>
                <Link href={`/app/musteriler/${d.id}`} className="underline-offset-2 hover:underline">{d.full_name}</Link>
                <span className="text-muted"> · {MATCH_LABEL[d.match]}{d.phone ? ` · ${d.phone}` : ""}</span>
              </li>
            ))}
          </ul>
          {caps.canManage ? (
            <label className="flex items-center gap-2 text-ink"><input type="checkbox" checked={confirm} onChange={(e) => setConfirm(e.target.checked)} className="h-4 w-4" /> Farklı bir kişi, yine de kaydet (yönetici onayı)</label>
          ) : (
            <p className="text-muted">Mevcut kaydı kullanın; ayrı bir kayıt yönetici onayı ister.</p>
          )}
        </div>
      ) : null}
      {error ? <Notice tone="danger">{error}</Notice> : null}
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="lg" disabled={pending || !fullName.trim() || blocked} data-testid="customer-save">{pending ? "Kaydediliyor…" : initial ? "Kaydet" : "Müşteriyi kaydet"}</Button>
        <Link href={initial ? `/app/musteriler/${initial.id}` : "/app/musteriler"} className="inline-flex h-11 items-center px-3 text-sm text-muted sm:h-9">Vazgeç</Link>
      </div>
    </form>
  );
}
