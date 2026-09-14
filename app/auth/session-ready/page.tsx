import { AuthShell, BackToLogin } from "@/components/auth/auth-shell";
import { safeSessionReadyNext } from "@/lib/auth/session-ready";
import { SessionReadyClient } from "./session-ready-client";

export const metadata = { title: "Oturum hazırlanıyor · BoutiqueOS" };

/**
 * Waiting room for a freshly issued token.
 *
 * Renders nothing that needs PostgREST: no tenant, no membership, no profile. A token
 * Auth has just issued can be rejected by PostgREST for a moment (PGRST303 "JWT issued
 * at future"); the client component below polls a read-only probe on a bounded
 * schedule and continues to `next` — an exact-match allowlist, so the parameter can
 * never send anyone off-site or into an arbitrary path.
 */
export default async function SessionReadyPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string }>;
}) {
  const { next } = await searchParams;
  const destination = safeSessionReadyNext(next);

  return (
    <AuthShell
      title="Bir saniye"
      description="Oturumunuz doğrulanıyor; hazır olunca otomatik olarak devam edeceksiniz."
      footer={<BackToLogin />}
    >
      <SessionReadyClient next={destination} />
    </AuthShell>
  );
}
