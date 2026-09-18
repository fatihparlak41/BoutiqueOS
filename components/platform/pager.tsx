import Link from "next/link";
import { PAGE_SIZE } from "@/lib/platform/model";

/** Server-side pagination links: the RPC bounds the page, this only moves the offset. */
export function Pager({ total, offset, href }: { total: number; offset: number; href: (page: number) => string }) {
  const page = Math.floor(offset / PAGE_SIZE) + 1;
  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  if (pages <= 1) return null;
  const cls = "text-xs text-text-muted underline-offset-4 hover:text-text-primary hover:underline";
  return (
    <nav aria-label="Sayfalar" className="flex items-center gap-4 text-xs text-text-muted" data-numeric>
      {page > 1 ? <Link href={href(page - 1)} className={cls}>← Önceki</Link> : <span aria-hidden>← Önceki</span>}
      <span>
        {page} / {pages}
      </span>
      {page < pages ? <Link href={href(page + 1)} className={cls}>Sonraki →</Link> : <span aria-hidden>Sonraki →</span>}
    </nav>
  );
}
