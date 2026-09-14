"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { AuthStatus } from "@/components/auth/auth-status";
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
      <div className="mt-8" role="status" aria-live="polite">
        <p className="text-sm text-text-secondary">Oturumunuz hazırlanıyor…</p>
        <div className="mt-4 space-y-2" aria-hidden>
          <Skeleton className="h-3 w-4/5" />
          <Skeleton className="h-3 w-3/5" />
          <Skeleton className="h-3 w-2/3" />
        </div>
      </div>
    );
  }

  return (
    <AuthStatus
      live
      tone={phase.kind === "delayed" ? "warning" : "danger"}
      className="mt-8"
      title={phase.kind === "delayed" ? "Oturumunuz hazırlanırken gecikme oluştu" : "Oturum doğrulanamadı"}
      description={
        phase.kind === "delayed"
          ? "Bağlantı bir an için hazır değildi. Tekrar deneyebilirsiniz; genellikle ikinci denemede açılır."
          : "Tekrar deneyebilir ya da yeniden giriş yapabilirsiniz."
      }
      action={
        <Button type="button" size="lg" className="w-full" onClick={retry}>
          Tekrar dene
        </Button>
      }
    />
  );
}
