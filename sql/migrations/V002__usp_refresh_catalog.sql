-- V002: gold.usp_refresh_catalog, called by the Data Factory pipeline after it has loaded silver.
--
-- Inputs from the pipeline:
--   @run_id        yyyyMMddHHmmss (UTC) of this run
--   @package_json  the package_show reply, unchanged (also stored in the lake)
--   @fields_json   the datastore_search?limit=0 reply (columns and total), unchanged
--   @resource_id   the table whose rows are in silver.df_records_raw
--   silver.df_records_raw  every row of that table, column names as published
--
-- One transaction: clean and type -> checks -> SCD2 merges into gold -> rows, snapshot, run log.
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

    SELECT
        @resource_id AS resource_id,
        (SELECT f.id AS name, f.type, f.position
           FROM (SELECT JSON_VALUE(value, '$.id') AS id, JSON_VALUE(value, '$.type') AS type,
                        CAST([key] AS INT) AS position
                   FROM OPENJSON(@fields_json, '$.result.fields')) f
          WHERE f.id <> N'_id'
          ORDER BY f.position
          FOR JSON PATH) AS columns_json,
        TRY_CONVERT(INT, JSON_VALUE(@fields_json, '$.result.total')) AS row_count
    INTO #schema;

    -- Flights, typed. Source times are Israel local time; stored as UTC. The key uses the local
    -- scheduled time, the same key the earlier pipelines used.
    WITH typed AS (
        SELECT
            NULLIF(LTRIM(RTRIM(CHOPER)), N'') AS airline_code,
            NULLIF(LTRIM(RTRIM(CHFLTN)), N'') AS flight_number,
            NULLIF(LTRIM(RTRIM(CHOPERD)), N'') AS airline_name,
            CASE CHAORD WHEN N'A' THEN N'arrival' WHEN N'D' THEN N'departure' END AS direction,
            TRY_CONVERT(DATETIME2(0), CHSTOL, 126) AS scheduled_local,
            TRY_CONVERT(DATETIME2(0), CHPTOL, 126) AS estimated_local,
            NULLIF(LTRIM(RTRIM(CHLOC1)), N'') AS airport_code,
            NULLIF(LTRIM(RTRIM(CHLOC1D)), N'') AS airport_name,
            NULLIF(LTRIM(RTRIM(CHLOC1T)), N'') AS city_en,
            NULLIF(LTRIM(RTRIM(CHLOC1TH)), N'') AS city_he,
            NULLIF(LTRIM(RTRIM(CHLOCCT)), N'') AS country_en,
            NULLIF(LTRIM(RTRIM(CHLOC1CH)), N'') AS country_he,
            TRY_CONVERT(INT, TRY_CONVERT(FLOAT, CHTERM)) AS terminal,
            NULLIF(LTRIM(RTRIM(CHCINT)), N'') AS checkin_counters,
            NULLIF(LTRIM(RTRIM(CHCKZN)), N'') AS checkin_zone,
            NULLIF(LTRIM(RTRIM(CHRMINE)), N'') AS status_en,
            NULLIF(LTRIM(RTRIM(CHRMINH)), N'') AS status_he
        FROM silver.df_records_raw
    ),
    keyed AS (
        SELECT
            CONCAT(airline_code, N'-', flight_number, N'-', direction, N'-',
                   REPLACE(REPLACE(CONVERT(CHAR(16), scheduled_local, 126), '-', ''), ':', '')) AS flight_key,
            airline_code, flight_number, airline_name, direction,
            CAST(CAST(scheduled_local AS DATETIME2(0)) AT TIME ZONE 'Israel Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(0)) AS scheduled_at,
            CAST(CAST(estimated_local AS DATETIME2(0)) AT TIME ZONE 'Israel Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(0)) AS estimated_at,
            airport_code, airport_name, city_en, city_he, country_en, country_he, terminal,
            checkin_counters, checkin_zone, status_en, status_he,
            ROW_NUMBER() OVER (PARTITION BY airline_code, flight_number, direction, scheduled_local
                               ORDER BY estimated_local DESC) AS rn
        FROM typed
        WHERE airline_code IS NOT NULL AND flight_number IS NOT NULL
          AND direction IS NOT NULL AND scheduled_local IS NOT NULL
    )
    SELECT * INTO #flight FROM keyed WHERE rn = 1;

    -- ================= 2. Checks: stop before gold if this run looks wrong =================
    IF (SELECT COUNT(*) FROM #dataset) <> 1 THROW 50010, 'package_show returned no active dataset', 1;
    IF (SELECT COUNT(*) FROM #flight) = 0 THROW 50011, 'no flights in this run', 1;
    IF EXISTS (SELECT flight_key FROM #flight GROUP BY flight_key HAVING COUNT(*) > 1)
        THROW 50012, 'duplicate flight_key in this run', 1;

    DECLARE @current INT = (SELECT COUNT(*) FROM #flight);
    DECLARE @previous INT = (SELECT COUNT(*) FROM gold.dim_flight WHERE is_current = 1);
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

    -- dim_flight: every change of status or time is a new version; a flight that leaves the board is closed.
    WITH src AS (
        SELECT flight_key, airline_code, flight_number, airline_name, direction, scheduled_at, estimated_at, airport_code, airport_name,
               city_en, city_he, country_en, country_he, terminal, checkin_counters, checkin_zone, status_en, status_he,
               HASHBYTES('SHA2_256', CONCAT(airline_code, N'|', flight_number, N'|', airline_name, N'|', direction, N'|',
                   CONVERT(NVARCHAR(30), scheduled_at, 126), N'|', CONVERT(NVARCHAR(30), estimated_at, 126), N'|', airport_code, N'|',
                   airport_name, N'|', city_en, N'|', city_he, N'|', country_en, N'|', country_he, N'|', terminal, N'|',
                   checkin_counters, N'|', checkin_zone, N'|', status_en, N'|', status_he)) AS row_hash
        FROM #flight
    )
    INSERT INTO gold.dim_flight (flight_key, airline_code, flight_number, airline_name, direction, scheduled_at, estimated_at, airport_code,
                                 airport_name, city_en, city_he, country_en, country_he, terminal, checkin_counters, checkin_zone,
                                 status_en, status_he, row_hash, valid_from, valid_to, is_current, run_id)
    SELECT flight_key, airline_code, flight_number, airline_name, direction, scheduled_at, estimated_at, airport_code,
           airport_name, city_en, city_he, country_en, country_he, terminal, checkin_counters, checkin_zone,
           status_en, status_he, row_hash, @now, NULL, 1, @run_id
    FROM (
        MERGE gold.dim_flight AS t
        USING src AS s ON t.flight_key = s.flight_key AND t.is_current = 1
        WHEN MATCHED AND t.row_hash <> s.row_hash THEN UPDATE SET is_current = 0, valid_to = @now
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (flight_key, airline_code, flight_number, airline_name, direction, scheduled_at, estimated_at, airport_code,
                    airport_name, city_en, city_he, country_en, country_he, terminal, checkin_counters, checkin_zone,
                    status_en, status_he, row_hash, valid_from, valid_to, is_current, run_id)
            VALUES (s.flight_key, s.airline_code, s.flight_number, s.airline_name, s.direction, s.scheduled_at, s.estimated_at, s.airport_code,
                    s.airport_name, s.city_en, s.city_he, s.country_en, s.country_he, s.terminal, s.checkin_counters, s.checkin_zone,
                    s.status_en, s.status_he, s.row_hash, @now, NULL, 1, @run_id)
        WHEN NOT MATCHED BY SOURCE AND t.is_current = 1 THEN UPDATE SET is_current = 0, valid_to = @now
        OUTPUT $action AS act, s.*
    ) AS changed
    WHERE act = N'UPDATE' AND flight_key IS NOT NULL;

    -- ================= 4. Current rows, snapshot, run log =================
    DELETE FROM gold.resource_row WHERE resource_id = @resource_id;
    INSERT INTO gold.resource_row (resource_id, row_number, row_json, run_id)
    SELECT @resource_id, r._id,
           (SELECT r2.* FROM silver.df_records_raw r2 WHERE r2._id = r._id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
           @run_id
    FROM silver.df_records_raw r
    WHERE r._id IS NOT NULL;

    MERGE gold.resource_snapshot AS t
    USING (
        SELECT s.resource_id, s.row_count,
               (SELECT TOP 20 r.* FROM silver.df_records_raw r ORDER BY r._id FOR JSON PATH, INCLUDE_NULL_VALUES) AS sample_rows_json
        FROM #schema s
    ) AS s ON t.resource_id = s.resource_id
    WHEN MATCHED THEN UPDATE SET row_count = s.row_count, sample_rows_json = s.sample_rows_json, has_full_rows = 1,
                                 copied_run_id = @run_id, copied_at = @now
    WHEN NOT MATCHED THEN INSERT (resource_id, row_count, sample_rows_json, has_full_rows, copied_run_id, copied_at)
                          VALUES (s.resource_id, s.row_count, s.sample_rows_json, 1, @run_id, @now);

    INSERT INTO gold.fct_ingestion_run (run_id, started_at, finished_at, status, source, pipeline_run, datasets, resources,
                                        tables_copied, tables_failed, tables_pending, rows_copied, transformed_at)
    VALUES (@run_id, @started, @now, N'succeeded', @source_url, @pipeline_run,
            (SELECT COUNT(*) FROM #dataset), (SELECT COUNT(*) FROM #resource), 1, 0, 0,
            (SELECT COUNT(*) FROM silver.df_records_raw), @now);

    COMMIT TRANSACTION;
END;
GO
