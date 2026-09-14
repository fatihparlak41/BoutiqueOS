/**
 * Password-reset request outcome handling, kept free of Next and "server-only" so it
 * can be exercised under plain Node (tests/auth/check_reset_request.ts).
 *
 * Two audiences, two different answers:
 *
 *   * The visitor always gets the same generic state. Anything else — a different
 *     message, a different timing, a thrown error — would turn the form into an
 *     account-enumeration oracle for the tenant's staff list.
 *   * The operator gets a structured server log when delivery failed. Without it a
 *     failure has no trace anywhere: resetPasswordForEmail() never throws (transport
 *     errors and gateway rejections both come back as `error`), and auth-js
 *     deliberately does not log them either.
 *
 * The log carries operational metadata only. The address, the redirect URL, tokens
 * and keys are never part of it.
 */

export type ResetRequestState = { done: boolean; error: string | null };

/** Structural subset of auth-js AuthError — enough to log, no library import needed. */
export type ResetDeliveryError = {
  name: string;
  status?: number;
  code?: string;
  message: string;
};

export type ResetDeliveryResult = { error: ResetDeliveryError | null };

export type ResetFailureLog = {
  name: string;
  status: number | null;
  code: string | null;
  message: string;
};

export type ResetFailureLogger = (label: string, payload: ResetFailureLog) => void;

export const RESET_FAILURE_LABEL = "[auth] password reset delivery failed";

/** What the visitor sees, whatever happened. */
export const GENERIC_RESET_STATE: ResetRequestState = { done: true, error: null };

/**
 * Records a failed delivery for the operator and returns the visitor's generic state.
 * Pure: no retry, no side effect beyond the logger call.
 */
export function settleResetRequest(
  result: ResetDeliveryResult,
  log: ResetFailureLogger,
): ResetRequestState {
  if (result.error) {
    log(RESET_FAILURE_LABEL, {
      name: result.error.name,
      status: result.error.status ?? null,
      code: result.error.code ?? null,
      message: result.error.message,
    });
  }
  return GENERIC_RESET_STATE;
}
