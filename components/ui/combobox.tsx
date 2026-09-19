"use client";

import * as React from "react";
import { Check, ChevronDown, Plus, Search, X } from "lucide-react";
import { cn } from "@/lib/utils";

/**
 * Searchable single-select on native elements (no overlay library): a button that shows
 * the chosen item, a panel with a search field and a listbox. Items may carry a `group`
 * (the parent) which is shown as "Üst Giyim › Bluzlar" and searched too. When the typed
 * text matches nothing, an explicit "+ Yeni … oluştur: X" row is offered — choosing it
 * calls `onCreate`, which decides (with its own confirmation) whether a row is written.
 * Nothing here writes anything by itself.
 *
 * Phone first: the panel is a bottom sheet (native <dialog>), the list rows are 44px.
 * Desktop: the same panel anchored under the field.
 */
export type ComboboxItem = { id: string; label: string; group?: string | null; keywords?: string };

function fold(s: string): string {
  return s.toLocaleLowerCase("tr-TR").replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

export function Combobox({
  id,
  value,
  items,
  onChange,
  placeholder = "Seçin",
  searchPlaceholder = "Ara…",
  emptyText = "Eşleşen kayıt yok.",
  createLabel,
  onCreate,
  disabled,
  className,
  "aria-label": ariaLabel,
}: {
  id: string;
  value: string | null;
  items: ComboboxItem[];
  onChange: (id: string | null) => void;
  placeholder?: string;
  searchPlaceholder?: string;
  emptyText?: string;
  /** "Yeni kategori oluştur" — shown with the typed text when nothing matches. */
  createLabel?: string;
  onCreate?: (name: string) => void;
  disabled?: boolean;
  className?: string;
  "aria-label"?: string;
}) {
  const [open, setOpen] = React.useState(false);
  const [query, setQuery] = React.useState("");
  const [active, setActive] = React.useState(0);
  const dialogRef = React.useRef<HTMLDialogElement>(null);
  const inputRef = React.useRef<HTMLInputElement>(null);

  const selected = items.find((i) => i.id === value) ?? null;
  const q = fold(query);
  const filtered = React.useMemo(() => {
    if (!q) return items;
    return items.filter((i) => fold(`${i.group ?? ""} ${i.label} ${i.keywords ?? ""}`).includes(q));
  }, [items, q]);
  const exact = filtered.some((i) => fold(i.label) === q);
  const canCreate = Boolean(onCreate && query.trim().length >= 2 && !exact);
  const rows = filtered.length + (canCreate ? 1 : 0);

  React.useEffect(() => {
    const el = dialogRef.current;
    if (!el) return;
    if (open && !el.open) {
      el.showModal();
      setQuery("");
      setActive(0);
      setTimeout(() => inputRef.current?.focus(), 30);
    }
    if (!open && el.open) el.close();
  }, [open]);

  React.useEffect(() => setActive(0), [q]);

  function pick(index: number) {
    if (index < filtered.length) {
      onChange(filtered[index].id);
      setOpen(false);
    } else if (canCreate && onCreate) {
      onCreate(query.trim());
      setOpen(false);
    }
  }

  return (
    <div className={cn("relative", className)}>
      <button
        id={id}
        type="button"
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={ariaLabel}
        onClick={() => setOpen(true)}
        className={cn(
          "flex min-h-11 w-full items-center justify-between gap-2 rounded border border-border-strong bg-surface px-3 text-left text-sm text-text-primary",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50 sm:min-h-10",
        )}
      >
        {selected ? (
          <span className="truncate">
            {selected.group ? <span className="text-text-muted">{selected.group} › </span> : null}
            {selected.label}
          </span>
        ) : (
          <span className="truncate text-text-muted">{placeholder}</span>
        )}
        <ChevronDown aria-hidden className="h-4 w-4 shrink-0 text-text-muted" />
      </button>

      <dialog
        ref={dialogRef}
        aria-label={ariaLabel ?? placeholder}
        onClose={() => setOpen(false)}
        onClick={(e) => {
          if (e.target === e.currentTarget) setOpen(false);
        }}
        className={cn(
          "m-0 mt-auto w-full max-w-none rounded-t-lg border border-border bg-surface p-0 text-text-primary shadow-md backdrop:bg-black/30",
          "sm:m-auto sm:w-[min(28rem,calc(100vw-2rem))] sm:rounded",
        )}
      >
        <div className="flex max-h-[80dvh] flex-col sm:max-h-[70vh]">
          <div className="flex items-center gap-2 border-b border-border px-3 py-2">
            <Search aria-hidden className="h-4 w-4 shrink-0 text-text-muted" />
            <input
              ref={inputRef}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "ArrowDown") { e.preventDefault(); setActive((a) => Math.min(rows - 1, a + 1)); }
                else if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => Math.max(0, a - 1)); }
                else if (e.key === "Enter") { e.preventDefault(); if (rows > 0) pick(active); }
              }}
              placeholder={searchPlaceholder}
              autoComplete="off"
              autoCorrect="off"
              spellCheck={false}
              role="combobox"
              aria-expanded="true"
              aria-controls={`${id}-listbox`}
              aria-activedescendant={rows > 0 ? `${id}-opt-${active}` : undefined}
              className="min-h-11 w-full bg-transparent text-base outline-none placeholder:text-text-muted sm:min-h-9 sm:text-sm"
            />
            <button type="button" onClick={() => setOpen(false)} aria-label="Kapat" className="inline-flex h-9 w-9 items-center justify-center rounded text-text-muted hover:bg-surface-muted hover:text-text-primary">
              <X aria-hidden className="h-4 w-4" />
            </button>
          </div>
          <ul id={`${id}-listbox`} role="listbox" className="min-h-0 flex-1 overflow-y-auto py-1">
            {value ? (
              <li>
                <button type="button" onClick={() => { onChange(null); setOpen(false); }} className="flex min-h-11 w-full items-center px-3 text-left text-sm text-text-muted hover:bg-surface-muted sm:min-h-9">
                  Seçimi kaldır
                </button>
              </li>
            ) : null}
            {filtered.map((item, i) => (
              <li
                key={item.id}
                id={`${id}-opt-${i}`}
                role="option"
                aria-selected={item.id === value}
                onMouseEnter={() => setActive(i)}
                onClick={() => pick(i)}
                className={cn(
                  "flex min-h-11 cursor-pointer items-center justify-between gap-3 px-3 text-sm sm:min-h-9",
                  i === active ? "bg-accent-muted text-text-primary" : "text-text-primary hover:bg-surface-muted",
                )}
              >
                <span className="truncate">
                  {item.group ? <span className="text-text-muted">{item.group} › </span> : null}
                  {item.label}
                </span>
                {item.id === value ? <Check aria-hidden className="h-4 w-4 shrink-0 text-accent" /> : null}
              </li>
            ))}
            {filtered.length === 0 && !canCreate ? <li className="px-3 py-3 text-sm text-text-muted">{emptyText}</li> : null}
            {canCreate ? (
              <li
                id={`${id}-opt-${filtered.length}`}
                role="option"
                aria-selected={false}
                onMouseEnter={() => setActive(filtered.length)}
                onClick={() => pick(filtered.length)}
                className={cn(
                  "flex min-h-11 cursor-pointer items-center gap-2 border-t border-border px-3 text-sm sm:min-h-9",
                  active === filtered.length ? "bg-accent-muted" : "hover:bg-surface-muted",
                )}
                data-testid="combobox-create"
              >
                <Plus aria-hidden className="h-4 w-4 shrink-0 text-accent" />
                <span>
                  {createLabel ?? "Yeni oluştur"}: <span className="font-medium">{query.trim()}</span>
                </span>
              </li>
            ) : null}
          </ul>
        </div>
      </dialog>
    </div>
  );
}
