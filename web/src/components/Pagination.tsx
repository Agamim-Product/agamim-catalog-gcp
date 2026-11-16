export function Pagination({
  page,
  size,
  total,
  onChange,
  label = "דפדוף",
}: {
  page: number;
  size: number;
  total: number;
  onChange: (page: number) => void;
  label?: string;
}) {
  const pages = Math.max(1, Math.ceil(total / size));
  if (pages <= 1) return null;
  return (
    <nav className="pagination" aria-label={label}>
      <button
        type="button"
        className="btn btn-ghost"
        disabled={page <= 1}
        onClick={() => {
          onChange(page - 1);
        }}
      >
        הקודם
      </button>
      <span aria-live="polite">
        עמוד {page} מתוך {pages}
      </span>
      <button
        type="button"
        className="btn btn-ghost"
        disabled={page >= pages}
        onClick={() => {
          onChange(page + 1);
        }}
      >
        הבא
      </button>
    </nav>
  );
}
