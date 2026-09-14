/**
 * Regression tests for session readiness after a freshly issued JWT.
 *
 * Runs under plain Node with type stripping — no test framework, no new dependency:
 *
 *   node --experimental-strip-types tests/auth/check_session_ready.ts
 *
 * lib/auth/session-ready.ts is deliberately free of "server-only" and of Next imports
 * so it can be exercised here directly. Import is relative because the "@/" alias is a
 * bundler feature that plain Node does not resolve.
 */

import {
  AFTER_PASSWORD_UPDATE_PATH,
  READINESS_SCHEDULE_MS,
  SESSION_READY_PATH,
  isFreshJwtRejection,
  probeOutcome,
  runReadiness,
  safeSessionReadyNext,
  sessionReadyPath,
  tenantReadOutcome,
  type ProbeResult,
} from "../../lib/auth/session-ready.ts";

let pass = 0;
const failures: string[] = [];

function check(name: string, actual: unknown, expected: unknown): void {
  if (Object.is(actual, expected)) {
    pass += 1;
    return;
  }
  failures.push(`${name}\n    beklenen: ${String(expected)}\n    gelen:    ${String(actual)}`);
}

const PGRST303 = { message: "JWT issued at future", code: "PGRST303" };
const PGRST303_CODE_ONLY = { message: "JWT claims validation failed", code: "PGRST303" };
const MESSAGE_ONLY = { message: "JWT issued at future", code: null };
const EXPIRED = { message: "JWT expired", code: "PGRST301" };
const BAD_KEY = { message: "Invalid API key", code: null };
const PERMISSION = { message: "permission denied for table business_members", code: "42501" };
const MISSING = { message: 'relation "public.nope" does not exist', code: "42P01" };

const SESSION_READY_APP = `${SESSION_READY_PATH}?next=%2Fapp`;

// ---------------------------------------------------------------- classifier
check("classifier: code + message", isFreshJwtRejection(PGRST303), true);
check("classifier: PGRST303 code alone", isFreshJwtRejection(PGRST303_CODE_ONLY), true);
check("classifier: message alone", isFreshJwtRejection(MESSAGE_ONLY), true);
check("classifier: expired (PGRST301) is not", isFreshJwtRejection(EXPIRED), false);
check("classifier: bad key is not", isFreshJwtRejection(BAD_KEY), false);
check("classifier: permission is not", isFreshJwtRejection(PERMISSION), false);
check("classifier: null", isFreshJwtRejection(null), false);

// ---------------------------------------------------------------- A) tenant bootstrap normal success
{
  const o = tenantReadOutcome("Üyelikler okunamadı", null);
  check("A: no error -> proceed", o.kind, "proceed");
}

// ---------------------------------------------------------------- B) exact PGRST303 -> session-ready redirect
{
  const o = tenantReadOutcome("Üyelikler okunamadı", PGRST303);
  check("B: PGRST303 -> redirect", o.kind, "redirect");
  check("B: redirect target", o.kind === "redirect" ? o.to : "", SESSION_READY_APP);
  const o2 = tenantReadOutcome("İşletmeler okunamadı", MESSAGE_ONLY, "/select-business");
  check("B: message-only -> redirect with select-business next", o2.kind === "redirect" ? o2.to : "", `${SESSION_READY_PATH}?next=%2Fselect-business`);
}

// ---------------------------------------------------------------- C) unrelated 401-style -> no session-ready redirect
{
  for (const [label, err] of [["expired", EXPIRED], ["bad key", BAD_KEY]] as const) {
    const o = tenantReadOutcome("Üyelikler okunamadı", err);
    check(`C: ${label} -> throw`, o.kind, "throw");
    check(`C: ${label} -> message kept`, o.kind === "throw" ? o.message : "", `Üyelikler okunamadı: ${err.message}`);
  }
}

// ---------------------------------------------------------------- D) unrelated DB error -> no session-ready redirect
{
  for (const [label, err] of [["permission", PERMISSION], ["missing relation", MISSING]] as const) {
    const o = tenantReadOutcome("Şubeler okunamadı", err);
    check(`D: ${label} -> throw`, o.kind, "throw");
    check(`D: ${label} -> not a redirect`, o.kind === "redirect", false);
  }
}

// ---------------------------------------------------------------- probe outcome
check("probe: no user -> unauthenticated", probeOutcome(false, null).status, "unauthenticated");
check("probe: no user even with error -> unauthenticated", probeOutcome(false, PGRST303).status, "unauthenticated");
check("probe: user, no error -> ready", probeOutcome(true, null).status, "ready");
check("probe: user, PGRST303 -> not_ready", probeOutcome(true, PGRST303).status, "not_ready");
check("probe: user, permission -> error", probeOutcome(true, PERMISSION).status, "error");
check("probe: user, expired -> error (not retried)", probeOutcome(true, EXPIRED).status, "error");

