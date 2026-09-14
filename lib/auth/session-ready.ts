/**
 * Session readiness after a freshly issued JWT, kept free of Next and "server-only" so
 * it runs under plain Node (tests/auth/check_session_ready.ts).
 *
 * The upstream condition (confirmed twice live on 2026-09-14, project
 * fpmcnovurkpjwhosrkms): right after Auth issues a token — measured after a password
 * update through a recovery session — PostgREST can reject it with PGRST303
 * "JWT issued at future" for a moment. A single blind pause (lib/auth/jwt-skew.ts,
 * 1.2 s) was not enough. Instead of turning that into a Next server exception, the
 * tenant bootstrap now sends the visitor to /auth/session-ready, a page that renders no
 * tenant data at all and polls a read-only probe on a bounded schedule until the token
 * is accepted, then continues to where the visitor was going.
 *
 * Boundaries, all deliberate:
 *   * only the fresh-JWT rejection is treated this way; every other error still throws
 *   * the probe is read-only and RLS-scoped to the caller's own membership rows
 *   * the schedule is finite: 0 s, 1 s, 2 s, 4 s, 8 s — about 15 s in total
 *   * `next` is an exact-match allowlist, never a free-form path
 *   * no service role, no relaxed JWT validation, no token in any log
 */

import { isFreshJwtError, type QueryError } from "./jwt-skew.ts";

// ------------------------------------------------------------------ destinations

export const SESSION_READY_PATH = "/auth/session-ready";

/** Exact paths a readiness wait may continue to. Anything else falls back to the first. */
export const SESSION_READY_NEXT_ALLOWLIST = ["/app", "/select-business"] as const;

export type SessionReadyNext = (typeof SESSION_READY_NEXT_ALLOWLIST)[number];

export function safeSessionReadyNext(value: string | null | undefined): SessionReadyNext {
  if (typeof value !== "string") return SESSION_READY_NEXT_ALLOWLIST[0];
  const trimmed = value.trim();
  return (SESSION_READY_NEXT_ALLOWLIST as readonly string[]).includes(trimmed)
    ? (trimmed as SessionReadyNext)
    : SESSION_READY_NEXT_ALLOWLIST[0];
}

export function sessionReadyPath(next: SessionReadyNext): string {
  return `${SESSION_READY_PATH}?next=${encodeURIComponent(next)}`;
}

/** Where setPasswordAction sends the visitor: never straight into a tenant-loading route. */
export const AFTER_PASSWORD_UPDATE_PATH = sessionReadyPath("/app");

// ------------------------------------------------------------------ PostgREST classification

/** PostgREST's code for a JWT whose claims failed validation (iat in the future, here). */
export const PGRST_JWT_CLAIMS_CODE = "PGRST303";

/**
 * True only for the fresh-token rejection: PostgREST code PGRST303, or the literal
 * "JWT issued at future" message. An expired token, a bad key, a permission error and
 * every other failure return false.
 */
export function isFreshJwtRejection(error: QueryError | null | undefined): boolean {
  if (!error) return false;
  if (isFreshJwtError(error)) return true;
  return error.code === PGRST_JWT_CLAIMS_CODE;
}

export type TenantReadOutcome =
  | { kind: "proceed" }
  | { kind: "redirect"; to: string }
  | { kind: "throw"; message: string };

/**
 * What the tenant bootstrap does with the result of one of its reads. Only the
 * fresh-JWT rejection becomes a redirect to the readiness page; every other error is
 * thrown with its original message so nothing is hidden.
 */
export function tenantReadOutcome(
  label: string,
  error: QueryError | null | undefined,
  next: SessionReadyNext = "/app",
): TenantReadOutcome {
  if (!error) return { kind: "proceed" };
  if (isFreshJwtRejection(error)) return { kind: "redirect", to: sessionReadyPath(next) };
  return { kind: "throw", message: `${label}: ${error.message}` };
}

// ------------------------------------------------------------------ readiness probe

export type ProbeResult =
  | { status: "ready" }
  | { status: "not_ready" }
  | { status: "unauthenticated" }
  | { status: "error"; message: string };

/**
 * Turns the probe's raw observations into a result. The probe itself is a minimal
 * read of the caller's own membership rows; this function never sees a token.
 */
export function probeOutcome(hasUser: boolean, error: QueryError | null | undefined): ProbeResult {
  if (!hasUser) return { status: "unauthenticated" };
  if (!error) return { status: "ready" };
  if (isFreshJwtRejection(error)) return { status: "not_ready" };
  return { status: "error", message: error.message };
}

// ------------------------------------------------------------------ bounded polling

/** Delays before each attempt, in ms: 0, 1, 2, 4, 8 s — five attempts, ~15 s total. */
export const READINESS_SCHEDULE_MS: readonly number[] = [0, 1000, 2000, 4000, 8000];

export type ReadinessOutcome =
  | { outcome: "ready"; attempts: number }
  | { outcome: "exhausted"; attempts: number }
  | { outcome: "unauthenticated"; attempts: number }
  | { outcome: "error"; attempts: number; message: string };

export type RunReadinessOptions = {
  schedule?: readonly number[];
  /** Injectable for tests; defaults to a real timer. */
  sleep?: (ms: number) => Promise<void>;
  /** Lets an unmounted component stop the loop; checked before every attempt. */
  isCancelled?: () => boolean;
};

const realSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Runs the probe on the schedule. Continues only on `not_ready`; any other answer ends
 * the loop immediately. Never loops past the schedule.
 */
export async function runReadiness(
  probe: () => Promise<ProbeResult>,
  options: RunReadinessOptions = {},
): Promise<ReadinessOutcome> {
  const schedule = options.schedule ?? READINESS_SCHEDULE_MS;
  const sleep = options.sleep ?? realSleep;
  let attempts = 0;

  for (const delay of schedule) {
    if (options.isCancelled?.()) break;
    if (delay > 0) await sleep(delay);
    if (options.isCancelled?.()) break;

    attempts += 1;
    const result = await probe();

    if (result.status === "ready") return { outcome: "ready", attempts };
    if (result.status === "unauthenticated") return { outcome: "unauthenticated", attempts };
    if (result.status === "error") return { outcome: "error", attempts, message: result.message };
    // not_ready: fall through to the next scheduled attempt
  }

  return { outcome: "exhausted", attempts };
}
