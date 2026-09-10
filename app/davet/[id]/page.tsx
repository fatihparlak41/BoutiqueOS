import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Wordmark } from "@/components/brand";
import { AcceptInviteForm } from "./accept-invite-form";

export const metadata = { title: "Davet · BoutiqueOS" };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Invitation acceptance.
 *
 * Nothing about the invitation is shown before it is claimed: not the tenant, not the
 * role, not the invited address. The id in the URL is an identifier, not a secret, so
 * this page must not turn it into a lookup oracle. Everything is decided by
 * rpc_accept_invite, which matches the caller's confirmed address against the row.
 *
 * The page carries no third-party script, font or image — an invitation URL should
 * never reach anyone else through a referrer.
 */
export default async function AcceptInvitePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  return (
    <main className="flex min-h-dvh flex-col justify-center px-6 py-16 sm:px-12">
      <div className="w-full max-w-sm sm:mx-auto">
        <Wordmark className="mb-10 block text-lg" />
        <h1 className="text-xl font-medium tracking-tightish">Ekibe katılın</h1>

        {user ? (
          <>
            <p className="mt-2 text-sm leading-relaxed text-muted">
              <span className="text-ink">{user.email}</span> hesabıyla giriş yaptınız. Davet bu adrese
              gönderildiyse aşağıdan kabul edebilirsiniz.
            </p>
            <AcceptInviteForm inviteId={id} />
          </>
        ) : (
          <>
            <p className="mt-2 text-sm leading-relaxed text-muted">
              Daveti kabul etmek için önce davetin gönderildiği e-posta adresiyle oturum açın.
            </p>
            <Link
              href="/login"
              className="mt-8 inline-flex min-h-11 w-full items-center justify-center rounded border border-line-strong bg-ink px-5 text-sm text-paper transition-colors hover:bg-ink/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
            >
              Oturum aç
            </Link>
            <p className="mt-4 text-xs leading-relaxed text-muted">
              Parolanızı henüz belirlemediyseniz davet e-postasındaki bağlantıyı kullanın.
            </p>
          </>
        )}
      </div>
    </main>
  );
}
