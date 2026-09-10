"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { ROLE_LABELS, type UserRole } from "@/lib/roles";
import { selectBusinessAction, type SelectBusinessState } from "@/app/auth/actions";

/**
 * Business picker.
 *
 * This was a plain <form action={selectBusinessAction}> inside the Server Component.
 * That form never worked in production: React parked its pre-hydration guard on it
 * (action="javascript:throw …"), the page carried no client component to hydrate it,
 * and no progressive-enhancement fields were emitted either — so clicking the button
 * produced no request at all. The screen only appears for an account with more than one
 * membership, which is why it went unnoticed until Phase 4 created the first one.
 *
 * Every other form in this app uses useActionState from a client component and works.
 * This now matches them, and a rejected selection reports inline instead of bouncing
 * through a query parameter.
 */

type Option = {
  business_id: string;
  business_name: string;
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
      className="flex w-full items-center justify-between gap-4 px-1 py-4 text-left transition-colors hover:bg-panel focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
    >
      <span className="min-w-0">
        <span className="block truncate font-serif text-base tracking-tightish">
          {option.business_name}
        </span>
        <span className="mt-0.5 block text-xs text-muted">
          {ROLE_LABELS[option.role]}
          <span className="mx-1.5 text-line-strong">/</span>
          {option.branch_count} şube
        </span>
      </span>
      <span aria-hidden className="text-muted">
        {pending ? "…" : "›"}
      </span>
    </button>
  );
}

export function BusinessPicker({ options }: { options: Option[] }) {
  const [state, formAction] = useActionState(selectBusinessAction, initialState);

  return (
    <>
      {state.error ? (
        <p role="alert" className="mt-6 border-l-2 border-danger bg-panel px-3 py-2 text-sm text-danger">
          {state.error}
        </p>
      ) : null}

      {/* One form, one submit button per option: the clicked button carries the id. */}
      <form action={formAction}>
        <ul className="mt-8 divide-y divide-line border-y border-line">
          {options.map((option) => (
            <li key={option.business_id}>
              <Choice option={option} />
            </li>
          ))}
        </ul>
      </form>
    </>
  );
}
