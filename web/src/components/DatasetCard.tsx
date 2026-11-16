import { Link } from "react-router-dom";
import type { Dataset } from "../api/types";
import { formatNumber, frequencyLabel, timeAgo } from "../lib/format";

export function DatasetCard({ dataset }: { dataset: Dataset }) {
  const tables = dataset.resources.filter((r) => r.is_queryable);
  const rows = tables.reduce((sum, r) => sum + (r.row_count ?? 0), 0);
  const formats = [...new Set(dataset.resources.map((r) => r.format).filter(Boolean))];
  return (
    <article className="card dataset-card">
      <h3>
        <Link to={`/dataset/${encodeURIComponent(dataset.name)}`}>{dataset.title}</Link>
      </h3>
      <p className="muted org">{dataset.organization.title ?? "ארגון לא ידוע"}</p>
      {dataset.description ? <p className="desc">{dataset.description}</p> : null}
      <dl className="facts">
        <div>
          <dt>תדירות עדכון</dt>
          <dd>{frequencyLabel(dataset.update_frequency)}</dd>
        </div>
        <div>
          <dt>עודכן במקור</dt>
          <dd>{timeAgo(dataset.source_modified_at)}</dd>
        </div>
        <div>
          <dt>טבלאות</dt>
          <dd>
            {tables.length} ({formatNumber(rows)} שורות)
          </dd>
        </div>
      </dl>
      <ul className="chips" aria-label="פורמטים">
        {formats.map((f) => (
          <li key={f} className="chip">
            {f}
          </li>
        ))}
        {dataset.tags.map((t) => (
          <li key={t} className="chip chip-tag">
            {t}
          </li>
        ))}
      </ul>
    </article>
  );
}
