-- V001: schemas and tables for the catalog warehouse (Azure SQL, database `gold`).
--   silver: staging for one pipeline run, emptied and reloaded by Data Factory every run
--   gold:   dimensions with full history (SCD type 2), the run log, and the API's views
-- Idempotent: safe to run again.

IF SCHEMA_ID('silver') IS NULL EXEC('CREATE SCHEMA silver');
IF SCHEMA_ID('gold') IS NULL EXEC('CREATE SCHEMA gold');
IF SCHEMA_ID('meta') IS NULL EXEC('CREATE SCHEMA meta');
GO

-- ---------- silver: loaded by Data Factory ----------
-- Every row of the table, column names exactly as the source publishes them.
IF OBJECT_ID('silver.df_records_raw') IS NULL
CREATE TABLE silver.df_records_raw (
    _id       INT            NULL,
    CHOPER    NVARCHAR(20)   NULL,
    CHFLTN    NVARCHAR(20)   NULL,
    CHOPERD   NVARCHAR(200)  NULL,
    CHSTOL    NVARCHAR(40)   NULL,
    CHPTOL    NVARCHAR(40)   NULL,
    CHAORD    NVARCHAR(5)    NULL,
    CHLOC1    NVARCHAR(10)   NULL,
    CHLOC1D   NVARCHAR(200)  NULL,
    CHLOC1TH  NVARCHAR(200)  NULL,
    CHLOC1T   NVARCHAR(200)  NULL,
    CHLOC1CH  NVARCHAR(200)  NULL,
    CHLOCCT   NVARCHAR(200)  NULL,
    CHTERM    NVARCHAR(20)   NULL,
    CHCINT    NVARCHAR(100)  NULL,
    CHCKZN    NVARCHAR(100)  NULL,
    CHRMINE   NVARCHAR(100)  NULL,
    CHRMINH   NVARCHAR(100)  NULL
);
GO

-- ---------- gold: dimensions with history ----------
IF OBJECT_ID('gold.dim_organization') IS NULL
CREATE TABLE gold.dim_organization (
    surrogate_id    BIGINT IDENTITY(1,1) PRIMARY KEY,
    organization_id NVARCHAR(64)   NOT NULL,
    name            NVARCHAR(200)  NULL,
    title           NVARCHAR(400)  NULL,
    description     NVARCHAR(MAX)  NULL,
    image_url       NVARCHAR(1000) NULL,
    row_hash        VARBINARY(32)  NOT NULL,
    valid_from      DATETIME2(0)   NOT NULL,
    valid_to        DATETIME2(0)   NULL,
    is_current      BIT            NOT NULL,
    run_id          NVARCHAR(20)   NOT NULL
);

IF OBJECT_ID('gold.dim_dataset') IS NULL
CREATE TABLE gold.dim_dataset (
    surrogate_id       BIGINT IDENTITY(1,1) PRIMARY KEY,
    dataset_id         NVARCHAR(64)   NOT NULL,
    name               NVARCHAR(200)  NOT NULL,
    title              NVARCHAR(400)  NULL,
    description        NVARCHAR(MAX)  NULL,
    organization_id    NVARCHAR(64)   NULL,
    license            NVARCHAR(200)  NULL,
    author             NVARCHAR(200)  NULL,
    maintainer         NVARCHAR(200)  NULL,
    update_frequency   NVARCHAR(100)  NULL,
    tags_json          NVARCHAR(MAX)  NULL,  -- JSON array of tag names
    resource_count     INT            NULL,
    source_created_at  DATETIME2(0)   NULL,
    source_modified_at DATETIME2(0)   NULL,
    source_url         NVARCHAR(400)  NULL,
    row_hash           VARBINARY(32)  NOT NULL,
    valid_from         DATETIME2(0)   NOT NULL,
    valid_to           DATETIME2(0)   NULL,
    is_current         BIT            NOT NULL,
    run_id             NVARCHAR(20)   NOT NULL
);

IF OBJECT_ID('gold.dim_resource') IS NULL
CREATE TABLE gold.dim_resource (
    surrogate_id       BIGINT IDENTITY(1,1) PRIMARY KEY,
    resource_id        NVARCHAR(64)   NOT NULL,
    dataset_id         NVARCHAR(64)   NOT NULL,
    name               NVARCHAR(400)  NULL,
    description        NVARCHAR(MAX)  NULL,
    format             NVARCHAR(40)   NULL,
    download_url       NVARCHAR(1000) NULL,
    size_bytes         BIGINT         NULL,
    is_queryable       BIT            NOT NULL,
    update_frequency   NVARCHAR(100)  NULL,
    position           INT            NULL,
    data_modified_at   DATETIME2(0)   NULL,
    source_modified_at DATETIME2(0)   NULL,
    row_hash           VARBINARY(32)  NOT NULL,
    valid_from         DATETIME2(0)   NOT NULL,
    valid_to           DATETIME2(0)   NULL,
    is_current         BIT            NOT NULL,
    run_id             NVARCHAR(20)   NOT NULL
);