// ---------------------------------------------------------------- helpers for E–G
function scriptedProbe(results: ProbeResult[]) {
  let calls = 0;
  const probe = async (): Promise<ProbeResult> => {
    const r = results[Math.min(calls, results.length - 1)]!;
    calls += 1;
    return r;
  };
  return { probe, calls: () => calls };
}
function fakeSleep() {
  const waits: number[] = [];
  return { waits, sleep: async (ms: number) => void waits.push(ms) };
}
const NOT_READY: ProbeResult = { status: "not_ready" };
const READY: ProbeResult = { status: "ready" };

check("schedule: five attempts", READINESS_SCHEDULE_MS.length, 5);
check("schedule: 0,1,2,4,8 s", READINESS_SCHEDULE_MS.join(","), "0,1000,2000,4000,8000");
check("schedule: ~15 s total", READINESS_SCHEDULE_MS.reduce((a, b) => a + b, 0), 15000);

// ---------------------------------------------------------------- E) PGRST303 -> PGRST303 -> success
{
  const p = scriptedProbe([NOT_READY, NOT_READY, READY]);
  const z = fakeSleep();
  const r = await runReadiness(p.probe, { sleep: z.sleep });
  check("E: outcome ready", r.outcome, "ready");
  check("E: three attempts", r.attempts, 3);
  check("E: probe called three times", p.calls(), 3);
  check("E: slept 1 s then 2 s", z.waits.join(","), "1000,2000");
}

// ---------------------------------------------------------------- F) PGRST303 across the full window
{
  const p = scriptedProbe([NOT_READY]);
  const z = fakeSleep();
  const r = await runReadiness(p.probe, { sleep: z.sleep });
  check("F: outcome exhausted (graceful, no throw)", r.outcome, "exhausted");
  check("F: exactly five attempts", r.attempts, 5);
  check("F: probe not called a sixth time", p.calls(), 5);
  check("F: waited the full schedule", z.waits.join(","), "1000,2000,4000,8000");
}

// ---------------------------------------------------------------- G) unrelated error during probe
{
  const p = scriptedProbe([NOT_READY, { status: "error", message: "permission denied" }, READY]);
  const z = fakeSleep();
  const r = await runReadiness(p.probe, { sleep: z.sleep });
  check("G: outcome error", r.outcome, "error");
  check("G: stops at the error (two attempts)", r.attempts, 2);
  check("G: no further probes", p.calls(), 2);
  check("G: message kept", r.outcome === "error" ? r.message : "", "permission denied");
}
{
  const p = scriptedProbe([{ status: "unauthenticated" }]);
  const r = await runReadiness(p.probe, { sleep: async () => {} });
  check("G: unauthenticated stops immediately", r.outcome, "unauthenticated");
  check("G: unauthenticated -> one attempt", r.attempts, 1);
}
{
  // Cancellation (component unmounted) ends the loop without another probe.
  const p = scriptedProbe([NOT_READY]);
  let cancelled = false;
  const r = await runReadiness(p.probe, {
    sleep: async () => {
      cancelled = true;
    },
    isCancelled: () => cancelled,
  });
  check("G: cancelled -> exhausted without further probes", r.outcome, "exhausted");
  check("G: cancelled -> one attempt", r.attempts, 1);
}

// ---------------------------------------------------------------- H) unsafe next rejected
{
  const unsafe = [
    "https://evil.test/app",
    "//evil.test",
    "/app/../admin",
    "/app/urunler",
    "/select-business?x=1",
    "javascript:alert(1)",
    "\\app",
    "/login",
    "",
    "   ",
    undefined,
    null,
  ];
  for (const v of unsafe) {
    check(`H: ${JSON.stringify(v)} -> /app`, safeSessionReadyNext(v as string), "/app");
  }
  check("H: /app accepted", safeSessionReadyNext("/app"), "/app");
  check("H: /select-business accepted", safeSessionReadyNext("/select-business"), "/select-business");
  check("H: surrounding whitespace tolerated", safeSessionReadyNext("  /select-business "), "/select-business");
  check("H: path builder encodes next", sessionReadyPath("/select-business"), `${SESSION_READY_PATH}?next=%2Fselect-business`);
}

// ---------------------------------------------------------------- I) password update -> session-ready, not /app
check("I: after-password path is session-ready", AFTER_PASSWORD_UPDATE_PATH, SESSION_READY_APP);
check("I: after-password path is not a tenant route", AFTER_PASSWORD_UPDATE_PATH.startsWith("/app"), false);

// ---------------------------------------------------------------- report
if (failures.length > 0) {
  console.error(`FAIL ${failures.length} / PASS ${pass}\n\n` + failures.join("\n\n"));
  process.exit(1);
}
console.log(`PASS ${pass} FAIL 0`);
