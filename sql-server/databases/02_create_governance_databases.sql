/*
  AFS-DBA-001
  Purpose: Create AFS_Identity, AFS_Compliance and AFS_Archive.
  Safety: Idempotent; existing databases are left untouched.
  Prerequisites: SQL Server 2022+ (target 2025 Developer); sysadmin.
  Run as: AFS_DBA / installation administrator.
*/
SET NOCOUNT ON;
GO

IF DB_ID('AFS_Identity') IS NULL
    CREATE DATABASE AFS_Identity;
GO
IF DB_ID('AFS_Compliance') IS NULL
    CREATE DATABASE AFS_Compliance;
GO
IF DB_ID('AFS_Archive') IS NULL
    CREATE DATABASE AFS_Archive;
GO

ALTER DATABASE AFS_Identity SET RECOVERY FULL;
ALTER DATABASE AFS_Compliance SET RECOVERY FULL;
ALTER DATABASE AFS_Archive SET RECOVERY FULL;
GO
