// Slowly changing dimension, type 2, as one BigQuery script.
//
// For each key in the source:
//   - new key                -> insert a current row
//   - same key, same hash    -> nothing
//   - same key, new hash     -> close the current row (valid_to = now), insert the new version
// For each current row whose key is no longer in the source -> close it.
//
// An empty source never closes anything: a broken run must not wipe the warehouse.
function scd2({ target, source, key, columns }) {
  const cols = columns.join(", ");
  const sCols = columns.map((c) => `S.${c}`).join(", ");
  return `
CREATE TABLE IF NOT EXISTS ${target}
PARTITION BY DATE(valid_from)
CLUSTER BY ${key}
AS
SELECT ${key}, ${cols},
       CAST(NULL AS STRING) AS row_hash,
       CAST(NULL AS TIMESTAMP) AS valid_from,
       CAST(NULL AS TIMESTAMP) AS valid_to,
       CAST(NULL AS BOOL) AS is_current,
       CAST(NULL AS STRING) AS run_id
FROM ${source}
WHERE FALSE;

BEGIN
  DECLARE source_rows INT64 DEFAULT (SELECT COUNT(*) FROM ${source});
  DECLARE now TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  IF source_rows > 0 THEN
    MERGE ${target} T
    USING (
      WITH s AS (
        SELECT ${key}, ${cols}, run_id,
               TO_HEX(MD5(TO_JSON_STRING(STRUCT(${cols})))) AS row_hash
        FROM ${source}
      )
      SELECT s.${key} AS merge_key, s.* FROM s
      UNION ALL
      SELECT CAST(NULL AS STRING) AS merge_key, s.*
      FROM s JOIN ${target} t
        ON t.${key} = s.${key} AND t.is_current AND t.row_hash != s.row_hash
    ) S
    ON T.${key} = S.merge_key AND T.is_current
    WHEN MATCHED AND T.row_hash != S.row_hash THEN
      UPDATE SET is_current = FALSE, valid_to = now
    WHEN NOT MATCHED BY TARGET THEN
      INSERT (${key}, ${cols}, row_hash, valid_from, valid_to, is_current, run_id)
      VALUES (S.${key}, ${sCols}, S.row_hash, now, NULL, TRUE, S.run_id)
    WHEN NOT MATCHED BY SOURCE AND T.is_current THEN
      UPDATE SET is_current = FALSE, valid_to = now;
  END IF;
END;
`;
}

module.exports = { scd2 };
