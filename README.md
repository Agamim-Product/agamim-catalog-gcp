# Agamim open-data catalog

A public, Hebrew (right-to-left) catalog of Israeli government open data. Every 30 minutes an **Azure Data
Factory** pipeline copies a dataset from [data.gov.il](https://data.gov.il) into a data lake, cleans and checks
it, and merges it into a warehouse that keeps every change. The website shows each dataset with its publisher,
table structure, rows and change history. The first dataset is the Ben Gurion Airport flights board (`flydata`).

Architecture diagram: [`docs/architecture.drawio`](docs/architecture.drawio) (open it at app.diagrams.net).

## How data flows

```
data.gov.il API ──Copy──► Data Lake (landing, raw JSON = bronze) ──Copy──► Azure SQL silver
                                                                              │ gold.usp_refresh_catalog
                                                                              ▼ (clean, check, SCD2 merge)
                         website + /api (App Service) ◄── reads ──────── Azure SQL gold
```

- **Bronze:** each API reply is saved unchanged in the lake, under `landing/ckan/<entity>/dt=YYYY-MM-DD/run=<run_id>/`.
- **Silver:** that run's rows, loaded into `silver.df_records_raw`. The table is emptied before each load.
- **Gold:** dimension tables with full history (`valid_from`, `valid_to`, `is_current`): `dim_dataset`, `dim_resource`,
  `dim_resource_schema`, `dim_flight` and the others. Plus the current rows, a snapshot of each table, and the run
  log `fct_ingestion_run`.
- **Checks:** a run stops before touching gold if:
  - it found no data,
  - flight keys are duplicated, or
  - the flights board shrank by more than 20%.
  Gold keeps its last good state, and an alert email is sent from prod.

## Environments

| | dev | staging | prod |
|---|---|---|---|
| Resource group | `rg-agamim-catalog-dev-ilc` | `rg-agamim-catalog-stg-ilc` | `rg-agamim-catalog-prod-ilc` |
| Website | app-agamim-catalog-dev-dc3eee23.azurewebsites.net | app-agamim-catalog-stg-dc3eee23.azurewebsites.net | app-agamim-catalog-prod-dc3eee23.azurewebsites.net |
| Pipeline schedule | on demand (CI) | on demand (CI) | every 30 minutes |
| App Service / SQL | F1 / Basic | F1 / Basic | B1 / Basic |

All three are in Israel Central. `rg-agamim-catalog-shared-ilc` holds the Terraform state and the GitHub
sign-in identities.

## Delivery (GitHub Actions)

- **Pull request:** these must all pass (`.github/workflows/ci.yml`):
  - **API:** ruff, mypy --strict, pytest (≥80% coverage), pip-audit
  - **Website:** eslint, strict TypeScript, vitest (≥80%), build, npm audit
  - **Data Factory:** `adf/validate.py`, plus migration naming checks
  - **Terraform:** fmt, validate, tflint, Checkov (accepted risks are listed, with reasons, in `.checkov.yaml`), and a read-only plan for each environment
  - **Security:** gitleaks, Trivy, CodeQL
- **Merge to main:** `deploy.yml` runs CI again and builds the release **once** (`scripts/package_app.sh`). It then
  deploys that same release to dev, and to staging if dev passed. It stops there.
- **Production is manual:** in GitHub, open Actions, then Deploy, then **Run workflow** on `main`. That run builds
  the release once and promotes it dev, staging, production. The production job also waits for the required
  reviewer of the `production` environment.
- **Each deploy** (`_deploy-env.yml`):
  1. terraform apply
  2. SQL migrations (`sql/migrate.py`)
  3. Data Factory deploy (`adf/deploy.py`) and one pipeline run
  4. website + API deploy
  5. smoke test
- **Signing in to Azure:** GitHub uses OIDC, so no secrets are stored. Each environment has its own identity, which
  can only change its own resource group.

## Repository

| Path | What it is |
|---|---|
| `adf/` | Data Factory linked services, datasets, the pipeline and the trigger (Data Factory Git format), plus `deploy.py` and `validate.py` |
| `sql/migrations/` | Warehouse schema and the refresh procedure, applied in order by `sql/migrate.py` |
| `sql/bootstrap/` | One-time database users for each environment's managed identities (run by the SQL admin) |
| `backend/` | Read-only FastAPI catalog API over gold (Python 3.12, uv) |
| `web/` | React + Vite + TypeScript website (Hebrew, right-to-left) |
| `infra/azure/` | Terraform: `shared/`, `envs/{dev,stg,prod}/`, `modules/catalog_env/` |
| `scripts/package_app.sh` | Builds the one deployable zip (API + dependencies + website) |

## Working locally

```bash
# API
cd backend && uv sync && uv run pytest
# Website (talks to the dev API through Vite's proxy)
cd web && npm ci && API_TARGET=https://app-agamim-catalog-dev-dc3eee23.azurewebsites.net npm run dev
# Terraform (Azure CLI sign-in; the SQL admin values come from the environment, never from the code)
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TF_VAR_sql_admin_object_id=$(az ad signed-in-user show --query id -o tsv)
export TF_VAR_sql_admin_login="<Entra ID sign-in name of the SQL admin>"
terraform -chdir=infra/azure/envs/dev plan
```

## Adding another dataset

1. Add a pipeline with that dataset's name and table resource ID: copy `pl_ingest_flydata`, or parameterise it.
2. If you want a typed model of its rows, like `dim_flight`, add it in a new migration. Otherwise the generic
   `resource_row` and `dim_resource_schema` tables already show any table's rows and columns.
3. Open a PR. CI validates it, and merging it deploys it.
