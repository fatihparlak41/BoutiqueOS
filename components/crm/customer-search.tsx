"use client";

import { useState } from "react";
import Link from "next/link";
import { Search, Users } from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Notice } from "@/components/catalog/intake/primitives";
import { searchCustomersAction } from "@/app/app/musteriler/actions";
import type { CustomerHit, CustomerSource } from "@/lib/crm/model";
import { formatDateTime } from "@/lib/receiving/format";

/** Name / phone / e-mail / Instagram search (bounded server RPC); recent customers until a search is made. */
export function CustomerSearch({ recent, sources }: { recent: CustomerHit[]; sources: CustomerSource[] }) {
  const [term, setTerm] = useState("");
  const [results, setResults] = useState<CustomerHit[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const label = (code: string | null) => sources.find((s) => s.code === code)?.label ?? code ?? "";

  async function search() {
    const q = term.trim();
    if (q.length < 2) { setResults(null); return; }
    setBusy(true); setError(null);
    const res = await searchCustomersAction(q);
    setBusy(false);
    if (!res.ok) setError(res.error); else setResults(res.data);
  }
  const rows = results ?? recent;
  return (
    <div className="space-y-3" data-testid="customer-search">
      <form onSubmit={(e) => { e.preventDefault(); void search(); }} className="flex items-end gap-2">
        <div className="flex-1">
          <div className="relative">
            <Search aria-hidden className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
            <Input value={term} onChange={(e) => setTerm(e.target.value)} placeholder="Ad, telefon, e-posta ya da Instagram" className="h-12 pl-8 text-base sm:h-10" autoComplete="off" aria-label="Müşteri ara" />
          </div>
        </div>
        <Button type="submit" variant="outline" size="md" disabled={busy || term.trim().length < 2}>{busy ? "…" : "Ara"}</Button>
      </form>
      {error ? <Notice tone="danger">{error}</Notice> : null}
      <p className="text-2xs text-muted">{results ? `${results.length} sonuç` : "Son eklenen müşteriler"}</p>
      {rows.length === 0 ? (
        results ? (
          <EmptyState compact title="Eşleşen müşteri yok" description="Ad, telefon, e-posta ya da Instagram kullanıcı adıyla ara." />
        ) : (
          <EmptyState icon={<Users />} title="İlk müşterini ekle" description="Telefon ya da Instagram yeter; satışlar ve rezervasyonlar müşteriye kendiliğinden bağlanır." action={<Link href="/app/musteriler/yeni"><Button variant="outline">Müşteri ekle</Button></Link>} />
        )
      ) : (
        <ul className="divide-y divide-line border-y border-line" data-testid="customer-results">
          {rows.map((c) => (
            <li key={c.id}>
              <Link href={`/app/musteriler/${c.id}`} className="flex items-center gap-3 px-1 py-3 hover:bg-panel">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-ink">{c.full_name}{!c.is_active ? <span className="ml-2 text-2xs text-muted">arşiv</span> : null}</p>
                  <p className="truncate text-2xs text-muted" data-numeric>{[c.phone, c.email, c.instagram ? `@${c.instagram}` : null].filter(Boolean).join(" · ") || "iletişim bilgisi yok"}</p>
                </div>
                <div className="text-right text-2xs text-muted" data-numeric>
                  {c.source ? <p>{label(c.source)}</p> : null}
                  <p>{c.order_count > 0 ? `${c.order_count} satış` : "satış yok"}{c.last_purchase_at ? ` · ${formatDateTime(c.last_purchase_at)}` : ""}</p>
                </div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
