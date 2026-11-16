import { useQuery } from "@tanstack/react-query";
import { api } from "../api/client";
import type { Dataset } from "../api/types";
import { DatasetCard } from "../components/DatasetCard";
import { SearchBox } from "../components/SearchBox";
import { Empty, ErrorBox, Loading } from "../components/States";
import { formatNumber, timeAgo } from "../lib/format";

function byOrganization(datasets: Dataset[]): [string, Dataset[]][] {
  const groups = new Map<string, Dataset[]>();
  for (const d of datasets) {
    const key = d.organization.title ?? "ארגון לא ידוע";
    groups.set(key, [...(groups.get(key) ?? []), d]);
  }
  return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b, "he"));
}

export function HomePage() {
  const datasets = useQuery({
    queryKey: ["datasets", "home"],
    queryFn: ({ signal }) => api.datasets({ size: 200, sort: "title" }, signal),
  });
  const status = useQuery({ queryKey: ["status"], queryFn: ({ signal }) => api.status(signal) });
  const items = datasets.data?.items ?? [];
  const rows = items.flatMap((d) => d.resources).reduce((sum, r) => sum + (r.row_count ?? 0), 0);
  const lastRun = status.data?.last_run;

  return (
    <>
      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-text">
          <p className="eyebrow">נתונים פתוחים, מתעדכנים כל 30 דקות</p>
          <h1 id="hero-title">קטלוג המאגרים</h1>
          <p className="lede">
            כל מאגר מוצג עם הארגון שמפרסם אותו, מבנה הטבלאות וסוגי העמודות, השורות עצמן והיסטוריית השינויים.
          </p>
          <SearchBox />
        </div>
        <img className="hero-mark" src="/agamim-emblem.png" alt="" width="160" height="160" />
      </section>

      <section className="stats" aria-label="תמונת מצב">
        <div className="stat">
          <span className="stat-value">{formatNumber(datasets.data?.total)}</span>
          <span className="stat-label">מאגרים בקטלוג</span>
        </div>
        <div className="stat">
          <span className="stat-value">{formatNumber(rows)}</span>
          <span className="stat-label">שורות נתונים</span>
        </div>
        <div className="stat">
          <span className="stat-value">{lastRun ? timeAgo(lastRun.transformed_at ?? lastRun.finished_at) : "—"}</span>
          <span className="stat-label">סנכרון אחרון</span>
        </div>
      </section>

      <section aria-labelledby="by-org">
        <h2 id="by-org">מאגרים לפי ארגון</h2>
        {datasets.isPending ? <Loading /> : null}
        {datasets.isError ? (
          <ErrorBox
            error={datasets.error}
            onRetry={() => {
              void datasets.refetch();
            }}
          />
        ) : null}
        {datasets.isSuccess && items.length === 0 ? <Empty>עדיין אין מאגרים בקטלוג.</Empty> : null}
        {byOrganization(items).map(([org, list]) => (
          <section key={org} className="lake" aria-label={org}>
            <h3 className="lake-title">
              {org} <span className="count">{list.length}</span>
            </h3>
            <div className="grid">
              {list.map((d) => (
                <DatasetCard key={d.dataset_id} dataset={d} />
              ))}
            </div>
          </section>
        ))}
      </section>
    </>
  );
}
