/**
 * Shared shape for every catalogue server action.
 *
 * It lives outside app/app/urunler/actions.ts on purpose: a "use server" module may only
 * export async functions, so the constant and the type cannot be declared there.
 */
export type ActionState = { error: string | null; ok: boolean };

export const IDLE: ActionState = { error: null, ok: false };