IF OBJECT_ID('gold.dim_resource_schema') IS NULL
CREATE TABLE gold.dim_resource_schema (
    surrogate_id BIGINT IDENTITY(1,1) PRIMARY KEY,
    resource_id  NVARCHAR(64)  NOT NULL,
    columns_json NVARCHAR(MAX) NOT NULL,  -- JSON array of {name, type, position}
    row_hash     VARBINARY(32) NOT NULL,
    valid_from   DATETIME2(0)  NOT NULL,
    valid_to     DATETIME2(0)  NULL,
    is_current   BIT           NOT NULL,
    run_id       NVARCHAR(20)  NOT NULL
);

IF OBJECT_ID('gold.dim_flight') IS NULL
CREATE TABLE gold.dim_flight (
    surrogate_id     BIGINT IDENTITY(1,1) PRIMARY KEY,
    flight_key       NVARCHAR(80)   NOT NULL,
    airline_code     NVARCHAR(20)   NOT NULL,
    flight_number    NVARCHAR(20)   NOT NULL,
    airline_name     NVARCHAR(200)  NULL,
    direction        NVARCHAR(10)   NOT NULL,
    scheduled_at     DATETIME2(0)   NOT NULL,  -- UTC
    estimated_at     DATETIME2(0)   NULL,      -- UTC
    airport_code     NVARCHAR(10)   NULL,
    airport_name     NVARCHAR(200)  NULL,
    city_en          NVARCHAR(200)  NULL,
    city_he          NVARCHAR(200)  NULL,
    country_en       NVARCHAR(200)  NULL,
    country_he       NVARCHAR(200)  NULL,
    terminal         INT            NULL,
    checkin_counters NVARCHAR(100)  NULL,
    checkin_zone     NVARCHAR(100)  NULL,
    status_en        NVARCHAR(100)  NULL,
    status_he        NVARCHAR(100)  NULL,
    row_hash         VARBINARY(32)  NOT NULL,
    valid_from       DATETIME2(0)   NOT NULL,
    valid_to         DATETIME2(0)   NULL,
    is_current       BIT            NOT NULL,
    run_id           NVARCHAR(20)   NOT NULL
);
GO

-- One current row per key, and fast "current" reads.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_flight_current')
    CREATE UNIQUE INDEX ux_dim_flight_current ON gold.dim_flight (flight_key) WHERE is_current = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_dataset_current')
    CREATE UNIQUE INDEX ux_dim_dataset_current ON gold.dim_dataset (dataset_id) WHERE is_current = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_resource_current')
    CREATE UNIQUE INDEX ux_dim_resource_current ON gold.dim_resource (resource_id) WHERE is_current = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_resource_schema_current')
    CREATE UNIQUE INDEX ux_dim_resource_schema_current ON gold.dim_resource_schema (resource_id) WHERE is_current = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_organization_current')
    CREATE UNIQUE INDEX ux_dim_organization_current ON gold.dim_organization (organization_id) WHERE is_current = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_dim_flight_key_history')
    CREATE INDEX ix_dim_flight_key_history ON gold.dim_flight (flight_key, valid_from);
GO

-- ---------- gold: current rows of fully copied tables, snapshot, run log ----------
IF OBJECT_ID('gold.resource_row') IS NULL
CREATE TABLE gold.resource_row (
    resource_id NVARCHAR(64)  NOT NULL,
    row_number  INT           NOT NULL,
    row_json    NVARCHAR(MAX) NOT NULL,
    run_id      NVARCHAR(20)  NOT NULL,
    CONSTRAINT pk_resource_row PRIMARY KEY (resource_id, row_number)
);

IF OBJECT_ID('gold.resource_snapshot') IS NULL
CREATE TABLE gold.resource_snapshot (
    resource_id      NVARCHAR(64)  NOT NULL PRIMARY KEY,
    row_count        INT           NULL,
    sample_rows_json NVARCHAR(MAX) NULL,
    has_full_rows    BIT           NOT NULL,
    copied_run_id    NVARCHAR(20)  NOT NULL,
    copied_at        DATETIME2(0)  NOT NULL
);

IF OBJECT_ID('gold.fct_ingestion_run') IS NULL
CREATE TABLE gold.fct_ingestion_run (
    run_id         NVARCHAR(20)   NOT NULL PRIMARY KEY,
    started_at     DATETIME2(0)   NULL,
    finished_at    DATETIME2(0)   NULL,
    status         NVARCHAR(20)   NOT NULL,
    source         NVARCHAR(200)  NULL,
    pipeline_run   NVARCHAR(64)   NULL,
    datasets       INT            NULL,
    resources      INT            NULL,
    tables_copied  INT            NULL,
    tables_failed  INT            NULL,
    tables_pending INT            NULL,
    rows_copied    INT            NULL,
    transformed_at DATETIME2(0)   NULL,
    message        NVARCHAR(2000) NULL
);
GO

-- ---------- meta: which migrations have run ----------
IF OBJECT_ID('meta.schema_migration') IS NULL
CREATE TABLE meta.schema_migration (
    version    NVARCHAR(20)  NOT NULL PRIMARY KEY,
    applied_at DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    checksum   NVARCHAR(64)  NOT NULL
);
GO
