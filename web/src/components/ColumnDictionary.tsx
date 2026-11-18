import legend from "../data/flydata-columns.json";

interface Entry {
  source: string;
  column: string | null;
  meaning_he: string;
  meaning_en: string;
}

/** What each column of the Israel Airports Authority feed means, and what it becomes in the clean table. */
export function ColumnDictionary() {
  const entries = legend as Entry[];
  return (
    <details className="card dictionary">
      <summary>מילון עמודות: מה כל קוד במקור אומר, ולמה הוא הופך בטבלה</summary>
      <p className="muted small">
        שמות העמודות במקור (רשות שדות התעופה) הם קודים. בדרך לטבלה הם מקבלים שם ברור. עמודות בעברית לא מועתקות.
      </p>
      <div className="scroll">
        <table>
          <thead>
            <tr>
              <th scope="col">במקור</th>
              <th scope="col">בטבלה</th>
              <th scope="col">משמעות</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((e) => (
              <tr key={e.source}>
                <td dir="ltr" className="mono">
                  {e.source}
                </td>
                <td dir="ltr" className="mono">
                  {e.column ?? "—"}
                </td>
                <td>{e.meaning_he}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
  );
}
