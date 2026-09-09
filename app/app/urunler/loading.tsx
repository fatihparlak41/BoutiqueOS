/** Shown while the catalogue queries run. Mirrors the list layout so the page does not jump. */
export default function ProductsLoading() {
  return (
    <div className="space-y-6" aria-busy="true" aria-live="polite">
      <span className="sr-only">Yükleniyor…</span>

      <div className="h-6 w-40 animate-pulse rounded bg-panel" />
      <div className="h-16 border-y border-line" />

      <div className="space-y-2">
        {[0, 1, 2, 3, 4].map((row) => (
          <div key={row} className="h-10 animate-pulse rounded bg-panel/70" />
        ))}
      </div>
    </div>
  );
}
