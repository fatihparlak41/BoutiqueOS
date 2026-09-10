/**
 * Team action feedback. Wider than the catalogue's ActionState because invitation
 * delivery has a third outcome: the invite row was created and is valid, but the mail
 * could not be sent because the server has no privileged Auth key configured.
 *
 * That case is reported, never disguised as success — the colleague is waiting for an
 * email that will not arrive, and the owner has to know.
 */
export type TeamActionState = {
  error: string | null;
  ok: boolean;
  /** Set when the invite exists but delivery is not configured on this deployment. */
  configurationRequired?: boolean;
  /** The link to hand over manually while delivery is unconfigured. */
  inviteUrl?: string;
};

export const TEAM_IDLE: TeamActionState = { error: null, ok: false };
