/**
 * Regression tests for the password-reset request outcome (Case C observability).
 *
 * Runs under plain Node with type stripping — no test framework, no new dependency:
 *
 *   node --experimental-strip-types tests/auth/check_reset_request.ts
 *
 * lib/auth/reset-request.ts is deliberately free of "server-only" and of Next imports so
 * it can be exercised here directly. Import is relative because the "@/" alias is a
 * bundler feature that plain Node does not resolve.
 */

import {
  GENERIC_RESET_STATE,
  RESET_FAILURE_LABEL,
  RESET_RECOVERED_LABEL,
  RESET_RETRY_DELAY_MS,
  deliverResetRequest,
  isTransientTlsFailure,
  settleResetRequest,
  type ResetDeliveryError,
  type ResetFailureLog,
} from "../../lib/auth/reset-request.ts";

let pass = 0;
const failures: string[] = [];

function check(name: string, actual: unknown, expected: unknown): void {
  if (Object.is(actual, expected)) {
    pass += 1;
    return;
  }
  failures.push(`${name}\n    beklenen: ${String(expected)}\n    gelen:    ${String(actual)}`);
}

/** Captures every logger call so both count and payload can be asserted. */
function recorder() {
  const calls: Array<{ label: string; payload: ResetFailureLog }> = [];
  return { calls, log: (label: string, payload: ResetFailureLog) => void calls.push({ label, payload }) };
}

const EMAIL = "someone@example.com";
const REDIRECT = "https://butikos.parlakmediatech.com.tr/sifre-belirle?token_hash=SECRET-TOKEN";

// Secrets that must never reach the log, whatever the library puts in its error.
const FORBIDDEN = [EMAIL, "SECRET-TOKEN", "token_hash", "hunter2", "sb_secret_", "otp=123456", REDIRECT];

// ---------------------------------------------------------------- A) success
{
  const r = recorder();
  const state = settleResetRequest({ error: null }, r.log);
  check("A: success -> no log", r.calls.length, 0);
  check("A: success -> done", state.done, true);
  check("A: success -> no visitor error", state.error, null);
  check("A: success -> generic state object", state, GENERIC_RESET_STATE);
}

// ---------------------------------------------------------------- B) transport failure
{
  const r = recorder();
  const state = settleResetRequest(
    { error: { name: "AuthRetryableFetchError", status: 0, message: "fetch failed" } },
    r.log,
  );
  check("B: transport -> log exactly once", r.calls.length, 1);
  check("B: transport -> label", r.calls[0]?.label, RESET_FAILURE_LABEL);
  check("B: transport -> name", r.calls[0]?.payload.name, "AuthRetryableFetchError");
  check("B: transport -> status 0 kept (not null)", r.calls[0]?.payload.status, 0);
  check("B: transport -> code null", r.calls[0]?.payload.code, null);
  check("B: transport -> still generic success", state.done, true);
  check("B: transport -> no visitor error", state.error, null);
}

// ---------------------------------------------------------------- C) gateway / API rejection
{
  const r = recorder();
  const state = settleResetRequest(
    { error: { name: "AuthApiError", status: 401, code: "invalid_api_key", message: "Invalid API key" } },
    r.log,
  );
  check("C: 401 -> log exactly once", r.calls.length, 1);
  check("C: 401 -> status", r.calls[0]?.payload.status, 401);
  check("C: 401 -> code", r.calls[0]?.payload.code, "invalid_api_key");
  check("C: 401 -> message", r.calls[0]?.payload.message, "Invalid API key");
  check("C: 401 -> still generic success", state.done, true);
  check("C: 401 -> no visitor error", state.error, null);
}
{
  const r = recorder();
  const state = settleResetRequest(
    { error: { name: "AuthApiError", status: 429, code: "over_email_send_rate_limit", message: "email rate limit exceeded" } },
    r.log,
  );
  check("C: 429 -> log exactly once", r.calls.length, 1);
  check("C: 429 -> code", r.calls[0]?.payload.code, "over_email_send_rate_limit");
  check("C: 429 -> still generic success", state.done, true);
}

// ---------------------------------------------------------------- D) payload hygiene
{
  // The payload is built from the error's own fields only; the address and redirect are
  // never handed to settleResetRequest, so they cannot leak even if the caller has them.
  const r = recorder();
  settleResetRequest(
    { error: { name: "AuthApiError", status: 500, code: "unexpected_failure", message: "Error sending recovery email" } },
    r.log,
  );
  const serialized = JSON.stringify(r.calls[0]);
  for (const secret of FORBIDDEN) {
    check(`D: payload does not contain ${secret.slice(0, 12)}…`, serialized.includes(secret), false);
  }
  check("D: payload keys are exactly attempt/name/status/code/message",
    Object.keys(r.calls[0]!.payload).sort().join(","), "attempt,code,message,name,status");
  check("D: single attempt is numbered 1", r.calls[0]!.payload.attempt, 1);
}

