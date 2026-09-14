/**
 * Password-recovery session gate, kept free of Next and "server-only" so it runs under
 * plain Node (tests/auth/check_recovery_guard.ts).
 *
 * What a recovery session looks like in THIS project — verified against the live Auth
 * schema on 2026-09-14 and against supabase/auth `internal/api/verify.go`:
 *
 *   * GoTrue records `models.OTP` for EVERY /verify flow: invite, magic link and password
 *     recovery all yield `amr: [{ method: "otp", timestamp }]`. There is no "recovery"
 *     AMR method for email recovery (that name exists only for MFA recovery codes), so
 *     the AMR claim alone cannot tell a recovery session from a magic-link one.
 *   * `users.recovery_sent_at` is set when the recovery email goes out and is cleared by
 *     GoTrue the moment the password is updated. GET /user exposes it.
 *   * `amr[].timestamp` is the moment the OTP was verified — the session's birth — and
 *     unlike `iat` it does not move when the access token is refreshed.
 *
 * So the gate is: a validated session that (1) was established by an emailed OTP, not a
 * password, (2) while a recovery request was pending, and (3) after that request was
 * sent. A password login is refused. Once the password is set the same session stops
 * qualifying on its own, because (2) no longer holds.
 *
 * Known, accepted edge: GoTrue writes `recovery_sent_at` for magic links as well (it reuses
 * the recovery token fields), so a magic-link session passes this gate too until the
 * password is next updated. Both links land in the same mailbox and prove the same
 * thing; a password login never passes.
 *
 * Nothing here trusts query strings, client-made cookies, user_metadata or the email.
 * Inputs come from getClaims() (signature-verified) and getUser() (Auth-server-verified).
 */

export type AmrEntry = { method: string; timestamp?: number };
export type AmrClaim = ReadonlyArray<AmrEntry | string>;

export type RecoveryClaims = {
  amr?: AmrClaim;
  /** Access-token issue time, seconds since epoch. Fallback when amr carries no timestamp. */
  iat?: number;
};

export type RecoveryUser = {
  recovery_sent_at?: string | null;
};

export type RecoveryGate =
  | { allowed: true }
  | { allowed: false; reason: "unauthenticated" | "not_recovery" };

/** Finds the entry for a method in either AMR format (objects or RFC-8176 strings). */
export function findAmrMethod(amr: AmrClaim | undefined, method: string): AmrEntry | null {
  if (!Array.isArray(amr)) return null;
  for (const entry of amr) {
    if (typeof entry === "string") {
      if (entry === method) return { method };
    } else if (entry && entry.method === method) {
      return entry;
    }
  }
  return null;
}

export function recoveryGate(claims: RecoveryClaims | null, user: RecoveryUser | null): RecoveryGate {
  if (!claims || !user) return { allowed: false, reason: "unauthenticated" };

  const otp = findAmrMethod(claims.amr, "otp");
  if (!otp) return { allowed: false, reason: "not_recovery" };

  const sentAt = user.recovery_sent_at ? Date.parse(user.recovery_sent_at) : Number.NaN;
  if (!Number.isFinite(sentAt)) return { allowed: false, reason: "not_recovery" };

  const establishedSeconds = typeof otp.timestamp === "number" ? otp.timestamp : claims.iat;
  if (typeof establishedSeconds !== "number") return { allowed: false, reason: "not_recovery" };

  // The OTP cannot have been verified before its email was sent; a session older than
  // the pending request was opened some other way.
  if (establishedSeconds * 1000 < sentAt) return { allowed: false, reason: "not_recovery" };

  return { allowed: true };
}

// ------------------------------------------------------------------ set-password decision

export type SetPasswordPlan = { kind: "reject"; error: string } | { kind: "update" };

/**
 * Everything setPasswordAction decides before it touches Auth, so a direct invocation
 * of the action cannot bypass the page guard: the gate is evaluated here again, on
 * server-validated inputs, not on the fact that the form was rendered.
 */
export function planSetPassword(input: {
  password: string;
  confirm: string;
  minLength: number;
  gate: RecoveryGate;
}): SetPasswordPlan {
  if (!input.gate.allowed) {
    return {
      kind: "reject",
      error:
        input.gate.reason === "unauthenticated"
          ? "Bağlantının süresi dolmuş. Yeni bir sıfırlama bağlantısı isteyin."
          : "Parola yalnız e-postayla gelen sıfırlama bağlantısı üzerinden belirlenebilir.",
    };
  }
  if (input.password.length < input.minLength) {
    return { kind: "reject", error: `Parola en az ${input.minLength} karakter olmalı.` };
  }
  if (input.password !== input.confirm) {
    return { kind: "reject", error: "Parolalar eşleşmiyor." };
  }
  return { kind: "update" };
}
