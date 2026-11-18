import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { api } from "../api/client";
import type { Flight } from "../api/types";
import { formatLocalDateTime, formatLocalDay, formatLocalTime } from "../lib/format";
import { useDebounced } from "../lib/useDebounced";
import { Pagination } from "./Pagination";
import { ScrollRegion } from "./ScrollRegion";
import { Empty, ErrorBox, Loading } from "./States";

const SIZE = 30;

/** Ben Gurion flights board, from the clean gold.flights table: English columns, Tel Aviv times. */
export function FlightsBoard() {
  const [text, setText] = useState("");
  const [direction, setDirection] = useState("");
  const [status, setStatus] = useState("");
  const [page, setPage] = useState(1);
  const q = useDebounced(text.trim(), 300);

  const flights = useQuery({
    queryKey: ["flights", q, direction, status, page],
    queryFn: ({ signal }) => api.flights({ q, direction, status, page, size: SIZE }, signal),
    placeholderData: keepPreviousData,
  });

  function reset<T>(setter: (v: T) => void) {
    return (v: T) => {
      setter(v);
      setPage(1);
    };
  }

  return (
    <section className="card" aria-labelledby="flights-title">
      <h2 id="flights-title">לוח טיסות נתב״ג</h2>
      <p className="muted">
        כל הזמנים בשעון תל אביב. הטבלה מוחלפת בכל ריצה, ועמודת &quot;נקלט&quot; מראה מתי נטענה השורה.
      </p>
      <div className="rows-tools">
        <label>
          חיפוש
          <input
            type="search"
            value={text}
            placeholder="מספר טיסה, חברה או יעד (באנגלית)"
            onChange={(e) => {
              reset(setText)(e.target.value);
            }}
          />
        </label>
        <label>
          כיוון
          <select
            value={direction}
            onChange={(e) => {
              reset(setDirection)(e.target.value);
            }}
          >
            <option value="">נחיתות והמראות</option>
            <option value="arrival">נחיתות</option>
            <option value="departure">המראות</option>
          </select>
        </label>
        <label>
          סטטוס
          <select
            value={status}
            onChange={(e) => {
              reset(setStatus)(e.target.value);
            }}
          >
            <option value="">כל הסטטוסים</option>
            {flights.data?.statuses.map((s) => (
              <option key={s.value} value={s.value}>
                {s.label} ({s.count})
              </option>
            ))}
          </select>
        </label>
      </div>
      {flights.isPending ? <Loading /> : null}
      {flights.isError ? <ErrorBox error={flights.error} /> : null}
      {flights.isSuccess && flights.data.items.length === 0 ? <Empty>אין טיסות שמתאימות לסינון.</Empty> : null}
      {flights.data && flights.data.items.length > 0 ? (
        <ScrollRegion label="טיסות">
          <table className="data flights">
            <thead>
              <tr>
                <th scope="col">טיסה</th>
                <th scope="col">כיוון</th>
                <th scope="col">יעד / מוצא</th>
                <th scope="col">מתוכנן</th>
                <th scope="col">משוער</th>
                <th scope="col">טרמינל</th>
                <th scope="col">סטטוס</th>
                <th scope="col">נקלט</th>
              </tr>
            </thead>
            <tbody>
              {flights.data.items.map((f) => (
                <FlightRow key={f.flight_key} flight={f} />
              ))}
            </tbody>
          </table>
        </ScrollRegion>
      ) : null}
      <Pagination page={page} size={SIZE} total={flights.data?.total ?? 0} onChange={setPage} label="דפדוף בטיסות" />
    </section>
  );
}

function FlightRow({ flight: f }: { flight: Flight }) {
  return (
    <tr>
      <td>
        <strong dir="ltr">
          {f.airline_code} {f.flight_number}
        </strong>
        <div className="muted small" dir="ltr">
          {f.airline_name}
        </div>
      </td>
      <td>{f.direction === "arrival" ? "נחיתה" : "המראה"}</td>
      <td dir="ltr">
        {f.city_en ?? "—"}
        <div className="muted small">{f.country_en}</div>
      </td>
      <td>
        {formatLocalTime(f.scheduled_at)}
        <div className="muted small">{formatLocalDay(f.scheduled_at)}</div>
      </td>
      <td>{formatLocalTime(f.estimated_at)}</td>
      <td>{f.terminal ?? "—"}</td>
      <td>
        <span className={`status status-${(f.status_en ?? "").toLowerCase().replace(/\s+/g, "-")}`} dir="ltr">
          {f.status_en ?? "—"}
        </span>
      </td>
      <td className="muted small">{formatLocalDateTime(f.ingested_at)}</td>
    </tr>
  );
}
