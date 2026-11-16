#!/bin/sh
# Entry point of the Cloud Run Job `catalog-transform-<env>`.
# Runs the Dataform project for one ingest run: bronze -> silver (+ assertions) -> gold.
# Credentials: the job's service account (Application Default Credentials). No key file is used.
set -eu

: "${DATAFORM_ENV:?DATAFORM_ENV must be dev or prod}"
: "${GCP_PROJECT:?GCP_PROJECT is required}"
LOCATION="${BQ_LOCATION:-me-west1}"
RUN_ID="${RUN_ID:-}"

cd /app/dataform
# The CLI reads the target project and location from this file; with no key in it, it uses ADC.
printf '{"projectId":"%s","location":"%s"}\n' "$GCP_PROJECT" "$LOCATION" > .df-credentials.json

echo "{\"message\":\"transform starting\",\"env\":\"$DATAFORM_ENV\",\"run_id\":\"$RUN_ID\"}"
dataform run . \
  --default-database="$GCP_PROJECT" \
  --default-location="$LOCATION" \
  --default-schema="silver_$DATAFORM_ENV" \
  --assertion-schema="assertions_$DATAFORM_ENV" \
  --vars="env=$DATAFORM_ENV,run_id=$RUN_ID" \
  --job-labels="app=agamim-catalog,env=$DATAFORM_ENV" \
  --action-retry-limit=1 \
  --timeout=5m \
  --execution-timeout=25m \
  ${DATAFORM_FULL_REFRESH:+--full-refresh}
echo "{\"message\":\"transform finished\",\"env\":\"$DATAFORM_ENV\",\"run_id\":\"$RUN_ID\"}"
