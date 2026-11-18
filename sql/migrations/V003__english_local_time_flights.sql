-- V003: flights become a simple, English-only table in Tel Aviv time; the refresh procedure is replaced.
--   gold.flights          one row per flight, replaced on every run. No row_hash / valid_from / valid_to.
--                         scheduled_at and estimated_at are Israel local time as the source publishes it;
--                         ingested_at is the Tel Aviv time of the pipeline run that loaded the row.
--   silver.flights_stage  what the Data Factory Copy step loads: the English source columns, renamed.
-- Removes gold.dim_flight (its history is not kept, by decision of the owner) and silver.df_records_raw.

IF OBJECT_ID('gold.flights') IS NULL
CREATE TABLE gold.flights (
    flight_key       NVARCHAR(80)  NOT NULL PRIMARY KEY,
    airline_code     NVARCHAR(20)  NOT NULL,
    flight_number    NVARCHAR(20)  NOT NULL,
    airline_name     NVARCHAR(200) NULL,
    direction        NVARCHAR(10)  NOT NULL,   -- arrival or departure
    scheduled_at     DATETIME2(0)  NOT NULL,   -- Tel Aviv time
    estimated_at     DATETIME2(0)  NULL,       -- Tel Aviv time
    airport_code     NVARCHAR(10)  NULL,
    airport_name     NVARCHAR(200) NULL,
    city_en          NVARCHAR(200) NULL,
    country_en       NVARCHAR(200) NULL,
    terminal         INT           NULL,
    checkin_counters NVARCHAR(100) NULL,
    checkin_zone     NVARCHAR(100) NULL,
    status_en        NVARCHAR(100) NULL,
    ingested_at      DATETIME2(0)  NOT NULL    -- Tel Aviv time
);

IF OBJECT_ID('silver.flights_stage') IS NULL
CREATE TABLE silver.flights_stage (
    airline_code     NVARCHAR(20)  NULL,
    flight_number    NVARCHAR(20)  NULL,
    airline_name     NVARCHAR(200) NULL,
    direction_code   NVARCHAR(5)   NULL,
    scheduled_at     NVARCHAR(40)  NULL,
    estimated_at     NVARCHAR(40)  NULL,
    airport_code     NVARCHAR(10)  NULL,
    airport_name     NVARCHAR(200) NULL,
    city_en          NVARCHAR(200) NULL,
    country_en       NVARCHAR(200) NULL,
    terminal         NVARCHAR(20)  NULL,
    checkin_counters NVARCHAR(100) NULL,
    checkin_zone     NVARCHAR(100) NULL,
    status_en        NVARCHAR(100) NULL,
    ingested_at      NVARCHAR(40)  NULL
);
GO

DROP TABLE IF EXISTS gold.dim_flight;
DROP TABLE IF EXISTS silver.df_records_raw;
GO

-- gold.usp_refresh_catalog: called by the Data Factory pipeline after it has loaded silver.flights_stage.
-- One transaction: clean and type -> checks -> merges into gold -> flights replaced -> rows, snapshot, run log.
-- Any failure rolls everything back, so gold keeps its last good state, and the pipeline fails.

