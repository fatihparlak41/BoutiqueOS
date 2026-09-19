"use client";

import { useState } from "react";
import Link from "next/link";
import { Search, SlidersHorizontal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Sheet } from "@/components/ui/sheet";

/**
 * The one list-filter pattern: a search field first, then "Filtre". The select controls
 * live in a side sheet on a phone and, when `inline` is set, sit next to the search from
 * lg up. Plain GET forms; the page owns the params and the query. Nothing here reads data.
 */
export type FilterSelect = { name: string; label: string; value: string; options: Array<{ value: string; label: string }>; allLabel?: string };

export function SearchFilters({
  basePath,
  searchName = "q",
  search,
  placeholder,
  selects,
  hidden = {},
  inline = false,
  clearLabel = "Temizle",
}: {
  basePath: string;
  searchName?: string;
  search: string;
  placeholder: string;
  selects: FilterSelect[];
  /** params to carry along (e.g. a branch) */
  hidden?: Record<string, string>;
  inline?: boolean;
  clearLabel?: string;
}) {
  const [open, setOpen] = useState(false);
  const activeCount = selects.filter((s) => s.value).length;
  const hiddenInputs = Object.entries(hidden).filter(([, v]) => v).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />);

  const controls = selects.map((s) => (
    <div key={s.name} className="space-y-1.5">
      <Label htmlFor={`f-${s.name}`}>{s.label}</Label>
      <Select id={`f-${s.name}`} name={s.name} defaultValue={s.value} className="h-11 sm:h-10">
        <option value="">{s.allLabel ?? "Tümü"}</option>
        {s.options.map((o) => (
          <option key={o.value} value={o.value}>{o.label}</option>
        ))}
      </Select>
    </div>
  ));

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <form method="get" className="relative min-w-0 flex-1">
          <Search aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 stroke-[1.5] text-text-muted" />
          <label htmlFor={`search-${searchName}`} className="sr-only">Ara</label>
          <Input id={`search-${searchName}`} name={searchName} defaultValue={search} placeholder={placeholder} spellCheck={false} enterKeyHint="search" autoComplete="off" className="h-11 pl-9 text-base sm:h-10 sm:text-sm" />
          {hiddenInputs}
          {selects.filter((s) => s.value).map((s) => <input key={s.name} type="hidden" name={s.name} value={s.value} />)}
        </form>
        <Button type="button" variant="outline" onClick={() => setOpen(true)} aria-haspopup="dialog" className={inline ? "shrink-0 lg:hidden" : "shrink-0"} data-testid="filter-button">
          <SlidersHorizontal aria-hidden className="h-4 w-4" />
          Filtre{activeCount > 0 ? <span className="ml-1 rounded-full bg-accent px-1.5 text-2xs text-accent-foreground" data-numeric>{activeCount}</span> : null}
        </Button>
        {inline && selects.length > 0 ? (
          <form method="get" className="hidden items-end gap-2 lg:flex">
            {search ? <input type="hidden" name={searchName} value={search} /> : null}
            {hiddenInputs}
            {selects.map((s) => (
              <div key={s.name} className="min-w-[9rem]">
                <label htmlFor={`i-${s.name}`} className="sr-only">{s.label}</label>
                <Select id={`i-${s.name}`} name={s.name} defaultValue={s.value} className="h-10" aria-label={s.label}>
                  <option value="">{s.label}: {s.allLabel ?? "tümü"}</option>
                  {s.options.map((o) => (
                    <option key={o.value} value={o.value}>{o.label}</option>
                  ))}
                </Select>
              </div>
            ))}
            <Button type="submit" variant="outline">Uygula</Button>
            {activeCount > 0 || search ? <Link href={basePath} className="text-xs text-text-muted underline-offset-4 hover:underline">{clearLabel}</Link> : null}
          </form>
        ) : null}
      </div>

      <Sheet open={open} onClose={() => setOpen(false)} title="Filtrele" side="right" className="w-[min(22rem,92vw)]">
        <form method="get" className="space-y-4 p-4">
          {search ? <input type="hidden" name={searchName} value={search} /> : null}
          {hiddenInputs}
          {controls}
          <div className="flex items-center justify-between gap-2 pt-2">
            <Link href={basePath} className="text-xs text-text-muted underline-offset-4 hover:underline">{clearLabel}</Link>
            <Button type="submit">Uygula</Button>
          </div>
        </form>
      </Sheet>
    </div>
  );
}