// ---------------------------------------------------------------- E) enumeration
{
  // Registered vs unknown address: the library answers `{ error: null }` for both, and a
  // delivery failure for a registered address must be indistinguishable too.
  const known = settleResetRequest({ error: null }, () => {});
  const unknown = settleResetRequest({ error: null }, () => {});
  const failed = settleResetRequest(
    { error: { name: "AuthRetryableFetchError", status: 0, message: "fetch failed" } },
    () => {},
  );
  check("E: known == unknown (json)", JSON.stringify(known), JSON.stringify(unknown));
  check("E: known == failed (json)", JSON.stringify(known), JSON.stringify(failed));
  check("E: known == unknown (identity)", known, unknown);
  check("E: known == failed (identity)", known, failed);
}

// ================================================================ deliverResetRequest
// Transient 525 (edge/origin TLS handshake, request never processed by Auth) is retried
// exactly once. Everything else is final on the first attempt.

const TLS_525: ResetDeliveryError = { name: "AuthRetryableFetchError", status: 525, message: "" };
const RATE_429: ResetDeliveryError = { name: "AuthApiError", status: 429, code: "over_email_send_rate_limit", message: "email rate limit exceeded" };
const FETCH_0: ResetDeliveryError = { name: "AuthRetryableFetchError", status: 0, message: "fetch failed" };
const SERVER_500: ResetDeliveryError = { name: "AuthApiError", status: 500, code: "unexpected_failure", message: "Error sending recovery email" };
const GATEWAY_503: ResetDeliveryError = { name: "AuthRetryableFetchError", status: 503, message: "" };
const AUTH_401: ResetDeliveryError = { name: "AuthApiError", status: 401, code: "invalid_api_key", message: "Invalid API key" };

/** Scripted sender: returns queued results in order and counts calls. */
function sender(results: Array<ResetDeliveryError | null>) {
  let calls = 0;
  const send = async () => {
    const error = results[Math.min(calls, results.length - 1)] ?? null;
    calls += 1;
    return { error };
  };
  return { send, calls: () => calls };
}

/** Recording logger: never prints. */
function logger() {
  const errors: Array<{ label: string; payload: ResetFailureLog }> = [];
  const warns: Array<{ label: string; payload: ResetFailureLog }> = [];
  return {
    errors,
    warns,
    log: {
      error: (label: string, payload: ResetFailureLog) => void errors.push({ label, payload }),
      warn: (label: string, payload: ResetFailureLog) => void warns.push({ label, payload }),
    },
  };
}

function fakeSleep() {
  const waits: number[] = [];
  return { waits, sleep: async (ms: number) => void waits.push(ms) };
}

const outcomes: Array<{ name: string; state: unknown }> = [];

// ---------------------------------------------------------------- classifier
check("525 classifier: AuthRetryableFetchError 525", isTransientTlsFailure(TLS_525), true);
check("525 classifier: 525 with another name is not transient", isTransientTlsFailure({ name: "AuthApiError", status: 525, message: "" }), false);
check("525 classifier: 503 is not", isTransientTlsFailure(GATEWAY_503), false);
check("525 classifier: status 0 is not", isTransientTlsFailure(FETCH_0), false);
check("525 classifier: null", isTransientTlsFailure(null), false);
check("retry delay within 1500-2000ms", RESET_RETRY_DELAY_MS >= 1500 && RESET_RETRY_DELAY_MS <= 2000, true);

// ---------------------------------------------------------------- 1) success first try
{
  const s = sender([null]); const l = logger(); const z = fakeSleep();
  const state = await deliverResetRequest(s.send, l.log, { sleep: z.sleep });
  check("1: success -> 1 call", s.calls(), 1);
  check("1: success -> no sleep", z.waits.length, 0);
  check("1: success -> no logs", l.errors.length + l.warns.length, 0);
  outcomes.push({ name: "1", state });
}

// ---------------------------------------------------------------- 2) 525 then success
{
  const s = sender([TLS_525, null]); const l = logger(); const z = fakeSleep();
  const state = await deliverResetRequest(s.send, l.log, { sleep: z.sleep });
  check("2: 525 then ok -> 2 calls", s.calls(), 2);
  check("2: 525 then ok -> one sleep of default delay", z.waits.join(","), String(RESET_RETRY_DELAY_MS));
  check("2: 525 then ok -> no error log", l.errors.length, 0);
  check("2: 525 then ok -> one recovered warning", l.warns.length, 1);
  check("2: recovered label", l.warns[0]?.label, RESET_RECOVERED_LABEL);
  check("2: recovered payload attempt", l.warns[0]?.payload.attempt, 2);
  check("2: recovered payload status (the transient one)", l.warns[0]?.payload.status, 525);
  check("2: recovered payload name", l.warns[0]?.payload.name, "AuthRetryableFetchError");
  outcomes.push({ name: "2", state });
}

