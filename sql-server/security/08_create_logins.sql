/*
  AFS-DBA-001
  Purpose: Create server logins for the lab.
  Safety: Creates missing logins; does not silently rotate existing passwords.
  Prerequisites: sysadmin; passwords supplied as sqlcmd variables at run time.
  Run as: AFS_DBA / installation administrator.
  IMPORTANT: Never put real passwords in this file. The deployment wrapper
             passes them from the process environment.
  SQLCMD variables:
    AFS_DBA_PASSWORD, AFS_APP_PASSWORD, AFS_DEVELOPER_PASSWORD,
    AFS_REPORTING_PASSWORD, AFS_AUDITOR_PASSWORD, AFS_OPS_PASSWORD
*/

USE [master];
GO

IF LEN(N'$(AFS_DBA_PASSWORD)') < 16
    THROW 53000, N'AFS_DBA_PASSWORD must be supplied and at least 16 characters.', 1;
IF LEN(N'$(AFS_APP_PASSWORD)') < 16
    THROW 53000, N'AFS_APP_PASSWORD must be supplied and at least 16 characters.', 1;
IF LEN(N'$(AFS_DEVELOPER_PASSWORD)') < 16
    THROW 53000, N'AFS_DEVELOPER_PASSWORD must be supplied and at least 16 characters.', 1;
IF LEN(N'$(AFS_REPORTING_PASSWORD)') < 16
    THROW 53000, N'AFS_REPORTING_PASSWORD must be supplied and at least 16 characters.', 1;
IF LEN(N'$(AFS_AUDITOR_PASSWORD)') < 16
    THROW 53000, N'AFS_AUDITOR_PASSWORD must be supplied and at least 16 characters.', 1;
IF LEN(N'$(AFS_OPS_PASSWORD)') < 16
    THROW 53000, N'AFS_OPS_PASSWORD must be supplied and at least 16 characters.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'AFS_DBA')
    CREATE LOGIN [AFS_DBA]
    WITH PASSWORD = N'$(AFS_DBA_PASSWORD)',
         CHECK_POLICY = ON,
         CHECK_EXPIRATION = OFF,
         DEFAULT_DATABASE = [master];
ELSE
    PRINT N'Login AFS_DBA already exists; password not changed.';

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'AFS_App')
    CREATE LOGIN [AFS_App]
    WITH PASSWORD = N'$(AFS_APP_PASSWORD)',
         CHECK_POLICY = ON,
         CHECK_EXPIRATION = OFF,
         DEFAULT_DATABASE = [AFS_CoreBanking];
ELSE
    PRINT N'Login AFS_App already exists; password not changed.';

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'AFS_Developer')
    CREATE LOGIN [AFS_Developer]
    WITH PASSWORD = N'$(AFS_DEVELOPER_PASSWORD)',
         CHECK_POLICY = ON,
         CHECK_EXPIRATION = OFF,
         DEFAULT_DATABASE = [AFS_CoreBanking];
ELSE
    PRINT N'Login AFS_Developer already exists; password not changed.';

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'AFS_Reporting')
    CREATE LOGIN [AFS_Reporting]
    WITH PASSWORD = N'$(AFS_REPORTING_PASSWORD)',
         CHECK_POLICY = ON,
         CHECK_EXPIRATION = OFF,
         DEFAULT_DATABASE = [AFS_Reporting];
ELSE
    PRINT N'Login AFS_Reporting already exists; password not changed.';

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'AFS_Auditor')
    CREATE LOGIN [AFS_Auditor]
    WITH PASSWORD = N'$(AFS_AUDITOR_PASSWORD)',
         CHECK_POLICY = ON,
         CHECK_EXPIRATION = OFF,
         DEFAULT_DATABASE = [AFS_Audit];
ELSE
    PRINT N'Login AFS_Auditor already exists; password not changed.';

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'AFS_Ops')
    CREATE LOGIN [AFS_Ops]
    WITH PASSWORD = N'$(AFS_OPS_PASSWORD)',
         CHECK_POLICY = ON,
         CHECK_EXPIRATION = OFF,
         DEFAULT_DATABASE = [master];
ELSE
    PRINT N'Login AFS_Ops already exists; password not changed.';
GO

IF IS_SRVROLEMEMBER(N'sysadmin', N'AFS_DBA') = 0
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [AFS_DBA];
GO

PRINT N'Server logins created. Existing passwords were not rotated.';
GO

SELECT name, type_desc, is_disabled, default_database_name, create_date
FROM sys.sql_logins
WHERE name LIKE N'AFS[_]%'
ORDER BY name;
GO
