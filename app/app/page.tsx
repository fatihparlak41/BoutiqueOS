import { requireTenant, ROLE_LABELS } from "@/lib/tenant";

export default async function AppHomePage() {
  const { active, branch } = await requireTenant();

  return (
    <div className="max-w-2xl">
      <h2 className="text-base font-medium tracking-tightish">Kurulum tamamlandı</h2>
      <p className="mt-2 text-sm leading-relaxed text-muted">
        Veritabanı ve oturum yönetimi hazır. Modüller sırayla açılacak; şu an yalnızca giriş ve
        işletme erişimi çalışıyor.
      </p>

      <dl className="mt-8 divide-y divide-line border-y border-line text-sm">
        <div className="flex justify-between gap-6 py-2.5">
          <dt className="text-muted">İşletme</dt>
          <dd className="text-right">
            {active.business_name}{" "}
            <span className="text-muted" data-numeric>
              {active.business_code}
            </span>
          </dd>
        </div>
        <div className="flex justify-between gap-6 py-2.5">
          <dt className="text-muted">Şube</dt>
          <dd className="text-right">{branch ? `${branch.name} (${branch.code})` : "—"}</dd>
        </div>
        <div className="flex justify-between gap-6 py-2.5">
          <dt className="text-muted">Yetki</dt>
          <dd className="text-right">{ROLE_LABELS[active.role]}</dd>
        </div>
      </dl>
    </div>
  );
}
