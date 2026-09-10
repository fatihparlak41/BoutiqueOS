"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { reportDbError } from "@/lib/db-errors";
import type { TeamActionState } from "@/lib/team/action-state";

/**
 * Accepting an invitation.
 *
 * The only thing this passes to the database is the invitation id from the URL. Which
 * tenant, which role, which branch and which discount ceiling all come out of the
 * invitation row; the acting identity comes from auth.uid() and the address from
 * auth.users. Knowing an id is not enough — rpc_accept_invite requires the caller's
 * CONFIRMED address to equal the invited one.
 */
export async function acceptInviteAction(
  _prev: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const inviteId = String(formData.get("invite_id") ?? "").trim();
  if (!/^[0-9a-fA-F-]{36}$/.test(inviteId)) {
    return { error: "Davet bulunamadı.", ok: false };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_accept_invite", { p_invite_id: inviteId });

  if (error) return { error: reportDbError("acceptInvite", error), ok: false };

  revalidatePath("/", "layout");
  return { error: null, ok: true };
}
