import Link from "next/link";
import { Wordmark } from "@/components/brand";
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
    <main className="flex min-h-dvh flex-col justify-center px-6 py-16 sm:px-12">
      <div className="w-full max-w-sm sm:mx-auto">
        <Wordmark className="mb-10 block text-lg" />

        <h1 className="text-xl font-medium tracking-tightish">Bir saniye</h1>
        <p className="mt-2 text-sm leading-relaxed text-muted">
          Oturumunuz doğrulanıyor; hazır olunca otomatik olarak devam edeceksiniz.
        </p>

        <SessionReadyClient next={destination} />

        <p className="mt-8 text-xs text-muted">
          <Link href="/login" className="underline-offset-2 hover:underline">
            ← Girişe dön
          </Link>
        </p>
      </div>
    </main>
  );
}
