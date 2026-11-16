// Environment-aware names and the run being transformed.
const vars = dataform.projectConfig.vars || {};
const env = vars.env || "dev";

const schemas = {
  bronze: `bronze_${env}`,
  silver: `silver_${env}`,
  gold: `gold_${env}`,
  assertions: `assertions_${env}`,
};

// RUN_ID looks like 20261116T203000Z. When it is set, bronze reads are limited to constant partitions,
// so BigQuery only scans that run's files. When it is empty (a manual full rebuild), the latest
// completed run is used and more files are scanned.
const runId = vars.run_id || "";
const runDate = runId ? `${runId.slice(0, 4)}-${runId.slice(4, 6)}-${runId.slice(6, 8)}` : "";

// How far back to look for the latest copy of a table that did not change in this run.
const LOOKBACK_DAYS = 3;

function runFilter(alias) {
  const a = alias ? `${alias}.` : "";
  if (runId) {
    return `${a}dt = DATE '${runDate}' AND ${a}run = '${runId}'`;
  }
  return `${a}run = (SELECT MAX(run) FROM \`${dataform.projectConfig.defaultDatabase}.${schemas.bronze}.ckan_run\`)`;
}

function lookbackFilter(alias) {
  const a = alias ? `${alias}.` : "";
  if (runId) {
    return `${a}dt BETWEEN DATE_SUB(DATE '${runDate}', INTERVAL ${LOOKBACK_DAYS} DAY) AND DATE '${runDate}' AND ${a}run <= '${runId}'`;
  }
  return "TRUE";
}

module.exports = { env, schemas, runId, runDate, runFilter, lookbackFilter, flightsDataset: vars.flights_dataset || "flydata" };
