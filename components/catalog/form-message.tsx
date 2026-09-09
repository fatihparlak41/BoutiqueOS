import type { ActionState } from "@/lib/catalog/action-state";

/**
 * One place for action feedback so no screen accidentally renders a raw database error.
 * `state.error` is already a translated sentence (lib/catalog/errors.ts).
 */
export function FormMessage({ state, successText }: { state: ActionState; successText?: string }) {
  if (state.error) {
    return (
      <p role="alert" className="border-l-2 border-danger bg-panel px-3 py-2 text-sm text-danger">
        {state.error}
      </p>
    );
  }

  if (state.ok && successText) {
    return (
      <p role="status" className="border-l-2 border-accent bg-accent-soft px-3 py-2 text-sm text-accent">
        {successText}
      </p>
    );
  }

  return null;
}
