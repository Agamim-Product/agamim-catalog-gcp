import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { useParams } from "react-router-dom";
import { api } from "../api/client";
import type { Dataset, HistoryItem } from "../api/types";
import { FlightsBoard } from "../components/FlightsBoard";
import { ErrorBox, Loading } from "../components/States";
import { TableViewer } from "../components/TableViewer";
import { formatBytes, formatDateTime, formatNumber, frequencyLabel, timeAgo } from "../lib/format";

// Datasets with a typed, purpose-built view in addition to the generic table viewer.
const FLIGHTS_DATASET = "flydata";

type Tab = "overview" | "tables" | "flights" | "history";

export function DatasetPage() {
  const { name = "" } = useParams();
  const dataset = useQuery({ queryKey: ["dataset", name], queryFn: ({ signal }) => api.dataset(name, signal) });
  const [tab, setTab] = useState<Tab>("overview");

  if (dataset.isPending) return <Loading />;
  if (dataset.isError) {
    return (
      <ErrorBox
        error={dataset.error}
        onRetry={() => {
          void dataset.refetch();
        }}
      />
    );
  }

  const d = dataset.data;
  const tabs: [Tab, string][] = [
    ["overview", "סקירה"],
    ["tables", "טבלאות ונתונים"],
    ...(d.name === FLIGHTS_DATASET ? ([["flights", "לוח טיסות"]] as [Tab, string][]) : []),
    ["history", "היסטוריית שינויים"],
  ];

  return (
    <article className="dataset">
      <header className="page-head">
        <p className="eyebrow">{d.organization.title}</p>
        <h1>{d.title}</h1>
        <p className="muted">
          עודכן במקור {timeAgo(d.source_modified_at)} · תדירות: {frequencyLabel(d.update_frequency)}
        </p>
      </header>

      <div className="tabs" role="tablist" aria-label="חלקי המאגר">
        {tabs.map(([id, label]) => (
          <button
            key={id}
            type="button"
            role="tab"
            id={`tab-${id}`}
            aria-selected={tab === id}
            aria-controls={`panel-${id}`}
            className={tab === id ? "tab active" : "tab"}
            onClick={() => {
              setTab(id);
            }}
          >
            {label}
          </button>
        ))}
      </div>

      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`}>
        {tab === "overview" ? <Overview dataset={d} /> : null}
        {tab === "tables" ? <Tables dataset={d} /> : null}
        {tab === "flights" ? <FlightsBoard /> : null}
        {tab === "history" ? <History name={d.name} /> : null}
      </div>
    </article>
  );
}

function Overview({ dataset: d }: { dataset: Dataset }) {
  return (
    <div className="overview">
      <section className="card">
        <h2>תיאור</h2>
        <p className="prose">{d.description ?? "לא סופק תיאור במקור."}</p>
        {d.tags.length > 0 ? (
          <ul className="chips" aria-label="תגיות">
            {d.tags.map((t) => (
              <li key={t} className="chip chip-tag">
                {t}
              </li>
            ))}
          </ul>
        ) : null}
      </section>
      <section className="card">
        <h2>פרטים</h2>
        <dl className="facts facts-wide">
          <div>
            <dt>ארגון מפרסם</dt>
            <dd>{d.organization.title ?? "—"}</dd>
          </div>
          <div>
            <dt>רישיון</dt>
            <dd>{d.license ?? "—"}</dd>
          </div>
          <div>
            <dt>נוצר במקור</dt>
            <dd>{formatDateTime(d.source_created_at)}</dd>
          </div>
          <div>
            <dt>עודכן במקור</dt>
            <dd>{formatDateTime(d.source_modified_at)}</dd>
          </div>
          <div>
            <dt>שינוי אחרון בקטלוג</dt>
            <dd>{formatDateTime(d.catalog_changed_at)}</dd>
          </div>
          <div>
            <dt>מקור</dt>
            <dd>
              <a href={d.source_url} target="_blank" rel="noreferrer">
                הדף ב-data.gov.il
              </a>
            </dd>
          </div>
        </dl>
      </section>
      <section className="card">
        <h2>קבצים וטבלאות</h2>
        <ul className="resources">
          {d.resources.map((r) => (
            <li key={r.resource_id}>
              <span className="chip">{r.format ?? "?"}</span> {r.name ?? "ללא שם"}
              <span className="muted">
                {" "}
                · {formatBytes(r.size_bytes)}
                {r.is_queryable ? ` · ${formatNumber(r.row_count)} שורות` : ""}
              </span>
              {r.download_url ? (
                <>
                  {" "}
                  ·{" "}
                  <a href={r.download_url} target="_blank" rel="noreferrer">
                    הורדה מהמקור
                  </a>
                </>
              ) : null}
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}

function Tables({ dataset: d }: { dataset: Dataset }) {
  const tables = d.resources.filter((r) => r.is_queryable);
  if (tables.length === 0) {
    return <p className="state">למאגר זה אין טבלאות שניתן לעיין בהן. ניתן להוריד את הקבצים מהמקור.</p>;
  }
  return (
    <div className="stack">
      {tables.map((r) => (
        <TableViewer key={r.resource_id} resource={r} />
      ))}
    </div>
  );
}

function describe(item: HistoryItem): string {
  if (item.kind === "table_structure") {
    try {
      const parsed = JSON.parse(item.snapshot) as { columns?: unknown[] };
      return `מבנה הטבלה "${item.label ?? ""}": ${parsed.columns?.length ?? 0} עמודות`;
    } catch {
      return `מבנה הטבלה "${item.label ?? ""}"`;
    }
  }
  return "פרטי המאגר עודכנו (שם, תיאור, תגיות או מועד עדכון במקור)";
}

function History({ name }: { name: string }) {
  const history = useQuery({ queryKey: ["history", name], queryFn: ({ signal }) => api.history(name, signal) });
  if (history.isPending) return <Loading />;
  if (history.isError) return <ErrorBox error={history.error} />;
  return (
    <section className="card">
      <h2>היסטוריית שינויים</h2>
      <p className="muted">כל שינוי במאגר או במבנה הטבלאות נשמר כגרסה. הגרסה הנוכחית מסומנת.</p>
      <ol className="timeline">
        {history.data.items.map((item) => (
          <li key={`${item.kind}-${item.id}-${item.valid_from}`} className={item.is_current ? "current" : undefined}>
            <strong>{formatDateTime(item.valid_from)}</strong> · {describe(item)}
            {item.is_current ? <span className="chip chip-current">נוכחי</span> : null}
          </li>
        ))}
      </ol>
    </section>
  );
}
