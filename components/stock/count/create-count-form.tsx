"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ClipboardCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Notice } from "@/components/catalog/intake/primitives";
import { COUNT_TYPE_HINTS, COUNT_TYPE_LABELS, type StockCountType } from "@/lib/stock/count-model";
import { createCountAction } from "@/app/app/stok/sayim/actions";

/**
 * Opening a count is one tap: the default is a full count of the default branch — the
 * safest, most common shop-floor action. Count type, branch (when there is more than one)
 * and the note sit under "Diğer seçenekler". The count semantics are unchanged: `full`
 * stays the default and the server decides everything else.
 */
export function CreateCountForm({ branches, defaultBranchId }: { branches: Array<{ id: string; name: string }>; defaultBranchId: string | null }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [branchId, setBranchId] = useState(defaultBranchId ?? branches[0]?.id ?? "");
  const [type, setType] = useState<StockCountType>("full");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const branchName = branches.find((b) => b.id === branchId)?.name ?? "—";
  const partial = type === "cycle";

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
      data-testid="create-count-form"
    >
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="text-sm font-medium text-text-primary">{partial ? "Bir kısmını say" : "Tüm mağazayı say"}</p>
          <p className="mt-0.5 text-xs text-text-muted">
            {partial ? `${branchName} · yalnız okuttuğun ürünler karşılaştırılır.` : `${branchName} · raftaki her şey okutulur, farklar sonra incelenir.`}
          </p>
        </div>
        <Button type="submit" variant="accent" disabled={pending || !branchId} className="w-full sm:w-auto" data-testid="create-count-submit">
          <ClipboardCheck aria-hidden className="h-4 w-4" />
          {pending ? "Açılıyor…" : "Sayımı başlat"}
        </Button>
      </div>

      <details className="group border-t border-border pt-3" data-testid="count-more-options">
        <summary className="cursor-pointer list-none text-xs text-text-secondary underline-offset-4 hover:underline">Diğer seçenekler</summary>
        <div className="mt-3 grid gap-4 sm:grid-cols-2">
          {branches.length > 1 ? (
            <div className="space-y-1.5">
              <Label htmlFor="count-branch">Şube</Label>
              <Select id="count-branch" value={branchId} onChange={(e) => setBranchId(e.target.value)}>
                {branches.map((b) => (
                  <option key={b.id} value={b.id}>{b.name}</option>
                ))}
              </Select>
            </div>
          ) : null}
          <div className="space-y-1.5">
            <Label htmlFor="count-type">Sayım türü</Label>
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
      </details>
      {error ? <Notice tone="danger">{error}</Notice> : null}
    </form>
  );
}
