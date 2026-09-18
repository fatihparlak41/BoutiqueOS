import * as React from "react";
import Link from "next/link";
import { Wordmark } from "@/components/brand";
import { cn } from "@/lib/utils";

/**
 * The one layout every unauthenticated and auth-transition screen uses.
 *
 * Desktop: a slightly asymmetric two-column composition — an editorial panel on the
 * left (wordmark, the product's one-line identity, a short statement set in the serif)
 * and the operational form on the right, vertically centred, no card floating in space.
 * Below lg it collapses to a single column: wordmark, then the form first.
 *
 * Nothing here decides anything; pages keep their own server logic.
 */
export function AuthShell({
  title,
  description,
  children,
  footer,
  wide = false,
}: {
  title: React.ReactNode;
  description?: React.ReactNode;
  children: React.ReactNode;
  /** Quiet line under the form — a link back, a note. */
  footer?: React.ReactNode;
  /** A little more room for a status page with a wider paragraph. */
  wide?: boolean;
}) {
  return (
    <main className="min-h-dvh bg-background lg:grid lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]">
      <section className="hidden border-r border-border bg-surface-muted/50 lg:flex lg:flex-col lg:justify-between lg:px-12 lg:py-12">
        <div>
          <Wordmark className="text-2xl" />
          <p className="mt-1 text-xs text-text-muted">fashion retail operations</p>
        </div>

        <div className="max-w-[24rem]">
          <p className="font-serif text-4xl font-medium leading-[1.08] tracking-tightish text-text-primary">
            Mağazanın günlük işleyişi, tek kayıt üzerinde.
          </p>
          <ul className="mt-8 divide-y divide-border border-y border-border text-sm text-text-secondary">
            <li className="py-3">Mal kabul stoğu yazar; elle stok girişi yoktur.</li>
            <li className="py-3">Sayım ile defter arasındaki fark burada kapanır.</li>
            <li className="py-3">Kim neyi görür, işletme sahibi belirler.</li>
          </ul>
        </div>

        <p className="text-xs text-text-muted">Ekip hesapları davetle açılır; işletmeler başvuruyla katılır.</p>
      </section>

      <section className="flex min-h-dvh flex-col px-6 py-10 sm:px-12 lg:min-h-0 lg:justify-center lg:px-20 lg:py-16">
        <div className="mb-12 lg:hidden">
          <Wordmark className="text-xl" />
          <p className="mt-0.5 text-2xs text-text-muted">fashion retail operations</p>
        </div>

        <div className={cn("w-full", wide ? "max-w-md" : "max-w-sm")}>
          <h1 className="font-serif text-3xl font-medium leading-tight tracking-tightish text-text-primary">
            {title}
          </h1>
          {description ? (
            <p className="mt-3 text-sm leading-relaxed text-text-muted">{description}</p>
          ) : null}

          {children}

          {footer ? <div className="mt-10 text-xs text-text-muted">{footer}</div> : null}
        </div>
      </section>
    </main>
  );
}

/** The quiet "back to sign-in" line most auth pages end with. */
export function BackToLogin({ label = "Girişe dön" }: { label?: string }) {
  return (
    <Link
      href="/login"
      className="underline-offset-4 hover:text-text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      {label}
    </Link>
  );
}
