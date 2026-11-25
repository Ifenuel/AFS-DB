/*
  AFS-DBA-001
  Purpose: Create the AFS schemas in every database.
  Safety: Idempotent.
  Prerequisites: Databases from 01_create_databases.sql.
  Run as: AFS_DBA.
*/

USE [AFS_CoreBanking];
GO
IF SCHEMA_ID(N'customer') IS NULL EXEC(N'CREATE SCHEMA [customer] AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'account')  IS NULL EXEC(N'CREATE SCHEMA [account]  AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'reference') IS NULL EXEC(N'CREATE SCHEMA [reference] AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'audit')    IS NULL EXEC(N'CREATE SCHEMA [audit]    AUTHORIZATION [dbo]');
GO

USE [AFS_Payments];
GO
IF SCHEMA_ID(N'payment')    IS NULL EXEC(N'CREATE SCHEMA [payment]    AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'transfer')   IS NULL EXEC(N'CREATE SCHEMA [transfer]   AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'settlement') IS NULL EXEC(N'CREATE SCHEMA [settlement] AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'audit')      IS NULL EXEC(N'CREATE SCHEMA [audit]      AUTHORIZATION [dbo]');
GO

USE [AFS_CustomerService];
GO
IF SCHEMA_ID(N'support')         IS NULL EXEC(N'CREATE SCHEMA [support]         AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'service_request') IS NULL EXEC(N'CREATE SCHEMA [service_request] AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'escalation')      IS NULL EXEC(N'CREATE SCHEMA [escalation]      AUTHORIZATION [dbo]');
GO

USE [AFS_Audit];
GO
IF SCHEMA_ID(N'security')       IS NULL EXEC(N'CREATE SCHEMA [security]       AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'administration') IS NULL EXEC(N'CREATE SCHEMA [administration] AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'operational')    IS NULL EXEC(N'CREATE SCHEMA [operational]    AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'audit')          IS NULL EXEC(N'CREATE SCHEMA [audit]          AUTHORIZATION [dbo]');
GO

USE [AFS_Reporting];
GO
IF SCHEMA_ID(N'reporting') IS NULL EXEC(N'CREATE SCHEMA [reporting] AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'staging')   IS NULL EXEC(N'CREATE SCHEMA [staging]   AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'warehouse') IS NULL EXEC(N'CREATE SCHEMA [warehouse] AUTHORIZATION [dbo]');
GO

USE [AFS_Fraud];
GO
IF SCHEMA_ID(N'fraud') IS NULL EXEC(N'CREATE SCHEMA [fraud] AUTHORIZATION [dbo]');
IF SCHEMA_ID(N'audit') IS NULL EXEC(N'CREATE SCHEMA [audit] AUTHORIZATION [dbo]');
GO

PRINT N'AFS schemas created.';
GO
