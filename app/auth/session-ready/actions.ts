"use server";

import { createClient } from "@/lib/supabase/server";
import { probeOutcome, type ProbeResult } from "@/lib/auth/session-ready";

/**
 * Readiness probe for a freshly issued token. Read-only and minimal on purpose: the
 * caller's own membership rows, one of them, under RLS (pol_bm_select: manager+ or
 * user_id = auth.uid()). Nothing here retries; the page owns the schedule.
 */
export async function probeSessionReadyAction(): Promise<ProbeResult> {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return probeOutcome(false, null);

  const { error } = await supabase
    .from("business_members")
    .select("business_id")
    .eq("user_id", user.id)
    .limit(1);

  return probeOutcome(true, error);
}
