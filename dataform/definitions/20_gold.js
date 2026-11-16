// Gold: the warehouse. Dimension tables keep every change (SCD type 2); the website reads only from here.
const { schemas, lookbackFilter } = require("includes/env");
const { scd2 } = require("includes/scd2");

// Gold waits for every silver assertion, so bad data never reaches it.
const SILVER_ASSERTIONS = ["run_not_shrunk"];

function dimension(name, { source, key, columns, description }) {
  operate(name, {
    hasOutput: true,
    dataset: schemas.gold,
    description,
    dependencyTargets: SILVER_ASSERTIONS.map((a) => ({ name: a, dataset: schemas.assertions })),
    dependOnDependencyAssertions: true,
    tags: ["gold"],
  }).queries((ctx) => [scd2({ target: ctx.self(), source: ctx.ref(source), key, columns })]);
}

dimension("dim_organization", {
  source: "stg_organization",
  key: "organization_id",
  columns: ["name", "title", "description", "image_url"],
  description: "Publishing organizations, with history.",
});

dimension("dim_dataset", {
  source: "stg_package",
  key: "dataset_id",
  columns: [
    "name", "title", "description", "organization_id", "license", "author", "maintainer",
    "update_frequency", "tags", "resource_count", "source_created_at", "source_modified_at", "source_url",
  ],
  description: "Datasets, with history. One current row per dataset (is_current).",
});

dimension("dim_resource", {
  source: "stg_resource",
  key: "resource_id",
  columns: [
    "dataset_id", "name", "description", "format", "download_url", "size_bytes", "is_queryable",
    "update_frequency", "position", "data_modified_at", "source_modified_at",
  ],
  description: "Files and tables of each dataset, with history.",
});

dimension("dim_resource_schema", {
  source: "stg_resource_table",
  key: "resource_id",
  columns: ["columns"],
  description: "Column names and types of each queryable table. A new version means the table's structure changed.",
});

dimension("dim_flight", {
  source: "stg_flight",
  key: "flight_key",
  columns: [
    "airline_code", "flight_number", "airline_name", "direction", "scheduled_at", "estimated_at",
    "airport_code", "airport_name", "city_en", "city_he", "country_en", "country_he", "terminal",
    "checkin_counters", "checkin_zone", "status_en", "status_he",
  ],
  description:
    "Ben Gurion flights, with history: every change of status or estimated time is a new version. " +
    "A flight that leaves the board is closed (valid_to set).",
});

publish("resource_snapshot", {
  type: "table",
  schema: schemas.gold,
  description: "Latest row count and first rows of each queryable table.",
  dependencies: SILVER_ASSERTIONS,
  dependOnDependencyAssertions: true,
  tags: ["gold"],
}).query((ctx) => `
SELECT resource_id, row_count, sample_rows, has_full_rows, copied_run_id, copied_at
FROM ${ctx.ref("stg_resource_table")}
`);

publish("resource_row", {
  type: "table",
  schema: schemas.gold,
  description: "Current rows of tables copied in full. Columns vary per table; see dim_resource_schema.",
  bigquery: { clusterBy: ["resource_id"] },
  dependencies: SILVER_ASSERTIONS,
  dependOnDependencyAssertions: true,
  tags: ["gold"],
}).query((ctx) => `
SELECT resource_id, row_number, row, run_id FROM ${ctx.ref("stg_resource_row")}
`);

publish("fct_ingestion_run", {
  type: "incremental",
  schema: schemas.gold,
  uniqueKey: ["run_id"],
  description: "One row per completed ingest run, with its counts.",
  bigquery: { partitionBy: "DATE(started_at)" },
  tags: ["gold"],
}).query((ctx) => `
SELECT
  b.run AS run_id,
  SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', JSON_VALUE(p, '$.started_at')) AS started_at,
  SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', JSON_VALUE(p, '$.finished_at')) AS finished_at,
  JSON_VALUE(p, '$.status') AS status,
  JSON_VALUE(p, '$.source') AS source,
  SAFE_CAST(JSON_VALUE(p, '$.packages') AS INT64) AS datasets,
  SAFE_CAST(JSON_VALUE(p, '$.resources') AS INT64) AS resources,
  SAFE_CAST(JSON_VALUE(p, '$.datastore_fetched') AS INT64) AS tables_copied,
  SAFE_CAST(JSON_VALUE(p, '$.datastore_failed') AS INT64) AS tables_failed,
  SAFE_CAST(JSON_VALUE(p, '$.datastore_pending') AS INT64) AS tables_pending,
  SAFE_CAST(JSON_VALUE(p, '$.rows_fetched') AS INT64) AS rows_copied,
  CURRENT_TIMESTAMP() AS transformed_at
FROM ${ctx.ref("ckan_run")} b, UNNEST([SAFE.PARSE_JSON(b.payload)]) p
WHERE ${lookbackFilter("b")}
${ctx.when(ctx.incremental(), `AND b.run > (SELECT COALESCE(MAX(run_id), '') FROM ${ctx.self()})`)}
QUALIFY ROW_NUMBER() OVER (PARTITION BY b.run ORDER BY b.fetched_at DESC) = 1
`);

publish("v_catalog", {
  type: "view",
  schema: schemas.gold,
  description: "The current catalog, one row per dataset with its organization and tables. Read by the API.",
  tags: ["gold"],
}).query((ctx) => `
WITH resources AS (
  SELECT
    r.dataset_id,
    ARRAY_AGG(STRUCT(
      r.resource_id, r.name, r.description, r.format, r.download_url, r.size_bytes, r.is_queryable,
      r.update_frequency, r.data_modified_at, s.columns, snap.row_count, snap.has_full_rows, snap.copied_at,
      s.valid_from AS schema_changed_at
    ) ORDER BY r.position) AS resources
  FROM ${ctx.ref("dim_resource")} r
  LEFT JOIN ${ctx.ref("dim_resource_schema")} s ON s.resource_id = r.resource_id AND s.is_current
  LEFT JOIN ${ctx.ref("resource_snapshot")} snap ON snap.resource_id = r.resource_id
  WHERE r.is_current
  GROUP BY r.dataset_id
)
SELECT
  d.dataset_id, d.name, d.title, d.description, d.license, d.author, d.maintainer, d.update_frequency,
  d.tags, d.source_created_at, d.source_modified_at, d.source_url,
  d.valid_from AS catalog_changed_at,
  STRUCT(o.organization_id AS id, o.name, o.title, o.image_url) AS organization,
  COALESCE(res.resources, []) AS resources
FROM ${ctx.ref("dim_dataset")} d
LEFT JOIN ${ctx.ref("dim_organization")} o ON o.organization_id = d.organization_id AND o.is_current
LEFT JOIN resources res ON res.dataset_id = d.dataset_id
WHERE d.is_current
`);
