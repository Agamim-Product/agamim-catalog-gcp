// Silver: typed, de-duplicated, flattened copies of the run being transformed.
const { schemas, runFilter, lookbackFilter, flightsDataset } = require("includes/env");

const ts = (expr) => `SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S', ${expr})`; // CKAN times are UTC
const text = (expr) => `NULLIF(TRIM(${expr}), '')`;

publish("stg_package", {
  type: "table",
  schema: schemas.silver,
  description: "One row per dataset in the run.",
  assertions: { uniqueKey: ["dataset_id"], nonNull: ["dataset_id", "name", "title"] },
  tags: ["silver"],
}).query((ctx) => `
SELECT
  b.entity_id AS dataset_id,
  JSON_VALUE(p, '$.name') AS name,
  ${text("JSON_VALUE(p, '$.title')")} AS title,
  ${text("JSON_VALUE(p, '$.notes')")} AS description,
  JSON_VALUE(p, '$.organization.id') AS organization_id,
  ${text("JSON_VALUE(p, '$.license_title')")} AS license,
  ${text("JSON_VALUE(p, '$.author')")} AS author,
  ${text("JSON_VALUE(p, '$.maintainer')")} AS maintainer,
  (SELECT ${text("JSON_VALUE(e, '$.value')")} FROM UNNEST(JSON_QUERY_ARRAY(p, '$.extras')) e
    WHERE JSON_VALUE(e, '$.key') = 'Frequency' LIMIT 1) AS update_frequency,
  ARRAY(SELECT JSON_VALUE(t, '$.name') FROM UNNEST(JSON_QUERY_ARRAY(p, '$.tags')) t ORDER BY 1) AS tags,
  SAFE_CAST(JSON_VALUE(p, '$.num_resources') AS INT64) AS resource_count,
  ${ts("JSON_VALUE(p, '$.metadata_created')")} AS source_created_at,
  ${ts("JSON_VALUE(p, '$.metadata_modified')")} AS source_modified_at,
  CONCAT('https://data.gov.il/dataset/', JSON_VALUE(p, '$.name')) AS source_url,
  b.run AS run_id
FROM ${ctx.ref("ckan_package")} b, UNNEST([SAFE.PARSE_JSON(b.payload)]) p
WHERE ${runFilter("b")}
  AND JSON_VALUE(p, '$.state') = 'active'
QUALIFY ROW_NUMBER() OVER (PARTITION BY b.entity_id ORDER BY b.fetched_at DESC) = 1
`);

publish("stg_organization", {
  type: "table",
  schema: schemas.silver,
  description: "One row per publishing organization seen in the run.",
  assertions: { uniqueKey: ["organization_id"], nonNull: ["organization_id", "title"] },
  tags: ["silver"],
}).query((ctx) => `
SELECT
  JSON_VALUE(p, '$.organization.id') AS organization_id,
  JSON_VALUE(p, '$.organization.name') AS name,
  ${text("JSON_VALUE(p, '$.organization.title')")} AS title,
  ${text("JSON_VALUE(p, '$.organization.description')")} AS description,
  ${text("JSON_VALUE(p, '$.organization.image_url')")} AS image_url,
  b.run AS run_id
FROM ${ctx.ref("ckan_package")} b, UNNEST([SAFE.PARSE_JSON(b.payload)]) p
WHERE ${runFilter("b")} AND JSON_VALUE(p, '$.organization.id') IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY JSON_VALUE(p, '$.organization.id') ORDER BY b.fetched_at DESC) = 1
`);

