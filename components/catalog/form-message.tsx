import type { ActionState } from "@/lib/catalog/action-state";

/**
 * One place for action feedback so no screen accidentally renders a raw database error.
 * `state.error` is already a translated sentence (lib/catalog/errors.ts). A success
 * detail returned by the action ("6 varyant oluşturuldu") wins over the static text.
 */
export function FormMessage({ state, successText }: { state: ActionState; successText?: string }) {
  if (state.error) {
    return (
      <p role="alert" className="rounded border border-danger/30 bg-danger-muted/50 px-3 py-2 text-sm text-danger">
        {state.error}
      </p>
    );
  }

  const text = state.ok ? (state.message ?? successText) : undefined;
  if (text) {
    return (
      <p role="status" className="rounded border border-success/25 bg-success-muted px-3 py-2 text-sm text-success">
        {text}
      </p>
    );
  }

  return null;
}