// ---------------------------------------------------------------- 3) 525 then 525
{
  const s = sender([TLS_525, TLS_525, null]); const l = logger(); const z = fakeSleep();
  const state = await deliverResetRequest(s.send, l.log, { sleep: z.sleep });
  check("3: 525 twice -> exactly 2 calls", s.calls(), 2);
  check("3: 525 twice -> one sleep", z.waits.length, 1);
  check("3: 525 twice -> one final error log", l.errors.length, 1);
  check("3: 525 twice -> no recovered warning", l.warns.length, 0);
  check("3: final log label", l.errors[0]?.label, RESET_FAILURE_LABEL);
  check("3: final log attempt 2", l.errors[0]?.payload.attempt, 2);
  check("3: final log status", l.errors[0]?.payload.status, 525);
  check("3: final log carries first attempt", l.errors[0]?.payload.previous?.status, 525);
  outcomes.push({ name: "3", state });
}

// ---------------------------------------------------------------- 4) 525 then 429
{
  const s = sender([TLS_525, RATE_429, null]); const l = logger(); const z = fakeSleep();
  const state = await deliverResetRequest(s.send, l.log, { sleep: z.sleep });
  check("4: 525 then 429 -> exactly 2 calls, no third", s.calls(), 2);
  check("4: 525 then 429 -> one sleep", z.waits.length, 1);
  check("4: 525 then 429 -> final error log", l.errors.length, 1);
  check("4: final log is the 429", l.errors[0]?.payload.status, 429);
  check("4: final log code", l.errors[0]?.payload.code, "over_email_send_rate_limit");
  check("4: final log previous is the 525", l.errors[0]?.payload.previous?.status, 525);
  check("4: no recovered warning", l.warns.length, 0);
  outcomes.push({ name: "4", state });
}

// ---------------------------------------------------------------- 5) 429 first
{
  const s = sender([RATE_429, null]); const l = logger(); const z = fakeSleep();
  const state = await deliverResetRequest(s.send, l.log, { sleep: z.sleep });
  check("5: 429 first -> 1 call only", s.calls(), 1);
  check("5: 429 first -> no sleep", z.waits.length, 0);
  check("5: 429 first -> one error log, attempt 1", l.errors[0]?.payload.attempt, 1);
  outcomes.push({ name: "5", state });
}

// ---------------------------------------------------------------- 6) status 0
{
  const s = sender([FETCH_0, null]); const l = logger(); const z = fakeSleep();
  const state = await deliverResetRequest(s.send, l.log, { sleep: z.sleep });
  check("6: status 0 -> 1 call only", s.calls(), 1);
  check("6: status 0 -> no sleep", z.waits.length, 0);
  check("6: status 0 -> logged", l.errors[0]?.payload.status, 0);
  outcomes.push({ name: "6", state });
}

// ---------------------------------------------------------------- 7) 500 / 503 / 401
for (const [label, err] of [["500", SERVER_500], ["503", GATEWAY_503], ["401", AUTH_401]] as const) {
  const s = sender([err, null]); const l = logger(); const z = fakeSleep();
  const state = await deliverResetRequest(s.send, l.log, { sleep: z.sleep });
  check(`7: ${label} -> 1 call only`, s.calls(), 1);
  check(`7: ${label} -> no sleep`, z.waits.length, 0);
  check(`7: ${label} -> logged once`, l.errors.length, 1);
  outcomes.push({ name: `7-${label}`, state });
}

// ---------------------------------------------------------------- 8) generic UI result identical in every case
for (const o of outcomes) {
  check(`8: outcome ${o.name} is the generic state (identity)`, o.state, GENERIC_RESET_STATE);
  check(`8: outcome ${o.name} json`, JSON.stringify(o.state), JSON.stringify({ done: true, error: null }));
}

// ---------------------------------------------------------------- 9) no sensitive data in logs
{
  // The sender closure is where the address and redirect live; the helper never sees
  // them, so nothing it logs can contain them.
  const hostile: ResetDeliveryError = { name: "AuthRetryableFetchError", status: 525, message: "" };
  const s = sender([hostile, hostile]); const l = logger(); const z = fakeSleep();
  await deliverResetRequest(s.send, l.log, { sleep: z.sleep });
  const all = JSON.stringify([...l.errors, ...l.warns]);
  for (const secret of FORBIDDEN) {
    check(`9: logs do not contain ${secret.slice(0, 12)}…`, all.includes(secret), false);
  }
  check("9: log payload keys (final)", Object.keys(l.errors[0]!.payload).sort().join(","), "attempt,code,message,name,previous,status");
  check("9: previous keys", Object.keys(l.errors[0]!.payload.previous!).sort().join(","), "code,message,name,status");
}

// ---------------------------------------------------------------- thrown errors are not swallowed
{
  let threw = false;
  try {
    await deliverResetRequest(async () => { throw new Error("boom"); }, logger().log, { sleep: async () => {} });
  } catch (e) { threw = (e as Error).message === "boom"; }
  check("thrown error propagates", threw, true);
}

// ---------------------------------------------------------------- report
if (failures.length > 0) {
  console.error(`FAIL ${failures.length} / PASS ${pass}\n\n` + failures.join("\n\n"));
  process.exit(1);
}
console.log(`PASS ${pass} FAIL 0`);
