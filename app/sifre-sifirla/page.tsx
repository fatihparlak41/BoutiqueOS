import Link from "next/link";
import { Wordmark } from "@/components/brand";
import { ResetRequestForm } from "./reset-request-form";

export const metadata = { title: "Şifre sıfırlama · BoutiqueOS" };

const NOTICE: Record<string, string> = {
  gecersiz: "Bağlantı geçersiz veya süresi dolmuş. Aşağıdan yeni bir bağlantı isteyin.",
};

export default async function ResetRequestPage({
  searchParams,
}: {
  searchParams: Promise<{ durum?: string }>;
}) {
  const { durum } = await searchParams;
  const notice = durum ? NOTICE[durum] : undefined;

  return (
    <main className="flex min-h-dvh flex-col justify-center px-6 py-16 sm:px-12">
      <div className="w-full max-w-sm sm:mx-auto">
        <Wordmark className="mb-10 block text-lg" />

        <h1 className="text-xl font-medium tracking-tightish">Parolanızı sıfırlayın</h1>
        <p className="mt-2 text-sm leading-relaxed text-muted">
          Hesabınızın e-posta adresini yazın. Kayıtlıysa sıfırlama bağlantısı gönderilir.
        </p>

        {notice ? (
          <p
            role="status"
            className="mt-5 border-l-2 border-line-strong bg-panel px-3 py-2 text-xs leading-relaxed text-ink-70"
          >
            {notice}
          </p>
        ) : null}

        <ResetRequestForm />

        <p className="mt-8 text-xs text-muted">
          <Link href="/login" className="underline-offset-2 hover:underline">
            ← Girişe dön
          </Link>
        </p>
      </div>
    </main>
  );
}
