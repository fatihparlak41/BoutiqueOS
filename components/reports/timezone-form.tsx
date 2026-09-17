"use client";

import { useActionState } from "react";
import { Button } from "@/components/ui/button";
import { Select } from "@/components/ui/select";
import { Label } from "@/components/ui/label";
import { setTimezoneAction } from "@/app/app/ayarlar/raporlama/actions";
import { TIMEZONE_IDLE, TIMEZONE_OPTIONS } from "@/lib/reports/model";

export function TimezoneForm({ current }: { current: string | null }) {
  const [state, formAction, pending] = useActionState(setTimezoneAction, TIMEZONE_IDLE);
  const known = current && TIMEZONE_OPTIONS.some((o) => o.value === current);
  return (
    <form action={formAction} className="max-w-md space-y-4">
      <div className="space-y-1.5">
        <Label htmlFor="timezone">Saat dilimi</Label>
        <Select id="timezone" name="timezone" defaultValue={known ? current : ""} required>
          <option value="" disabled>Seçin</option>
          {!known && current ? <option value={current}>{current} (mevcut)</option> : null}
          {TIMEZONE_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </Select>
      </div>
      {state.error ? <p className="text-xs text-danger" role="alert">{state.error}</p> : null}
      {state.ok ? <p className="text-xs text-text-secondary" role="status">Kaydedildi. Raporlar bu saat dilimine göre gün sayar.</p> : null}
      <Button type="submit" size="sm" disabled={pending}>{pending ? "Kaydediliyor…" : "Kaydet"}</Button>
    </form>
  );
}
