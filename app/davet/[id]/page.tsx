import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { AuthShell } from "@/components/auth/auth-shell";
import { buttonVariants } from "@/components/ui/button";
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

  if (user) {
    return (
      <AuthShell
        title="Ekibe katılın"
        description={
          <>
            <span className="text-text-primary">{user.email}</span> hesabıyla oturum açtınız. Davet bu adrese
            gönderildiyse aşağıdan kabul edebilirsiniz; işletme ve rolünüz kabulden sonra görünür.
          </>
        }
      >
        <AcceptInviteForm inviteId={id} />
      </AuthShell>
    );
  }

  return (
    <AuthShell
      title="Ekibe katılın"
      description="Daveti kabul etmek için önce davetin gönderildiği e-posta adresiyle oturum açın."
      footer="Parolanızı henüz belirlemediyseniz davet e-postasındaki bağlantıyı kullanın."
    >
      <div className="mt-8">
        <Link href="/login" className={buttonVariants({ size: "lg", className: "w-full" })}>
          Oturum aç
        </Link>
      </div>
    </AuthShell>
  );
}
