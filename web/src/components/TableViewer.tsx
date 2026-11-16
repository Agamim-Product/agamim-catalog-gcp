import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { api } from "../api/client";
import type { Resource } from "../api/types";
import { cellText, columnTypeLabel, formatNumber } from "../lib/format";
import { useDebounced } from "../lib/useDebounced";
import { Pagination } from "./Pagination";
import { ScrollRegion } from "./ScrollRegion";
import { Empty, ErrorBox, Loading } from "./States";

const SIZE = 25;

/** Columns come from the table's current structure, so any table renders without code changes. */
export function TableViewer({ resource }: { resource: Resource }) {
  const [text, setText] = useState("");
  const [page, setPage] = useState(1);
  const q = useDebounced(text.trim(), 300);
  const rows = useQuery({
    queryKey: ["rows", resource.resource_id, q, page],
    queryFn: ({ signal }) => api.rows(resource.resource_id, { q, page, size: SIZE }, signal),
    placeholderData: keepPreviousData,
    enabled: Boolean(resource.has_full_rows),
  });
  const columns = resource.columns ?? [];
  const searchId = `rows-search-${resource.resource_id}`;

  return (
    <section className="card table-card" aria-label={resource.name ?? "טבלה"}>
      <header className="table-head">
        <h3>{resource.name ?? "טבלה"}</h3>
        <p className="muted">
          {formatNumber(resource.row_count)} שורות · {columns.length} עמודות
        </p>
      </header>

      <details className="schema">
        <summary>מבנה הטבלה ({columns.length} עמודות)</summary>
        <table>
          <thead>
            <tr>
              <th scope="col">#</th>
              <th scope="col">שם העמודה</th>
              <th scope="col">סוג</th>
            </tr>
          </thead>
          <tbody>
            {columns.map((c, i) => (
              <tr key={c.name}>
                <td>{i + 1}</td>
                <td dir="ltr" className="mono">
                  {c.name}
                </td>
                <td>{columnTypeLabel(c.type)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </details>

      {!resource.has_full_rows ? (
        <Empty>השורות של טבלה זו לא הועתקו לקטלוג. ניתן להוריד אותן מהמקור.</Empty>
      ) : (
        <>
          <div className="rows-tools">
            <label htmlFor={searchId}>חיפוש בשורות</label>
            <input
              id={searchId}
              type="search"
              value={text}
              onChange={(e) => {
                setText(e.target.value);
                setPage(1);
              }}
            />
            {rows.data ? <span className="muted">{formatNumber(rows.data.total)} תוצאות</span> : null}
          </div>
          {rows.isPending ? <Loading /> : null}
          {rows.isError ? <ErrorBox error={rows.error} /> : null}
          {rows.data ? (
            <ScrollRegion label="שורות הטבלה">
              <table className="data">
                <thead>
                  <tr>
                    {columns.map((c) => (
                      <th key={c.name} scope="col" dir="ltr">
                        {c.name}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {rows.data.items.map((row, i) => (
                    <tr key={cellText(row._id) + String(i)}>
                      {columns.map((c) => (
                        <td key={c.name}>{cellText(row[c.name])}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </ScrollRegion>
          ) : null}
          <Pagination page={page} size={SIZE} total={rows.data?.total ?? 0} onChange={setPage} label="דפדוף בשורות" />
        </>
      )}
    </section>
  );
}
