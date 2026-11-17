import { useQuery } from "@tanstack/react-query";
import { NavLink, Outlet } from "react-router-dom";
import { api } from "../api/client";
import { formatDateTime, minutesSince, timeAgo } from "../lib/format";

export function SyncBadge() {
  const { data } = useQuery({
    queryKey: ["status"],
    queryFn: ({ signal }) => api.status(signal),
    refetchInterval: 60_000,
  });
  const finished = data?.last_run?.transformed_at ?? data?.last_run?.finished_at ?? null;
  const minutes = minutesSince(finished);
  const stale = minutes !== null && minutes > 90;
  return (
    <p className={`sync ${stale ? "sync-stale" : ""}`} title={finished ? formatDateTime(finished) : undefined}>
      <span className="dot" aria-hidden="true" />
      {finished ? `סונכרן מ-data.gov.il ${timeAgo(finished)}` : "ממתין לסנכרון ראשון"}
      {stale ? " · הנתונים לא התעדכנו כבר יותר משעה וחצי" : ""}
    </p>
  );
}

export function Layout() {
  return (
    <>
      <a className="skip-link" href="#main">
        דילוג לתוכן הראשי
      </a>
      <header className="topbar">
        <div className="topbar-inner">
          <NavLink to="/" className="brand" aria-label="קטלוג אגמים, דף הבית">
            <img src="/agamim-logo.png" alt="" width="40" height="40" />
            <span>קטלוג אגמים</span>
          </NavLink>
          <nav aria-label="ניווט ראשי">
            <ul>
              <li>
                <NavLink to="/" end>
                  בית
                </NavLink>
              </li>
              <li>
                <NavLink to="/catalog">כל המאגרים</NavLink>
              </li>
              <li>
                <NavLink to="/about">על הקטלוג</NavLink>
              </li>
            </ul>
          </nav>
          <img className="partner" src="/pakar-logo.svg" alt="פיקוד העורף" height="36" />
        </div>
      </header>
      <main id="main" className="page">
        <Outlet />
      </main>
      <footer className="footer">
        <SyncBadge />
        <p>
          מקור הנתונים:{" "}
          <a href="https://data.gov.il" target="_blank" rel="noreferrer">
            data.gov.il
          </a>{" "}
          · הנתונים מוצגים כפי שפורסמו, ללא שינוי בתוכן.
        </p>
      </footer>
    </>
  );
}
