import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { api } from "../api/client";
import type { Flight } from "../api/types";
import { formatDay, formatTime } from "../lib/format";
import { useDebounced } from "../lib/useDebounced";
import { Pagination } from "./Pagination";
import { ScrollRegion } from "./ScrollRegion";
import { Empty, ErrorBox, Loading } from "./States";

const SIZE = 30;

function FlightHistory({ flight }: { flight: Flight }) {
  const history = useQuery({
    queryKey: ["flight-history", flight.flight_key],
    queryFn: ({ signal }) => api.flightHistory(flight.flight_key, signal),
  });
  if (history.isPending) return <Loading label="טוען היסטוריה…" />;
  if (history.isError) return <ErrorBox error={history.error} />;
  return (
    <ol className="timeline" aria-label={`היסטוריית טיסה ${flight.airline_code}${flight.flight_number}`}>
      {history.data.items.map((v) => (
        <li key={v.valid_from} className={v.is_current ? "current" : undefined}>
          <strong>{v.status_he ?? v.status_en ?? "—"}</strong> · משוער {formatTime(v.estimated_at)}
          <span className="muted"> · נקלט {formatTime(v.valid_from)}</span>
        </li>
      ))}
    </ol>
  );
}

/** Ben Gurion flights board, from the typed gold table (one current row per flight, with history). */
export function FlightsBoard() {
  const [text, setText] = useState("");
  const [direction, setDirection] = useState("");
  const [status, setStatus] = useState("");
  const [page, setPage] = useState(1);
  const [open, setOpen] = useState<string | null>(null);
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
      <p className="muted">כל שינוי בסטטוס או בשעה המשוערת נשמר כגרסה. לחצו על טיסה כדי לראות את ההיסטוריה שלה.</p>
      <div className="rows-tools">
        <label>
          חיפוש
          <input
            type="search"
            value={text}
            placeholder="מספר טיסה, חברה או יעד"
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
              </tr>
            </thead>
            <tbody>
              {flights.data.items.map((f) => (
                <FlightRow
                  key={f.flight_key}
                  flight={f}
                  open={open === f.flight_key}
                  onToggle={() => {
                    setOpen(open === f.flight_key ? null : f.flight_key);
                  }}
                />
              ))}
            </tbody>
          </table>
        </ScrollRegion>
      ) : null}
      <Pagination page={page} size={SIZE} total={flights.data?.total ?? 0} onChange={setPage} label="דפדוף בטיסות" />
    </section>
  );
}

function FlightRow({ flight: f, open, onToggle }: { flight: Flight; open: boolean; onToggle: () => void }) {
  return (
    <>
      <tr>
        <td>
          <button type="button" className="link-button" aria-expanded={open} onClick={onToggle}>
            <span dir="ltr">
              {f.airline_code} {f.flight_number}
            </span>
          </button>
          <div className="muted small">{f.airline_name}</div>
        </td>
        <td>{f.direction === "arrival" ? "נחיתה" : "המראה"}</td>
        <td>
          {f.city_he ?? f.city_en ?? "—"}
          <div className="muted small">{f.country_he}</div>
        </td>
        <td>
          {formatTime(f.scheduled_at)}
          <div className="muted small">{formatDay(f.scheduled_at)}</div>
        </td>
        <td>{formatTime(f.estimated_at)}</td>
        <td>{f.terminal ?? "—"}</td>
        <td>
          <span className={`status status-${(f.status_en ?? "").toLowerCase().replace(/\s+/g, "-")}`}>
            {f.status_he ?? f.status_en ?? "—"}
          </span>
        </td>
      </tr>
      {open ? (
        <tr className="history-row">
          <td colSpan={7}>
            <FlightHistory flight={f} />
          </td>
        </tr>
      ) : null}
    </>
  );
}
