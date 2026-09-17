"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";
import { reportDbError } from "@/lib/db-errors";
import { reportCaps, TIMEZONE_OPTIONS } from "@/lib/reports/model";

export type TimezoneActionState = { error: string | null; ok: boolean };
export const TIMEZONE_IDLE: TimezoneActionState = { error: null, ok: false };

/**
 * Sets settings.timezone through rpc_business_set_timezone. The RPC proves owner/manager
 * rank and validates the zone against pg_timezone_names; the tenant is the one the shell
 * resolved server-side. The choice is bounded to the curated list on top of that.
 */
export async function setTimezoneAction(_prev: TimezoneActionState, formData: FormData): Promise<TimezoneActionState> {
  const { active } = await requireTenant();
  if (!reportCaps(active.role).canConfigure) return { error: "Bu ayarı yalnız sahip ve yöneticiler değiştirebilir.", ok: false };
  const timezone = String(formData.get("timezone") ?? "").trim();
  if (!TIMEZONE_OPTIONS.some((o) => o.value === timezone)) return { error: "Listeden bir saat dilimi seçin.", ok: false };
  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_business_set_timezone", { p_business_id: active.business_id, p_timezone: timezone });
  if (error) return { error: reportDbError("set timezone", error), ok: false };
  revalidatePath("/app", "layout");
  return { error: null, ok: true };
}
