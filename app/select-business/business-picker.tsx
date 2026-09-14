"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { ChevronRight } from "lucide-react";
import { ROLE_LABELS, type UserRole } from "@/lib/roles";
import { selectBusinessAction, type SelectBusinessState } from "@/app/auth/actions";

/**
 * Business picker: one form, one submit button per option, the clicked button carries
 * the id. A rejected selection reports inline. Every value shown was proven server-side
 * by loadMemberships; the click only expresses a preference the server re-checks.
 */

type Option = {
  business_id: string;
  business_name: string;
  business_code: string;
  role: UserRole;
  branch_count: number;
};

const initialState: SelectBusinessState = { error: null };

function Choice({ option }: { option: Option }) {
  const { pending } = useFormStatus();
  return (
    <button
      type="submit"
      name="business_id"
      value={option.business_id}
      disabled={pending}
      className="group flex w-full items-center justify-between gap-4 rounded border border-border bg-surface px-4 py-4 text-left transition-colors hover:border-border-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background disabled:opacity-50"
    >
      <span className="min-w-0">
        <span className="block truncate font-serif text-2xl font-semibold leading-tight tracking-tightish text-text-primary">
          {option.business_name}
        </span>
        <span className="mt-1 block text-xs text-text-muted">
          {ROLE_LABELS[option.role]}
          {" — "}
          {option.branch_count === 1 ? "1 şube" : `${option.branch_count} şube`}
          <span className="ml-2 text-text-muted/70" data-numeric>
            {option.business_code}
          </span>
        </span>
      </span>
      <ChevronRight
        aria-hidden
        className="h-4 w-4 shrink-0 stroke-[1.5] text-text-muted transition-colors group-hover:text-text-primary"
      />
      {pending ? <span className="sr-only">Açılıyor…</span> : null}
    </button>
  );
}

export function BusinessPicker({ options }: { options: Option[] }) {
  const [state, formAction] = useActionState(selectBusinessAction, initialState);

  return (
    <form action={formAction}>
      {state.error ? (
        <p role="alert" className="mb-4 rounded border border-danger/30 bg-danger-muted/50 px-3 py-2 text-sm text-danger">
          {state.error}
        </p>
      ) : null}
      <ul className="space-y-2">
        {options.map((option) => (
          <li key={option.business_id}>
            <Choice option={option} />
          </li>
        ))}
      </ul>
    </form>
  );
}
