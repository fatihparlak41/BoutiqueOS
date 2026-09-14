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
 * One transient condition is retried, once: HTTP 525, an SSL/TLS handshake failure
 * between the edge and Auth's origin. Measured live on 2026-09-14 (~10:20:50 UTC):
 * the request never appeared in Supabase Auth logs, recovery_sent_at stayed put and no
 * token was created — Auth never processed it, so sending it again cannot double
 * anything. Every other outcome, including status 0 (fetch threw), 429, 5xx, is
 * final on the first attempt: a request that reached Auth is not replayed.
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
  attempt: number;
  name: string;
  status: number | null;
  code: string | null;
  message: string;
  /** Present on the final log of a retried request: what the first attempt saw. */
  previous?: Omit<ResetFailureLog, "attempt" | "previous">;
};

export type ResetLogger = {
  error: (label: string, payload: ResetFailureLog) => void;
  warn: (label: string, payload: ResetFailureLog) => void;
};

export const RESET_FAILURE_LABEL = "[auth] password reset delivery failed";
export const RESET_RECOVERED_LABEL = "[auth] password reset delivery recovered after transient 525";

/** The one status that is retried: edge ↔ origin TLS handshake failure, request never processed. */
export const TRANSIENT_TLS_STATUS = 525;

/** Bounded pause before the single retry. */
export const RESET_RETRY_DELAY_MS = 1700;

/** What the visitor sees, whatever happened. */
export const GENERIC_RESET_STATE: ResetRequestState = { done: true, error: null };

export function isTransientTlsFailure(error: ResetDeliveryError | null | undefined): boolean {
  return !!error && error.name === "AuthRetryableFetchError" && error.status === TRANSIENT_TLS_STATUS;
}

function describe(error: ResetDeliveryError): Omit<ResetFailureLog, "attempt" | "previous"> {
  return {
    name: error.name,
    status: error.status ?? null,
    code: error.code ?? null,
    message: error.message,
  };
}

/**
 * Records a failed delivery for the operator and returns the visitor's generic state.
 * Pure: no retry, no side effect beyond the logger call.
 */
export function settleResetRequest(
  result: ResetDeliveryResult,
  log: (label: string, payload: ResetFailureLog) => void,
  attempt = 1,
): ResetRequestState {
  if (result.error) {
    log(RESET_FAILURE_LABEL, { attempt, ...describe(result.error) });
  }
  return GENERIC_RESET_STATE;
}

export type DeliverOptions = {
  delayMs?: number;
  /** Injectable for tests; defaults to a real timer. */
  sleep?: (ms: number) => Promise<void>;
};

const realSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Sends the reset request; on a transient 525 — and only then — waits once and sends
 * it a second time. At most two calls ever. The visitor's state is identical in every
 * branch; only the operator log differs.
 */
export async function deliverResetRequest(
  send: () => Promise<ResetDeliveryResult>,
  log: ResetLogger,
  options: DeliverOptions = {},
): Promise<ResetRequestState> {
  const first = await send();
  if (!isTransientTlsFailure(first.error)) return settleResetRequest(first, log.error, 1);

  const sleep = options.sleep ?? realSleep;
  await sleep(options.delayMs ?? RESET_RETRY_DELAY_MS);

  const second = await send();
  const previous = describe(first.error as ResetDeliveryError);

  if (!second.error) {
    // The transient failure being reported is the first attempt's; the second succeeded.
    log.warn(RESET_RECOVERED_LABEL, { attempt: 2, ...previous });
    return GENERIC_RESET_STATE;
  }

  log.error(RESET_FAILURE_LABEL, { attempt: 2, ...describe(second.error), previous });
  return GENERIC_RESET_STATE;
}
