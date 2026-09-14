/**
 * Regression tests for the fresh-JWT clock-skew retry used by the tenant bootstrap.
 *
 * Runs under plain Node with type stripping — no test framework, no new dependency:
 *
 *   node --experimental-strip-types tests/auth/check_jwt_skew_retry.ts
 *
 * lib/auth/jwt-skew.ts is deliberately free of "server-only" and of Next imports so it
 * can be exercised here directly. Import is relative because the "@/" alias is a bundler
 * feature that plain Node does not resolve.
 */

import {
  FRESH_JWT_RETRY_DELAY_MS,
  isFreshJwtError,
  withFreshJwtRetry,
  type QueryError,
} from "../../lib/auth/jwt-skew.ts";

let pass = 0;
const failures: string[] = [];

function check(name: string, actual: unknown, expected: unknown): void {
  if (Object.is(actual, expected)) {
    pass += 1;
    return;
  }
  failures.push(`${name}\n    beklenen: ${String(expected)}\n    gelen:    ${String(actual)}`);
}

const SKEW: QueryError = { message: "JWT issued at future", code: "PGRST301" };
const EXPIRED: QueryError = { message: "JWT expired", code: "PGRST301" };
const FORBIDDEN: QueryError = { message: "permission denied for table business_members", code: "42501" };
const NOT_FOUND: QueryError = { message: 'relation "public.nope" does not exist', code: "42P01" };

/** A scripted query: returns the queued results in order and counts calls. */
function scripted(results: Array<QueryError | null>) {
  let calls = 0;
  const run = async () => {
    const error = results[Math.min(calls, results.length - 1)] ?? null;
    calls += 1;
    return { data: error ? null : { ok: true }, error };
  };
  return { run, calls: () => calls };
}

/** A recording sleep: never actually waits. */
function fakeSleep() {
  const waits: number[] = [];
  return { waits, sleep: async (ms: number) => void waits.push(ms) };
}

// ---------------------------------------------------------------- classifier
check("classifier: exact message", isFreshJwtError(SKEW), true);
check("classifier: case-insensitive", isFreshJwtError({ message: "jwt ISSUED AT future" }), true);
check("classifier: expired is not skew", isFreshJwtError(EXPIRED), false);
check("classifier: code alone is not enough", isFreshJwtError({ message: "JWT expired", code: "PGRST301" }), false);
check("classifier: null", isFreshJwtError(null), false);
check("classifier: undefined", isFreshJwtError(undefined), false);

// ---------------------------------------------------------------- A) normal success
{
  const q = scripted([null]);
  const s = fakeSleep();
  const r = await withFreshJwtRetry(q.run, { sleep: s.sleep });
  check("A: success -> one call", q.calls(), 1);
  check("A: success -> no sleep", s.waits.length, 0);
  check("A: success -> no error", r.error, null);
}

// ---------------------------------------------------------------- B) skew then success
{
  const q = scripted([SKEW, null]);
  const s = fakeSleep();
  const r = await withFreshJwtRetry(q.run, { sleep: s.sleep });
  check("B: skew -> two calls", q.calls(), 2);
  check("B: skew -> exactly one sleep", s.waits.length, 1);
  check("B: skew -> default delay", s.waits[0], FRESH_JWT_RETRY_DELAY_MS);
  check("B: skew -> default delay within 1000-1500ms", FRESH_JWT_RETRY_DELAY_MS >= 1000 && FRESH_JWT_RETRY_DELAY_MS <= 1500, true);
  check("B: skew -> second result returned", r.error, null);
}
{
  const q = scripted([SKEW, null]);
  const s = fakeSleep();
  await withFreshJwtRetry(q.run, { sleep: s.sleep, delayMs: 1500 });
  check("B: custom delay honoured", s.waits[0], 1500);
}

// ---------------------------------------------------------------- C) skew twice
{
  const q = scripted([SKEW, SKEW, null]);
  const s = fakeSleep();
  const r = await withFreshJwtRetry(q.run, { sleep: s.sleep });
  check("C: skew twice -> exactly two calls (max 1 retry)", q.calls(), 2);
  check("C: skew twice -> one sleep", s.waits.length, 1);
  check("C: skew twice -> final error surfaces", r.error?.message, SKEW.message);
}

// ---------------------------------------------------------------- D) unrelated auth error
{
  const q = scripted([EXPIRED, null]);
  const s = fakeSleep();
  const r = await withFreshJwtRetry(q.run, { sleep: s.sleep });
  check("D: expired -> one call, no retry", q.calls(), 1);
  check("D: expired -> no sleep", s.waits.length, 0);
  check("D: expired -> error surfaces", r.error?.message, EXPIRED.message);
}
{
  const q = scripted([FORBIDDEN, null]);
  const s = fakeSleep();
  const r = await withFreshJwtRetry(q.run, { sleep: s.sleep });
  check("D: 403-style -> one call, no retry", q.calls(), 1);
  check("D: 403-style -> error surfaces", r.error?.message, FORBIDDEN.message);
}

// ---------------------------------------------------------------- E) unrelated PostgREST error
{
  const q = scripted([NOT_FOUND, null]);
  const s = fakeSleep();
  const r = await withFreshJwtRetry(q.run, { sleep: s.sleep });
  check("E: postgrest error -> one call, no retry", q.calls(), 1);
  check("E: postgrest error -> no sleep", s.waits.length, 0);
  check("E: postgrest error -> error surfaces", r.error?.code, NOT_FOUND.code);
}

// ---------------------------------------------------------------- thrown errors are not swallowed
{
  let threw = false;
  try {
    await withFreshJwtRetry(async () => {
      throw new Error("boom");
    }, { sleep: async () => {} });
  } catch (e) {
    threw = (e as Error).message === "boom";
  }
  check("thrown error propagates", threw, true);
}

// ---------------------------------------------------------------- report
if (failures.length > 0) {
  console.error(`FAIL ${failures.length} / PASS ${pass}\n\n` + failures.join("\n\n"));
  process.exit(1);
}
console.log(`PASS ${pass} FAIL 0`);
