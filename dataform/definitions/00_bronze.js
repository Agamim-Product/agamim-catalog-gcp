// Bronze: BigLake tables over the raw lake in Cloud Storage (created by Terraform, read in place).
// Every table has the columns run_id, fetched_at, entity_id, payload (the source record as a JSON string),
// plus the hive partitions dt (DATE) and run (STRING) taken from the file path.
const { schemas } = require("includes/env");

const descriptions = {
  ckan_package: "One line per dataset (CKAN package_show/package_search), unchanged.",
  ckan_datastore: "One line per datastore table: columns, total row count and first rows.",
  ckan_records: "One line per table row, for tables copied in full.",
  ckan_run: "One line per ingest run, written last. A run without this line is incomplete.",
};

for (const [name, description] of Object.entries(descriptions)) {
  declare({ schema: schemas.bronze, name, description });
}
