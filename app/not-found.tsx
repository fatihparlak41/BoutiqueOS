import Link from "next/link";
import { Wordmark } from "@/components/brand";

export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center px-6">
      <Wordmark className="text-base" />
      <h1 className="mt-10 text-xl font-medium tracking-tightish">Sayfa bulunamadı</h1>
      <p className="mt-2 text-sm text-muted">Aradığınız adres taşınmış veya hiç var olmamış olabilir.</p>
      <Link
        href="/app"
        className="mt-6 w-fit text-sm underline underline-offset-4 hover:text-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
      >
        Uygulamaya dön
      </Link>
    </main>
  );
}
