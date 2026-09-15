"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Notice } from "@/components/catalog/intake/primitives";
import { COUNT_TYPE_HINTS, COUNT_TYPE_LABELS, type StockCountType } from "@/lib/stock/count-model";
import { createCountAction } from "@/app/app/stok/sayim/actions";

export function CreateCountForm({ branches, defaultBranchId }: { branches: Array<{ id: string; name: string }>; defaultBranchId: string | null }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [branchId, setBranchId] = useState(defaultBranchId ?? branches[0]?.id ?? "");
  const [type, setType] = useState<StockCountType>("full");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        setError(null);
        start(async () => {
          const res = await createCountAction({ branch_id: branchId, count_type: type, note });
          if (!res.ok) return setError(res.error);
          router.push(`/app/stok/sayim/${res.data}`);
        });
      }}
      className="space-y-4 rounded border border-border bg-surface p-4"
    >
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="count-branch">Şube</Label>
          <Select id="count-branch" value={branchId} onChange={(e) => setBranchId(e.target.value)}>
            {branches.map((b) => (
              <option key={b.id} value={b.id}>{b.name}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="count-type">Tür</Label>
          <Select id="count-type" value={type} onChange={(e) => setType(e.target.value as StockCountType)}>
            {(Object.keys(COUNT_TYPE_LABELS) as StockCountType[]).map((t) => (
              <option key={t} value={t}>{COUNT_TYPE_LABELS[t]}</option>
            ))}
          </Select>
          <p className="text-2xs text-text-muted">{COUNT_TYPE_HINTS[type]}</p>
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="count-note">Not</Label>
          <Input id="count-note" value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} placeholder="İsteğe bağlı (örn. sezon sonu sayımı)" />
        </div>
      </div>
      {error ? <Notice tone="danger">{error}</Notice> : null}
      <Button type="submit" disabled={pending || !branchId}>{pending ? "Açılıyor…" : "Sayımı başlat"}</Button>
    </form>
  );
}
