import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useSearchParams } from "react-router-dom";
import { api } from "../api/client";
import { DatasetCard } from "../components/DatasetCard";
import { Pagination } from "../components/Pagination";
import { SearchBox } from "../components/SearchBox";
import { Empty, ErrorBox, Loading } from "../components/States";

const PAGE_SIZE = 12;

export function CatalogPage() {
  const [params, setParams] = useSearchParams();
  const q = params.get("q") ?? "";
  const org = params.get("org") ?? "";
  const format = params.get("format") ?? "";
  const tag = params.get("tag") ?? "";
  const sort = params.get("sort") === "modified" ? "modified" : "title";
  const page = Math.max(1, Number(params.get("page") ?? "1") || 1);

  const facets = useQuery({ queryKey: ["facets"], queryFn: ({ signal }) => api.facets(signal) });
  const results = useQuery({
    queryKey: ["datasets", { q, org, format, tag, sort, page }],
    queryFn: ({ signal }) => api.datasets({ q, org, format, tag, sort, page, size: PAGE_SIZE }, signal),
    placeholderData: keepPreviousData,
  });

  function update(key: string, value: string) {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value);
    else next.delete(key);
    if (key !== "page") next.delete("page");
    setParams(next);
  }

  const total = results.data?.total ?? 0;
  const items = results.data?.items ?? [];

  return (
    <>
      <section className="page-head">
        <h1>כל המאגרים</h1>
        <SearchBox key={q} initial={q} />
      </section>

      <div className="catalog">
        <aside className="filters card" aria-label="סינון">
          <h2 className="visually-hidden">סינון</h2>
          <label>
            ארגון
            <select
              value={org}
              onChange={(e) => {
                update("org", e.target.value);
              }}
            >
              <option value="">כל הארגונים</option>
              {facets.data?.organizations.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label} ({o.count})
                </option>
              ))}
            </select>
          </label>
          <label>
            פורמט
            <select
              value={format}
              onChange={(e) => {
                update("format", e.target.value);
              }}
            >
              <option value="">כל הפורמטים</option>
              {facets.data?.formats.map((f) => (
                <option key={f.value} value={f.value}>
                  {f.label} ({f.count})
                </option>
              ))}
            </select>
          </label>
          <label>
            תגית
            <select
              value={tag}
              onChange={(e) => {
                update("tag", e.target.value);
              }}
            >
              <option value="">כל התגיות</option>
              {facets.data?.tags.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label} ({t.count})
                </option>
              ))}
            </select>
          </label>
          <label>
            מיון
            <select
              value={sort}
              onChange={(e) => {
                update("sort", e.target.value === "modified" ? "modified" : "");
              }}
            >
              <option value="title">לפי שם</option>
              <option value="modified">עודכן לאחרונה</option>
            </select>
          </label>
        </aside>

        <section className="results" aria-labelledby="results-count">
          <p id="results-count" className="muted" aria-live="polite">
            {results.isSuccess ? `נמצאו ${total} מאגרים${q ? ` עבור "${q}"` : ""}` : " "}
          </p>
          {results.isPending ? <Loading /> : null}
          {results.isError ? (
            <ErrorBox
              error={results.error}
              onRetry={() => {
                void results.refetch();
              }}
            />
          ) : null}
          {results.isSuccess && items.length === 0 ? <Empty>לא נמצאו מאגרים. נסו מילה אחרת או הסירו סינון.</Empty> : null}
          <div className="grid">
            {items.map((d) => (
              <DatasetCard key={d.dataset_id} dataset={d} />
            ))}
          </div>
          <Pagination
            page={page}
            size={PAGE_SIZE}
            total={total}
            onChange={(p) => {
              update("page", String(p));
            }}
          />
        </section>
      </div>
    </>
  );
}
