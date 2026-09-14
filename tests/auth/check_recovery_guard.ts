/**
 * Regression tests for the password-recovery session gate and the set-password plan.
 *
 * Runs under plain Node with type stripping — no test framework, no new dependency:
 *
 *   node --experimental-strip-types tests/auth/check_recovery_guard.ts
 *
 * lib/auth/recovery-session.ts is deliberately free of "server-only" and of Next
 * imports so it can be exercised here directly. Import is relative because the "@/"
 * alias is a bundler feature that plain Node does not resolve.
 *
 * Fixture facts mirror the live project on 2026-09-14 (auth.mfa_amr_claims and
 * supabase/auth verify.go): every emailed link — invite, magic link, recovery — yields
 * amr method "otp"; a password login yields "password". Recovery is therefore the
 * combination "otp session established after a still-pending recovery request".
 */

import {
  findAmrMethod,
  planSetPassword,
  recoveryGate,
  type RecoveryClaims,
  type RecoveryUser,
} from "../../lib/auth/recovery-session.ts";

let pass = 0;
const failures: string[] = [];

function check(name: string, actual: unknown, expected: unknown): void {
  if (Object.is(actual, expected)) {
    pass += 1;
    return;
  }
  failures.push(`${name}\n    beklenen: ${String(expected)}\n    gelen:    ${String(actual)}`);
}

// Live timeline: recovery email 09:27:03Z, OTP verified (session born) 09:27:21Z.
const SENT_AT = "2026-09-14T09:27:03.684Z";
const OTP_AT = Math.floor(Date.parse("2026-09-14T09:27:21.778Z") / 1000);
const EARLIER_OTP_AT = Math.floor(Date.parse("2026-09-14T08:50:21.303Z") / 1000); // Case B magic link, before the request

const pending: RecoveryUser = { recovery_sent_at: SENT_AT };
const cleared: RecoveryUser = { recovery_sent_at: null }; // GoTrue clears it once the password is set

const recovery: RecoveryClaims = { amr: [{ method: "otp", timestamp: OTP_AT }], iat: OTP_AT + 5 };
const passwordLogin: RecoveryClaims = { amr: [{ method: "password", timestamp: OTP_AT }], iat: OTP_AT + 5 };
const magicLinkBefore: RecoveryClaims = { amr: [{ method: "otp", timestamp: EARLIER_OTP_AT }], iat: OTP_AT + 5 };
const noAmr: RecoveryClaims = { iat: OTP_AT + 5 };
const emptyAmr: RecoveryClaims = { amr: [], iat: OTP_AT + 5 };

// ---------------------------------------------------------------- findAmrMethod
check("amr: object form found", findAmrMethod([{ method: "otp", timestamp: 1 }], "otp")?.timestamp, 1);
check("amr: string form found", findAmrMethod(["otp"], "otp")?.method, "otp");
check("amr: absent", findAmrMethod([{ method: "password", timestamp: 1 }], "otp"), null);
check("amr: undefined claim", findAmrMethod(undefined, "otp"), null);

// ---------------------------------------------------------------- 1) recovery -> allowed
check("1: recovery session with pending request -> allowed", recoveryGate(recovery, pending).allowed, true);

// ---------------------------------------------------------------- 2) password -> denied
{
  const g = recoveryGate(passwordLogin, pending);
  check("2: password login -> denied", g.allowed, false);
  check("2: password login -> reason", g.allowed ? "" : g.reason, "not_recovery");
}

// ---------------------------------------------------------------- 3) magic link -> denied
// GoTrue records "otp" for magic links too. Without a pending recovery request the
// session is refused; with a request sent AFTER the session was born it is refused
// as well (the OTP could not have come from that email).
{
  const g1 = recoveryGate({ amr: [{ method: "otp", timestamp: OTP_AT }], iat: OTP_AT }, cleared);
  check("3: magic link, no pending request -> denied", g1.allowed, false);
  const g2 = recoveryGate(magicLinkBefore, pending);
  check("3: magic link opened before the request -> denied", g2.allowed, false);
  check("3: reason", g2.allowed ? "" : g2.reason, "not_recovery");
}

