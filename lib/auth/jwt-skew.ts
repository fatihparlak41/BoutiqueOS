/**
 * Fresh-JWT clock skew, kept free of Next and "server-only" so it runs under plain Node
 * (tests/auth/check_jwt_skew_retry.ts).
 *
 * A token minted by Auth in the same second a request reaches PostgREST can carry an
 * `iat` a moment ahead of the verifier's clock. PostgREST answers "JWT issued at future"
 * and the request fails although nothing is wrong with the session. Measured live on
 * 2026-09-14: setPasswordAction updated the password (PUT /user 200), redirected to /app,
 * and the very next read of business_members died with exactly that message.
 *
 * The tolerance here is deliberately narrow: this one message, one bounded delay, one
 * retry, read-only callers only. Nothing else is retried — not 401/403 in general, not
 * an expired token, not a write — and the final error always surfaces to the caller.
 */

export const FRESH_JWT_ERROR_FRAGMENT = "jwt issued at future";

/** Bounded pause before the single retry. Long enough for a one-second skew to pass. */
export const FRESH_JWT_RETRY_DELAY_MS = 1200;

/** Structural subset of a PostgREST / Supabase error — enough to classify, no import. */
export type QueryError = { message: string; code?: string | null };

export type QueryResult = { error: QueryError | null };

export function isFreshJwtError(error: QueryError | null | undefined): boolean {
  if (!error || typeof error.message !== "string") return false;
  return error.message.toLowerCase().includes(FRESH_JWT_ERROR_FRAGMENT);
}

export type RetryOptions = {
  delayMs?: number;
  /** Injectable for tests; defaults to a real timer. */
  sleep?: (ms: number) => Promise<void>;
};

const realSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Runs a READ-ONLY query thunk; if — and only if — it fails with the fresh-JWT message,
 * waits once and runs it a second time. The second result is returned as-is, error
 * included. Any other error returns immediately without a retry.
 */
export async function withFreshJwtRetry<T extends QueryResult>(
  run: () => Promise<T>,
  options: RetryOptions = {},
): Promise<T> {
  const first = await run();
  if (!isFreshJwtError(first.error)) return first;

  const sleep = options.sleep ?? realSleep;
  await sleep(options.delayMs ?? FRESH_JWT_RETRY_DELAY_MS);
  return run();
}
