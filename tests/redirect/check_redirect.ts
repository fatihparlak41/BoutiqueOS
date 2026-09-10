/**
 * Open-redirect tests for the auth email round trip.
 *
 * Runs under plain Node with type stripping — no test framework, no new dependency:
 *
 *   node --experimental-strip-types tests/redirect/check_redirect.ts
 *
 * lib/redirect.ts is deliberately free of "server-only" and of Next imports so it can
 * be exercised here directly. Import is relative because the "@/" alias is a bundler
 * feature that plain Node does not resolve.
 */

import { safeNextPath, safeRedirectPath } from "../../lib/redirect.ts";

const PROD = "https://butikos.parlakmediatech.com.tr";
const LOCAL = "http://localhost:3000";

let pass = 0;
const failures: string[] = [];

function check(name: string, actual: unknown, expected: unknown): void {
  if (Object.is(actual, expected)) {
    pass += 1;
    return;
  }
  failures.push(`${name}\n    beklenen: ${String(expected)}\n    gelen:    ${String(actual)}`);
}

// ---------------------------------------------------------------- destinations
check(
  "R01 new-user invite destination survives the round trip",
  safeRedirectPath(`${PROD}/davet/6f1d2c34-5a6b-4c7d-8e9f-0a1b2c3d4e5f`, PROD),
  "/davet/6f1d2c34-5a6b-4c7d-8e9f-0a1b2c3d4e5f",
);
check(
  "R02 existing-user magic link lands on the same invitation",
  safeRedirectPath(`${PROD}/davet/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee`, PROD),
  "/davet/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
);
check("R03 recovery destination", safeRedirectPath(`${PROD}/sifre-belirle`, PROD), "/sifre-belirle");
check("R04 localhost invite destination", safeRedirectPath(`${LOCAL}/davet/x-y-z`, LOCAL), "/davet/x-y-z");
check(
  "R05 the invitation id is not lost when a query string rides along",
  safeRedirectPath(`${PROD}/davet/1234?kaynak=mail`, PROD),
  "/davet/1234?kaynak=mail",
);
check("R06 a relative destination is accepted", safeRedirectPath("/davet/1234", PROD), "/davet/1234");

// ---------------------------------------------------------------- open redirect
check("R07 absolute foreign origin is refused", safeRedirectPath("https://evil.example", PROD), "/app");
check(
  "R08 foreign origin with a plausible path is refused",
  safeRedirectPath("https://evil.example/davet/1234", PROD),
  "/app",
);
check("R09 protocol-relative is refused", safeRedirectPath("//evil.example", PROD), "/app");
check(
  "R10 protocol-relative with a path is refused",
  safeRedirectPath("//evil.example/davet/1234", PROD),
  "/app",
);
check("R11 javascript: is refused", safeRedirectPath("javascript:alert(1)", PROD), "/app");
check("R12 data: is refused", safeRedirectPath("data:text/html,<script>1</script>", PROD), "/app");
check(
  "R13 userinfo trick is refused (host is evil.example, not ours)",
  safeRedirectPath(`https://butikos.parlakmediatech.com.tr@evil.example/davet/1`, PROD),
  "/app",
);
check(
  "R14 a different scheme on the same host is refused",
  safeRedirectPath("http://butikos.parlakmediatech.com.tr/davet/1", PROD),
  "/app",
);
check(
  "R15 a different port is refused",
  safeRedirectPath("http://localhost:4000/davet/1", LOCAL),
  "/app",
);
check("R16 backslash folding is refused", safeRedirectPath("/\\evil.example", PROD), "/app");
check("R17 an unlisted same-origin path falls back", safeRedirectPath(`${PROD}/yonetim`, PROD), "/app");
check("R18 empty falls back", safeRedirectPath("", PROD), "/app");
check("R19 null falls back", safeRedirectPath(null, PROD), "/app");
check("R20 garbage falls back", safeRedirectPath("http://[", PROD), "/app");

// ---------------------------------------------------------------- safeNextPath
check("R21 next accepts a relative path", safeNextPath("/app/ayarlar/ekip"), "/app/ayarlar/ekip");
check("R22 next refuses an absolute URL", safeNextPath("https://evil.example"), "/app");
check("R23 next refuses protocol-relative", safeNextPath("//evil.example"), "/app");
check("R24 next refuses a scheme", safeNextPath("/javascript:alert(1)"), "/app");
check("R25 next refuses a newline", safeNextPath("/app\nSet-Cookie: x=1"), "/app");

// ---------------------------------------------------------------- report
for (const failure of failures) console.error(`  [FAIL] ${failure}`);
console.log(`redirect: ${pass} passed, ${failures.length} failed`);
if (failures.length > 0) process.exit(1);
