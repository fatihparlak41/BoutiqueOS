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
  settleResetRequest,
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
  check("D: payload keys are exactly name/status/code/message",
    Object.keys(r.calls[0]!.payload).sort().join(","), "code,message,name,status");
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

// ---------------------------------------------------------------- report
if (failures.length > 0) {
  console.error(`FAIL ${failures.length} / PASS ${pass}\n\n` + failures.join("\n\n"));
  process.exit(1);
}
console.log(`PASS ${pass} FAIL 0`);
