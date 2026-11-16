import { ApiError } from "../api/client";

export function Loading({ label = "טוען…" }: { label?: string }) {
  return (
    <div className="state" role="status" aria-live="polite">
      <span className="spinner" aria-hidden="true" />
      {label}
    </div>
  );
}

export function ErrorBox({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const message =
    error instanceof ApiError && error.status === 404
      ? "הפריט המבוקש לא נמצא."
      : "לא הצלחנו לטעון את הנתונים. ייתכן שהשרת עמוס, נסו שוב בעוד רגע.";
  return (
    <div className="state state-error" role="alert">
      <p>{message}</p>
      {onRetry ? (
        <button type="button" className="btn btn-ghost" onClick={onRetry}>
          נסו שוב
        </button>
      ) : null}
    </div>
  );
}

export function Empty({ children }: { children: React.ReactNode }) {
  return <div className="state">{children}</div>;
}
