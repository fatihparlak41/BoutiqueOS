import "server-only";

import { createClient } from "@/lib/supabase/server";
import { recoveryGate, type RecoveryGate } from "@/lib/auth/recovery-session";

/**
 * Evaluates the recovery gate for the current request from two server-validated
 * sources: getClaims() verifies the token's signature and yields `amr` / `iat`;
 * getUser() asks the Auth server and yields `recovery_sent_at`. Neither comes from
 * anything the browser can forge. The email rides along for display only — it plays
 * no part in the decision.
 */
export async function loadRecoveryGate(): Promise<{ gate: RecoveryGate; email: string | null }> {
  const supabase = await createClient();

  const [{ data: claimsData }, { data: userData }] = await Promise.all([
    supabase.auth.getClaims(),
    supabase.auth.getUser(),
  ]);

  const claims = claimsData?.claims ?? null;
  const user = userData?.user ?? null;

  const gate = recoveryGate(
    claims ? { amr: claims.amr, iat: claims.iat } : null,
    user ? { recovery_sent_at: user.recovery_sent_at ?? null } : null,
  );

  return { gate, email: user?.email ?? null };
}
