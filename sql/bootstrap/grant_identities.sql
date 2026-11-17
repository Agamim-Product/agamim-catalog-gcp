-- One-time per environment, run by the server's Entra ID administrator (not by CI):
-- creates database users for the environment's managed identities, each with only what it needs.
-- Variables (sqlcmd -v): ADF_NAME, WEB_APP_NAME, CI_IDENTITY_NAME. Idempotent.

-- Data Factory: loads silver (empty + insert) and runs the refresh procedure, which writes gold.
IF DATABASE_PRINCIPAL_ID('$(ADF_NAME)') IS NULL CREATE USER [$(ADF_NAME)] FROM EXTERNAL PROVIDER;
GRANT SELECT, INSERT, DELETE, ALTER ON SCHEMA::silver TO [$(ADF_NAME)];
GRANT EXECUTE ON SCHEMA::gold TO [$(ADF_NAME)];
GO

-- Website + API: reads gold only.
IF DATABASE_PRINCIPAL_ID('$(WEB_APP_NAME)') IS NULL CREATE USER [$(WEB_APP_NAME)] FROM EXTERNAL PROVIDER;
GRANT SELECT ON SCHEMA::gold TO [$(WEB_APP_NAME)];
GO

-- GitHub Actions deployer: applies schema migrations.
IF DATABASE_PRINCIPAL_ID('$(CI_IDENTITY_NAME)') IS NULL CREATE USER [$(CI_IDENTITY_NAME)] FROM EXTERNAL PROVIDER;
ALTER ROLE db_owner ADD MEMBER [$(CI_IDENTITY_NAME)];
GO

SELECT name, type_desc FROM sys.database_principals
WHERE name IN ('$(ADF_NAME)', '$(WEB_APP_NAME)', '$(CI_IDENTITY_NAME)');