// ---------------------------------------------------------------- 4) invite -> denied
// Same AMR shape as a magic link; an invite session never has a pending recovery.
check("4: invite session -> denied", recoveryGate({ amr: [{ method: "otp", timestamp: OTP_AT }], iat: OTP_AT }, cleared).allowed, false);

// ---------------------------------------------------------------- 5) missing AMR -> denied
check("5: no amr claim -> denied", recoveryGate(noAmr, pending).allowed, false);
check("5: empty amr claim -> denied", recoveryGate(emptyAmr, pending).allowed, false);

// ---------------------------------------------------------------- 6) unauthenticated -> denied
{
  const g = recoveryGate(null, null);
  check("6: no claims -> denied", g.allowed, false);
  check("6: reason", g.allowed ? "" : g.reason, "unauthenticated");
  check("6: claims without user -> denied", recoveryGate(recovery, null).allowed, false);
  check("6: user without claims -> denied", recoveryGate(null, pending).allowed, false);
}

// ---------------------------------------------------------------- after password update
check("after update: same session, request cleared -> denied", recoveryGate(recovery, cleared).allowed, false);

// ---------------------------------------------------------------- string-format AMR falls back to iat
check("string amr: iat after request -> allowed", recoveryGate({ amr: ["otp"], iat: OTP_AT }, pending).allowed, true);
check("string amr: iat before request -> denied", recoveryGate({ amr: ["otp"], iat: EARLIER_OTP_AT }, pending).allowed, false);
check("string amr: no iat -> denied", recoveryGate({ amr: ["otp"] }, pending).allowed, false);

// ---------------------------------------------------------------- what the gate must not consult
{
  // Extra fields that a client can influence are ignored entirely.
  const claims = { ...passwordLogin, user_metadata: { recovery: true }, email: "x@example.com" } as RecoveryClaims;
  check("ignores user_metadata / email", recoveryGate(claims, pending).allowed, false);
}

// ---------------------------------------------------------------- 7) direct action without recovery -> denied, no update
{
  const plan = planSetPassword({
    password: "correct-horse-battery",
    confirm: "correct-horse-battery",
    minLength: 10,
    gate: recoveryGate(passwordLogin, pending),
  });
  check("7: password session -> reject", plan.kind, "reject");
  check("7: message names the recovery link", plan.kind === "reject" ? plan.error.includes("sıfırlama bağlantısı") : false, true);
}
{
  const plan = planSetPassword({
    password: "correct-horse-battery",
    confirm: "correct-horse-battery",
    minLength: 10,
    gate: recoveryGate(null, null),
  });
  check("7: unauthenticated -> reject", plan.kind, "reject");
  check("7: unauthenticated -> expired-link message", plan.kind === "reject" ? plan.error.includes("süresi dolmuş") : false, true);
}

// ---------------------------------------------------------------- 8) valid recovery session -> update
{
  const gate = recoveryGate(recovery, pending);
  const ok = planSetPassword({ password: "correct-horse-battery", confirm: "correct-horse-battery", minLength: 10, gate });
  check("8: recovery session -> update", ok.kind, "update");
  const short = planSetPassword({ password: "short", confirm: "short", minLength: 10, gate });
  check("8: too short -> reject", short.kind, "reject");
  const mismatch = planSetPassword({ password: "correct-horse-battery", confirm: "correct-horse-batterx", minLength: 10, gate });
  check("8: mismatch -> reject", mismatch.kind, "reject");
  // The gate is checked before the password rules: a denied session never learns
  // whether its password would have been acceptable.
  const deniedShort = planSetPassword({ password: "short", confirm: "short", minLength: 10, gate: recoveryGate(passwordLogin, pending) });
  check("8: gate evaluated before password rules", deniedShort.kind === "reject" ? deniedShort.error.includes("sıfırlama bağlantısı") : false, true);
}

// ---------------------------------------------------------------- report
if (failures.length > 0) {
  console.error(`FAIL ${failures.length} / PASS ${pass}\n\n` + failures.join("\n\n"));
  process.exit(1);
}
console.log(`PASS ${pass} FAIL 0`);
