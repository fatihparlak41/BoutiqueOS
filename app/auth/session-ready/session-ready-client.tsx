"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { runReadiness, type ReadinessOutcome, type SessionReadyNext } from "@/lib/auth/session-ready";
import { probeSessionReadyAction } from "./actions";

type Phase = { kind: "waiting" } | { kind: "delayed" } | { kind: "failed" };

/**
 * Polls the read-only readiness probe on the bounded schedule and moves on as soon as
 * the token is accepted. Every terminal state is either a navigation or a screen with
 * a manual retry — the loop never runs past the schedule on its own.
 */
export function SessionReadyClient({ next }: { next: SessionReadyNext }) {
  const router = useRouter();
  const [phase, setPhase] = useState<Phase>({ kind: "waiting" });
  const [round, setRound] = useState(0);
  const cancelled = useRef(false);

  useEffect(() => {
    cancelled.current = false;
    let active = true;

    (async () => {
      const result: ReadinessOutcome = await runReadiness(probeSessionReadyAction, {
        isCancelled: () => cancelled.current,
      });
      if (!active) return;

      switch (result.outcome) {
        case "ready":
          router.replace(next);
          return;
        case "unauthenticated":
          router.replace("/login");
          return;
        case "exhausted":
          setPhase({ kind: "delayed" });
          return;
        case "error":
          setPhase({ kind: "failed" });
          return;
      }
    })();

    return () => {
      active = false;
      cancelled.current = true;
    };
    // `round` restarts the schedule on a manual retry.
  }, [next, round, router]);

  const retry = useCallback(() => {
    setPhase({ kind: "waiting" });
    setRound((r) => r + 1);
  }, []);

  if (phase.kind === "waiting") {
    return (
      <p role="status" aria-live="polite" className="mt-6 text-sm text-muted">
        Oturum hazırlanıyor…
      </p>
    );
  }

  return (
    <div className="mt-6 space-y-4">
      <p role="status" aria-live="polite" className="text-sm leading-relaxed text-ink-70">
        {phase.kind === "delayed"
          ? "Oturumunuz hazırlanırken gecikme oluştu. Tekrar deneyebilirsiniz."
          : "Oturum doğrulanamadı. Tekrar deneyebilir ya da yeniden giriş yapabilirsiniz."}
      </p>
      <Button type="button" size="lg" className="w-full" onClick={retry}>
        Tekrar dene
      </Button>
    </div>
  );
}