publish("stg_resource", {
  type: "table",
  schema: schemas.silver,
  description: "One row per file or table (CKAN resource) of the datasets in the run.",
  assertions: { uniqueKey: ["resource_id"], nonNull: ["resource_id", "dataset_id"] },
  tags: ["silver"],
}).query((ctx) => `
SELECT
  JSON_VALUE(r, '$.id') AS resource_id,
  b.entity_id AS dataset_id,
  ${text("JSON_VALUE(r, '$.name')")} AS name,
  ${text("JSON_VALUE(r, '$.description')")} AS description,
  UPPER(${text("JSON_VALUE(r, '$.format')")}) AS format,
  JSON_VALUE(r, '$.url') AS download_url,
  SAFE_CAST(JSON_VALUE(r, '$.size') AS INT64) AS size_bytes,
  COALESCE(SAFE_CAST(JSON_VALUE(r, '$.datastore_active') AS BOOL), FALSE) AS is_queryable,
  ${text("JSON_VALUE(r, '$.Frequency')")} AS update_frequency,
  SAFE_CAST(JSON_VALUE(r, '$.position') AS INT64) AS position,
  ${ts("JSON_VALUE(r, '$.last_modified')")} AS data_modified_at,
  ${ts("JSON_VALUE(r, '$.metadata_modified')")} AS source_modified_at,
  b.run AS run_id
FROM ${ctx.ref("ckan_package")} b, UNNEST([SAFE.PARSE_JSON(b.payload)]) p,
  UNNEST(JSON_QUERY_ARRAY(p, '$.resources')) r
WHERE ${runFilter("b")} AND JSON_VALUE(p, '$.state') = 'active'
QUALIFY ROW_NUMBER() OVER (PARTITION BY JSON_VALUE(r, '$.id') ORDER BY b.fetched_at DESC) = 1
`);

publish("stg_resource_table", {
  type: "table",
  schema: schemas.silver,
  description:
    "Latest columns, row count and first rows of each queryable table. A table that did not change in " +
    "this run keeps its last copy (looked up over the last few days).",
  assertions: { uniqueKey: ["resource_id"], nonNull: ["resource_id"] },
  tags: ["silver"],
}).query((ctx) => `
WITH latest AS (
  SELECT b.entity_id AS resource_id, b.run, b.fetched_at, SAFE.PARSE_JSON(b.payload) AS d
  FROM ${ctx.ref("ckan_datastore")} b
  WHERE ${lookbackFilter("b")}
  QUALIFY ROW_NUMBER() OVER (PARTITION BY b.entity_id ORDER BY b.run DESC) = 1
)
SELECT
  l.resource_id,
  ARRAY(
    SELECT AS STRUCT JSON_VALUE(f, '$.id') AS name, JSON_VALUE(f, '$.type') AS type, pos AS position
    FROM UNNEST(JSON_QUERY_ARRAY(l.d, '$.fields')) f WITH OFFSET pos
    WHERE JSON_VALUE(f, '$.id') != '_id'
    ORDER BY pos
  ) AS columns,
  SAFE_CAST(JSON_VALUE(l.d, '$.total') AS INT64) AS row_count,
  JSON_QUERY(l.d, '$.records') AS sample_rows,
  COALESCE(SAFE_CAST(JSON_VALUE(l.d, '$.full_rows') AS BOOL), FALSE) AS has_full_rows,
  l.run AS copied_run_id,
  l.run AS run_id,
  l.fetched_at AS copied_at
FROM latest l
JOIN ${ctx.ref("stg_resource")} r USING (resource_id)
`);

publish("stg_resource_row", {
  type: "table",
  schema: schemas.silver,
  description: "Every row of tables copied in full, from their latest copy. Columns vary per table (JSON).",
  bigquery: { clusterBy: ["resource_id"] },
  assertions: { nonNull: ["resource_id", "row"] },
  tags: ["silver"],
}).query((ctx) => `
WITH tables AS (
  SELECT resource_id, copied_run_id FROM ${ctx.ref("stg_resource_table")} WHERE has_full_rows
)
SELECT
  t.resource_id,
  SAFE_CAST(JSON_VALUE(SAFE.PARSE_JSON(b.payload), '$.row._id') AS INT64) AS row_number,
  JSON_QUERY(SAFE.PARSE_JSON(b.payload), '$.row') AS row,
  t.copied_run_id AS run_id
FROM ${ctx.ref("ckan_records")} b
JOIN tables t
  ON JSON_VALUE(SAFE.PARSE_JSON(b.payload), '$.resource_id') = t.resource_id AND b.run = t.copied_run_id
WHERE ${lookbackFilter("b")}
`);