CREATE OR ALTER PROCEDURE gold.usp_refresh_catalog
    @run_id        NVARCHAR(20),
    @package_json  NVARCHAR(MAX),
    @fields_json   NVARCHAR(MAX),
    @resource_id   NVARCHAR(64),
    @pipeline_run  NVARCHAR(64) = NULL,
    @source_url    NVARCHAR(200) = N'https://data.gov.il'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @started DATETIME2(0) = TRY_CONVERT(DATETIME2(0), STUFF(STUFF(STUFF(STUFF(STUFF(@run_id, 13, 0, ':'), 11, 0, ':'), 9, 0, 'T'), 7, 0, '-'), 5, 0, '-'), 126);
    DECLARE @pkg NVARCHAR(MAX) = JSON_QUERY(@package_json, '$.result');
    DECLARE @dataset_id NVARCHAR(64) = JSON_VALUE(@package_json, '$.result.id');

    IF ISJSON(@package_json) = 0 OR @pkg IS NULL THROW 50001, 'package_show reply is not valid JSON', 1;
    IF ISJSON(@fields_json) = 0 THROW 50002, 'datastore_search reply is not valid JSON', 1;

    -- ================= 1. Clean and type (silver) =================
    SELECT
        JSON_VALUE(@pkg, '$.id') AS dataset_id,
        JSON_VALUE(@pkg, '$.name') AS name,
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@pkg, '$.title'))), N'') AS title,
        NULLIF(LTRIM(RTRIM(n.notes)), N'') AS description,
        JSON_VALUE(@pkg, '$.organization.id') AS organization_id,
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@pkg, '$.license_title'))), N'') AS license,
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@pkg, '$.author'))), N'') AS author,
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@pkg, '$.maintainer'))), N'') AS maintainer,
        (SELECT TOP 1 NULLIF(LTRIM(RTRIM(e.[value])), N'')
           FROM OPENJSON(@pkg, '$.extras') WITH ([key] NVARCHAR(100), [value] NVARCHAR(400)) e
          WHERE e.[key] = N'Frequency') AS update_frequency,
        (SELECT COALESCE(N'[' + STRING_AGG(CAST(N'"' + STRING_ESCAPE(t.name, 'json') + N'"' AS NVARCHAR(MAX)), N',')
                         WITHIN GROUP (ORDER BY t.name) + N']', N'[]')
           FROM OPENJSON(@pkg, '$.tags') WITH (name NVARCHAR(200)) t) AS tags_json,
        TRY_CONVERT(INT, JSON_VALUE(@pkg, '$.num_resources')) AS resource_count,
        TRY_CONVERT(DATETIME2(0), LEFT(JSON_VALUE(@pkg, '$.metadata_created'), 19), 126) AS source_created_at,
        TRY_CONVERT(DATETIME2(0), LEFT(JSON_VALUE(@pkg, '$.metadata_modified'), 19), 126) AS source_modified_at,
        N'https://data.gov.il/dataset/' + JSON_VALUE(@pkg, '$.name') AS source_url
    INTO #dataset
    FROM OPENJSON(@pkg) WITH (notes NVARCHAR(MAX) '$.notes') n
    WHERE JSON_VALUE(@pkg, '$.state') = N'active';

    SELECT
        JSON_VALUE(@pkg, '$.organization.id') AS organization_id,
        JSON_VALUE(@pkg, '$.organization.name') AS name,
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@pkg, '$.organization.title'))), N'') AS title,
        NULLIF(LTRIM(RTRIM(o.description)), N'') AS description,
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@pkg, '$.organization.image_url'))), N'') AS image_url
    INTO #organization
    FROM OPENJSON(@pkg, '$.organization') WITH (description NVARCHAR(MAX) '$.description') o
    WHERE JSON_VALUE(@pkg, '$.organization.id') IS NOT NULL;

    SELECT
        r.id AS resource_id,
        JSON_VALUE(@pkg, '$.id') AS dataset_id,
        NULLIF(LTRIM(RTRIM(r.name)), N'') AS name,
        NULLIF(LTRIM(RTRIM(r.description)), N'') AS description,
        UPPER(NULLIF(LTRIM(RTRIM(r.format)), N'')) AS format,
        r.url AS download_url,
        TRY_CONVERT(BIGINT, r.size) AS size_bytes,
        CAST(CASE WHEN r.datastore_active = N'true' THEN 1 ELSE 0 END AS BIT) AS is_queryable,
        NULLIF(LTRIM(RTRIM(r.frequency)), N'') AS update_frequency,
        TRY_CONVERT(INT, r.position) AS position,
        TRY_CONVERT(DATETIME2(0), LEFT(r.last_modified, 19), 126) AS data_modified_at,
        TRY_CONVERT(DATETIME2(0), LEFT(r.metadata_modified, 19), 126) AS source_modified_at
    INTO #resource
    FROM OPENJSON(@pkg, '$.resources') WITH (
        id NVARCHAR(64), name NVARCHAR(400), description NVARCHAR(MAX), format NVARCHAR(40),
        url NVARCHAR(1000), size NVARCHAR(40), datastore_active NVARCHAR(10), frequency NVARCHAR(100) '$.Frequency',
        position NVARCHAR(10), last_modified NVARCHAR(40), metadata_modified NVARCHAR(40)
    ) r;

    -- The columns the catalog shows for this table are the columns of gold.flights, in order. This list is kept
    -- here (not read from the system views): the pipeline's identity can run this procedure but may not read
    -- table metadata. Change it together with the table.
    DECLARE @flight_columns NVARCHAR(MAX) = N'[
      {"name":"flight_key","type":"text","position":1},{"name":"airline_code","type":"text","position":2},
      {"name":"flight_number","type":"text","position":3},{"name":"airline_name","type":"text","position":4},
      {"name":"direction","type":"text","position":5},{"name":"scheduled_at","type":"timestamp","position":6},
      {"name":"estimated_at","type":"timestamp","position":7},{"name":"airport_code","type":"text","position":8},
      {"name":"airport_name","type":"text","position":9},{"name":"city_en","type":"text","position":10},
      {"name":"country_en","type":"text","position":11},{"name":"terminal","type":"int","position":12},
      {"name":"checkin_counters","type":"text","position":13},{"name":"checkin_zone","type":"text","position":14},
      {"name":"status_en","type":"text","position":15},{"name":"ingested_at","type":"timestamp","position":16}]';

    SELECT @resource_id AS resource_id, @flight_columns AS columns_json INTO #schema;


    -- Flights. The Data Factory Copy step already kept only the English columns and added the ingest time
    -- (Tel Aviv time). The source publishes Israel local time, and it is kept as it is: no time-zone conversion.
    -- The key uses the local scheduled time, the same key the earlier pipelines used.
    WITH typed AS (
        SELECT
            NULLIF(LTRIM(RTRIM(airline_code)), N'') AS airline_code,
            NULLIF(LTRIM(RTRIM(flight_number)), N'') AS flight_number,
            NULLIF(LTRIM(RTRIM(airline_name)), N'') AS airline_name,
            CASE direction_code WHEN N'A' THEN N'arrival' WHEN N'D' THEN N'departure' END AS direction,
            TRY_CONVERT(DATETIME2(0), scheduled_at, 126) AS scheduled_at,
            TRY_CONVERT(DATETIME2(0), estimated_at, 126) AS estimated_at,
            NULLIF(LTRIM(RTRIM(airport_code)), N'') AS airport_code,
            NULLIF(LTRIM(RTRIM(airport_name)), N'') AS airport_name,
            NULLIF(LTRIM(RTRIM(city_en)), N'') AS city_en,
            NULLIF(LTRIM(RTRIM(country_en)), N'') AS country_en,
            TRY_CONVERT(INT, TRY_CONVERT(FLOAT, terminal)) AS terminal,
            NULLIF(LTRIM(RTRIM(checkin_counters)), N'') AS checkin_counters,
            NULLIF(LTRIM(RTRIM(checkin_zone)), N'') AS checkin_zone,
            NULLIF(LTRIM(RTRIM(status_en)), N'') AS status_en,
            -- Ingest time in Tel Aviv time: set by the Copy step; if it is missing, take it here.
            COALESCE(TRY_CONVERT(DATETIME2(0), ingested_at, 120),
                     CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Israel Standard Time' AS DATETIME2(0))) AS ingested_at
        FROM silver.flights_stage
    ),
    keyed AS (
        SELECT
            CONCAT(airline_code, N'-', flight_number, N'-', direction, N'-',
                   REPLACE(REPLACE(CONVERT(CHAR(16), scheduled_at, 126), '-', ''), ':', '')) AS flight_key,
            *,
            ROW_NUMBER() OVER (PARTITION BY airline_code, flight_number, direction, scheduled_at
                               ORDER BY estimated_at DESC) AS rn
        FROM typed
        WHERE airline_code IS NOT NULL AND flight_number IS NOT NULL
          AND direction IS NOT NULL AND scheduled_at IS NOT NULL
    )
    SELECT flight_key, airline_code, flight_number, airline_name, direction, scheduled_at, estimated_at, airport_code,
           airport_name, city_en, country_en, terminal, checkin_counters, checkin_zone, status_en, ingested_at
    INTO #flight FROM keyed WHERE rn = 1;


    -- ================= 2. Checks: stop before gold if this run looks wrong =================
    IF (SELECT COUNT(*) FROM #dataset) <> 1 THROW 50010, 'package_show returned no active dataset', 1;
    IF (SELECT COUNT(*) FROM #flight) = 0 THROW 50011, 'no flights in this run', 1;
    IF EXISTS (SELECT flight_key FROM #flight GROUP BY flight_key HAVING COUNT(*) > 1)
        THROW 50012, 'duplicate flight_key in this run', 1;

    DECLARE @current INT = (SELECT COUNT(*) FROM #flight);
    DECLARE @previous INT = (SELECT COUNT(*) FROM gold.flights);
    IF @previous > 0 AND @current < 0.8 * @previous
    BEGIN
        DECLARE @msg NVARCHAR(400) = CONCAT(N'run shrank: ', @current, N' flights now, ', @previous, N' on the board before');
        THROW 50013, @msg, 1;
    END;

    -- ================= 3. Gold: SCD type 2 =================
    -- Pattern per dimension: a MERGE closes changed or vanished current rows and inserts new keys; its OUTPUT
    -- feeds an INSERT of the new version for keys whose row changed.
    BEGIN TRANSACTION;

    -- dim_organization
    WITH src AS (
        SELECT *, HASHBYTES('SHA2_256', CONCAT(name, N'|', title, N'|', description, N'|', image_url)) AS row_hash
        FROM #organization
    )
    INSERT INTO gold.dim_organization (organization_id, name, title, description, image_url, row_hash, valid_from, valid_to, is_current, run_id)
    SELECT organization_id, name, title, description, image_url, row_hash, @now, NULL, 1, @run_id
    FROM (
        MERGE gold.dim_organization AS t
        USING src AS s ON t.organization_id = s.organization_id AND t.is_current = 1
        WHEN MATCHED AND t.row_hash <> s.row_hash THEN UPDATE SET is_current = 0, valid_to = @now
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (organization_id, name, title, description, image_url, row_hash, valid_from, valid_to, is_current, run_id)
            VALUES (s.organization_id, s.name, s.title, s.description, s.image_url, s.row_hash, @now, NULL, 1, @run_id)
        OUTPUT $action AS act, s.organization_id, s.name, s.title, s.description, s.image_url, s.row_hash
    ) AS changed
    WHERE act = N'UPDATE';

    -- dim_dataset (one dataset per run: datasets not in this run are left as they are)
    WITH src AS (
        SELECT *, HASHBYTES('SHA2_256', CONCAT(name, N'|', title, N'|', description, N'|', organization_id, N'|', license, N'|',
               author, N'|', maintainer, N'|', update_frequency, N'|', tags_json, N'|', resource_count, N'|',
               CONVERT(NVARCHAR(30), source_created_at, 126), N'|', CONVERT(NVARCHAR(30), source_modified_at, 126), N'|', source_url)) AS row_hash
        FROM #dataset
    )
    INSERT INTO gold.dim_dataset (dataset_id, name, title, description, organization_id, license, author, maintainer, update_frequency,
                                  tags_json, resource_count, source_created_at, source_modified_at, source_url, row_hash, valid_from, valid_to, is_current, run_id)
    SELECT dataset_id, name, title, description, organization_id, license, author, maintainer, update_frequency,
           tags_json, resource_count, source_created_at, source_modified_at, source_url, row_hash, @now, NULL, 1, @run_id
    FROM (
        MERGE gold.dim_dataset AS t
        USING src AS s ON t.dataset_id = s.dataset_id AND t.is_current = 1
        WHEN MATCHED AND t.row_hash <> s.row_hash THEN UPDATE SET is_current = 0, valid_to = @now
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (dataset_id, name, title, description, organization_id, license, author, maintainer, update_frequency,
                    tags_json, resource_count, source_created_at, source_modified_at, source_url, row_hash, valid_from, valid_to, is_current, run_id)
            VALUES (s.dataset_id, s.name, s.title, s.description, s.organization_id, s.license, s.author, s.maintainer, s.update_frequency,
                    s.tags_json, s.resource_count, s.source_created_at, s.source_modified_at, s.source_url, s.row_hash, @now, NULL, 1, @run_id)
        OUTPUT $action AS act, s.*
    ) AS changed
    WHERE act = N'UPDATE';

    -- dim_resource: resources of this dataset; one that disappears from the dataset is closed.
    WITH src AS (
        SELECT *, HASHBYTES('SHA2_256', CONCAT(dataset_id, N'|', name, N'|', description, N'|', format, N'|', download_url, N'|', size_bytes, N'|',
               is_queryable, N'|', update_frequency, N'|', position, N'|', CONVERT(NVARCHAR(30), data_modified_at, 126), N'|',
               CONVERT(NVARCHAR(30), source_modified_at, 126))) AS row_hash
        FROM #resource
    )
    INSERT INTO gold.dim_resource (resource_id, dataset_id, name, description, format, download_url, size_bytes, is_queryable,
                                   update_frequency, position, data_modified_at, source_modified_at, row_hash, valid_from, valid_to, is_current, run_id)
    SELECT resource_id, dataset_id, name, description, format, download_url, size_bytes, is_queryable,
           update_frequency, position, data_modified_at, source_modified_at, row_hash, @now, NULL, 1, @run_id
    FROM (
        MERGE gold.dim_resource AS t
        USING src AS s ON t.resource_id = s.resource_id AND t.is_current = 1
        WHEN MATCHED AND t.row_hash <> s.row_hash THEN UPDATE SET is_current = 0, valid_to = @now
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (resource_id, dataset_id, name, description, format, download_url, size_bytes, is_queryable,
                    update_frequency, position, data_modified_at, source_modified_at, row_hash, valid_from, valid_to, is_current, run_id)
            VALUES (s.resource_id, s.dataset_id, s.name, s.description, s.format, s.download_url, s.size_bytes, s.is_queryable,
                    s.update_frequency, s.position, s.data_modified_at, s.source_modified_at, s.row_hash, @now, NULL, 1, @run_id)
        WHEN NOT MATCHED BY SOURCE AND t.is_current = 1 AND t.dataset_id = @dataset_id THEN UPDATE SET is_current = 0, valid_to = @now
        OUTPUT $action AS act, s.*
    ) AS changed
    WHERE act = N'UPDATE' AND resource_id IS NOT NULL;

    -- dim_resource_schema: a new version only when the table's columns change.
    WITH src AS (
        SELECT resource_id, columns_json, HASHBYTES('SHA2_256', columns_json) AS row_hash FROM #schema WHERE columns_json IS NOT NULL
    )
    INSERT INTO gold.dim_resource_schema (resource_id, columns_json, row_hash, valid_from, valid_to, is_current, run_id)
    SELECT resource_id, columns_json, row_hash, @now, NULL, 1, @run_id
    FROM (
        MERGE gold.dim_resource_schema AS t
        USING src AS s ON t.resource_id = s.resource_id AND t.is_current = 1
        WHEN MATCHED AND t.row_hash <> s.row_hash THEN UPDATE SET is_current = 0, valid_to = @now
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (resource_id, columns_json, row_hash, valid_from, valid_to, is_current, run_id)
            VALUES (s.resource_id, s.columns_json, s.row_hash, @now, NULL, 1, @run_id)
        OUTPUT $action AS act, s.resource_id, s.columns_json, s.row_hash
    ) AS changed
    WHERE act = N'UPDATE';

    -- flights: one row per flight, replaced as a whole by this run. It is all inside the transaction, so readers
    -- see either the previous board or this one, never a half-loaded table.
    DELETE FROM gold.flights;
    INSERT INTO gold.flights (flight_key, airline_code, flight_number, airline_name, direction, scheduled_at, estimated_at,
                              airport_code, airport_name, city_en, country_en, terminal, checkin_counters, checkin_zone,
                              status_en, ingested_at)
    SELECT flight_key, airline_code, flight_number, airline_name, direction, scheduled_at, estimated_at,
           airport_code, airport_name, city_en, country_en, terminal, checkin_counters, checkin_zone,
           status_en, ingested_at
    FROM #flight;

    -- ================= 4. Rows and snapshot for the catalog, run log =================
    DELETE FROM gold.resource_row WHERE resource_id = @resource_id;
    INSERT INTO gold.resource_row (resource_id, row_number, row_json, run_id)
    SELECT @resource_id,
           ROW_NUMBER() OVER (ORDER BY f.scheduled_at, f.flight_key),
           (SELECT f2.* FROM gold.flights f2 WHERE f2.flight_key = f.flight_key
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
           @run_id
    FROM gold.flights f;

    MERGE gold.resource_snapshot AS t
    USING (
        SELECT @resource_id AS resource_id,
               (SELECT COUNT(*) FROM gold.flights) AS row_count,
               (SELECT TOP 20 f.* FROM gold.flights f ORDER BY f.scheduled_at, f.flight_key FOR JSON PATH, INCLUDE_NULL_VALUES) AS sample_rows_json
    ) AS s ON t.resource_id = s.resource_id
    WHEN MATCHED THEN UPDATE SET row_count = s.row_count, sample_rows_json = s.sample_rows_json, has_full_rows = 1,
                                 copied_run_id = @run_id, copied_at = @now
    WHEN NOT MATCHED THEN INSERT (resource_id, row_count, sample_rows_json, has_full_rows, copied_run_id, copied_at)
                          VALUES (s.resource_id, s.row_count, s.sample_rows_json, 1, @run_id, @now);

    INSERT INTO gold.fct_ingestion_run (run_id, started_at, finished_at, status, source, pipeline_run, datasets, resources,
                                        tables_copied, tables_failed, tables_pending, rows_copied, transformed_at)
    VALUES (@run_id, @started, @now, N'succeeded', @source_url, @pipeline_run,
            (SELECT COUNT(*) FROM #dataset), (SELECT COUNT(*) FROM #resource), 1, 0, 0,
            (SELECT COUNT(*) FROM silver.flights_stage), @now);

    COMMIT TRANSACTION;
END;
GO