// Typed model for the first dataset, the Ben Gurion flights board (data.gov.il "flydata").
publish("stg_flight", {
  type: "table",
  schema: schemas.silver,
  description: "Ben Gurion Airport flights board, typed. Times are Israel local time in the source.",
  assertions: {
    uniqueKey: ["flight_key"],
    nonNull: ["flight_key", "airline_code", "flight_number", "direction", "scheduled_at"],
    rowConditions: ["direction IN ('arrival', 'departure')"],
  },
  tags: ["silver"],
}).query((ctx) => `
WITH flight_rows AS (
  SELECT r.row, r.run_id
  FROM ${ctx.ref("stg_resource_row")} r
  JOIN ${ctx.ref("stg_resource")} res USING (resource_id)
  JOIN ${ctx.ref("stg_package")} p USING (dataset_id)
  WHERE p.name = '${flightsDataset}'
),
typed AS (
  SELECT
    ${text("JSON_VALUE(row, '$.CHOPER')")} AS airline_code,
    ${text("JSON_VALUE(row, '$.CHFLTN')")} AS flight_number,
    ${text("JSON_VALUE(row, '$.CHOPERD')")} AS airline_name,
    CASE JSON_VALUE(row, '$.CHAORD') WHEN 'A' THEN 'arrival' WHEN 'D' THEN 'departure' END AS direction,
    TIMESTAMP(SAFE.PARSE_DATETIME('%Y-%m-%dT%H:%M:%S', JSON_VALUE(row, '$.CHSTOL')), 'Asia/Jerusalem') AS scheduled_at,
    TIMESTAMP(SAFE.PARSE_DATETIME('%Y-%m-%dT%H:%M:%S', JSON_VALUE(row, '$.CHPTOL')), 'Asia/Jerusalem') AS estimated_at,
    ${text("JSON_VALUE(row, '$.CHLOC1')")} AS airport_code,
    ${text("JSON_VALUE(row, '$.CHLOC1D')")} AS airport_name,
    ${text("JSON_VALUE(row, '$.CHLOC1T')")} AS city_en,
    ${text("JSON_VALUE(row, '$.CHLOC1TH')")} AS city_he,
    ${text("JSON_VALUE(row, '$.CHLOCCT')")} AS country_en,
    ${text("JSON_VALUE(row, '$.CHLOC1CH')")} AS country_he,
    SAFE_CAST(JSON_VALUE(row, '$.CHTERM') AS INT64) AS terminal,
    ${text("JSON_VALUE(row, '$.CHCINT')")} AS checkin_counters,
    ${text("JSON_VALUE(row, '$.CHCKZN')")} AS checkin_zone,
    ${text("JSON_VALUE(row, '$.CHRMINE')")} AS status_en,
    ${text("JSON_VALUE(row, '$.CHRMINH')")} AS status_he,
    run_id
  FROM flight_rows
)
SELECT
  CONCAT(airline_code, '-', flight_number, '-', direction, '-',
         FORMAT_TIMESTAMP('%Y%m%dT%H%M', scheduled_at, 'Asia/Jerusalem')) AS flight_key,
  *
FROM typed
WHERE airline_code IS NOT NULL AND scheduled_at IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY airline_code, flight_number, direction, scheduled_at ORDER BY estimated_at DESC) = 1
`);

// A run must not shrink the catalog by more than 20% compared with the previous complete run.
assert("run_not_shrunk", {
  schema: schemas.assertions,
  description: "Fails when this run has under 80% of the previous run's datasets.",
  tags: ["silver"],
}).query((ctx) => `
WITH runs AS (
  SELECT run, SAFE_CAST(JSON_VALUE(SAFE.PARSE_JSON(payload), '$.packages') AS INT64) AS packages
  FROM ${ctx.ref("ckan_run")}
),
current_run AS (SELECT COUNT(*) AS n FROM ${ctx.ref("stg_package")}),
previous_run AS (
  SELECT packages FROM runs
  WHERE run < (SELECT MAX(run_id) FROM ${ctx.ref("stg_package")})
  ORDER BY run DESC LIMIT 1
)
SELECT c.n AS current_datasets, p.packages AS previous_datasets
FROM current_run c CROSS JOIN previous_run p
WHERE c.n < 0.8 * p.packages
`);
