/*
  AFS-DBA-001
  Purpose: Create the AFS databases with explicit data/log paths and recovery models.
  Safety: Idempotent for database creation; alters settings on existing databases.
  Prerequisites: SQL Server 2022+ (target 2025 Developer); sysadmin; directories exist.
  Run as: AFS_DBA / installation administrator.
  SQLCMD variables: DataRoot, LogRoot (defaults below; override with -v).
  Verification: SELECT name, recovery_model_desc FROM sys.databases WHERE name LIKE 'AFS[_]%';
*/

-- DataRoot and LogRoot are supplied by sqlcmd -v (the deployment wrapper passes
-- them). Do not hard-code :setvar defaults here: :setvar would silently override
-- the caller's -v value.
USE [master];
GO

IF DB_ID(N'AFS_CoreBanking') IS NULL
BEGIN
    PRINT N'Creating AFS_CoreBanking...';
    CREATE DATABASE [AFS_CoreBanking]
    ON PRIMARY
    (
        NAME = N'AFS_CoreBanking',
        FILENAME = N'$(DataRoot)\AFS_CoreBanking.mdf',
        SIZE = 256MB,
        FILEGROWTH = 64MB
    )
    LOG ON
    (
        NAME = N'AFS_CoreBanking_log',
        FILENAME = N'$(LogRoot)\AFS_CoreBanking_log.ldf',
        SIZE = 128MB,
        FILEGROWTH = 64MB
    );
END
ELSE
    PRINT N'AFS_CoreBanking already exists.';
GO

IF DB_ID(N'AFS_Payments') IS NULL
BEGIN
    PRINT N'Creating AFS_Payments...';
    CREATE DATABASE [AFS_Payments]
    ON PRIMARY
    (
        NAME = N'AFS_Payments',
        FILENAME = N'$(DataRoot)\AFS_Payments.mdf',
        SIZE = 256MB,
        FILEGROWTH = 64MB
    )
    LOG ON
    (
        NAME = N'AFS_Payments_log',
        FILENAME = N'$(LogRoot)\AFS_Payments_log.ldf',
        SIZE = 128MB,
        FILEGROWTH = 64MB
    );
END
ELSE
    PRINT N'AFS_Payments already exists.';
GO

IF DB_ID(N'AFS_CustomerService') IS NULL
BEGIN
    PRINT N'Creating AFS_CustomerService...';
    CREATE DATABASE [AFS_CustomerService]
    ON PRIMARY
    (
        NAME = N'AFS_CustomerService',
        FILENAME = N'$(DataRoot)\AFS_CustomerService.mdf',
        SIZE = 128MB,
        FILEGROWTH = 64MB
    )
    LOG ON
    (
        NAME = N'AFS_CustomerService_log',
        FILENAME = N'$(LogRoot)\AFS_CustomerService_log.ldf',
        SIZE = 64MB,
        FILEGROWTH = 64MB
    );
END
ELSE
    PRINT N'AFS_CustomerService already exists.';
GO

IF DB_ID(N'AFS_Audit') IS NULL
BEGIN
    PRINT N'Creating AFS_Audit...';
    CREATE DATABASE [AFS_Audit]
    ON PRIMARY
    (
        NAME = N'AFS_Audit',
        FILENAME = N'$(DataRoot)\AFS_Audit.mdf',
        SIZE = 128MB,
        FILEGROWTH = 64MB
    )
    LOG ON
    (
        NAME = N'AFS_Audit_log',
        FILENAME = N'$(LogRoot)\AFS_Audit_log.ldf',
        SIZE = 64MB,
        FILEGROWTH = 64MB
    );
END
ELSE
    PRINT N'AFS_Audit already exists.';
GO

IF DB_ID(N'AFS_Reporting') IS NULL
BEGIN
    PRINT N'Creating AFS_Reporting...';
    CREATE DATABASE [AFS_Reporting]
    ON PRIMARY
    (
        NAME = N'AFS_Reporting',
        FILENAME = N'$(DataRoot)\AFS_Reporting.mdf',
        SIZE = 128MB,
        FILEGROWTH = 64MB
    )
    LOG ON
    (
        NAME = N'AFS_Reporting_log',
        FILENAME = N'$(LogRoot)\AFS_Reporting_log.ldf',
        SIZE = 64MB,
        FILEGROWTH = 64MB
    );
END
ELSE
    PRINT N'AFS_Reporting already exists.';
GO

IF DB_ID(N'AFS_Fraud') IS NULL
BEGIN
    PRINT N'Creating AFS_Fraud...';
    CREATE DATABASE [AFS_Fraud]
    ON PRIMARY
    (
        NAME = N'AFS_Fraud',
        FILENAME = N'$(DataRoot)\AFS_Fraud.mdf',
        SIZE = 128MB,
        FILEGROWTH = 64MB
    )
    LOG ON
    (
        NAME = N'AFS_Fraud_log',
        FILENAME = N'$(LogRoot)\AFS_Fraud_log.ldf',
        SIZE = 64MB,
        FILEGROWTH = 64MB
    );
END
ELSE
    PRINT N'AFS_Fraud already exists.';
GO

-- ---------------------------------------------------------------------------
-- Database options
-- ---------------------------------------------------------------------------
ALTER DATABASE [AFS_CoreBanking] SET RECOVERY FULL;
ALTER DATABASE [AFS_CoreBanking] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [AFS_CoreBanking] SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE [AFS_CoreBanking] SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE [AFS_CoreBanking] SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE [AFS_CoreBanking] SET TARGET_RECOVERY_TIME = 60 SECONDS;
GO

ALTER DATABASE [AFS_Payments] SET RECOVERY FULL;
ALTER DATABASE [AFS_Payments] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [AFS_Payments] SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE [AFS_Payments] SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE [AFS_Payments] SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE [AFS_Payments] SET TARGET_RECOVERY_TIME = 60 SECONDS;
GO

ALTER DATABASE [AFS_CustomerService] SET RECOVERY FULL;
ALTER DATABASE [AFS_CustomerService] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [AFS_CustomerService] SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE [AFS_CustomerService] SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE [AFS_CustomerService] SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE [AFS_CustomerService] SET TARGET_RECOVERY_TIME = 60 SECONDS;
GO

ALTER DATABASE [AFS_Audit] SET RECOVERY FULL;
ALTER DATABASE [AFS_Audit] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [AFS_Audit] SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE [AFS_Audit] SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE [AFS_Audit] SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE [AFS_Audit] SET TARGET_RECOVERY_TIME = 60 SECONDS;
GO

ALTER DATABASE [AFS_Reporting] SET RECOVERY SIMPLE;
ALTER DATABASE [AFS_Reporting] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [AFS_Reporting] SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE [AFS_Reporting] SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE [AFS_Reporting] SET COMPATIBILITY_LEVEL = 160;
GO

ALTER DATABASE [AFS_Fraud] SET RECOVERY FULL;
ALTER DATABASE [AFS_Fraud] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [AFS_Fraud] SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE [AFS_Fraud] SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE [AFS_Fraud] SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE [AFS_Fraud] SET TARGET_RECOVERY_TIME = 60 SECONDS;
GO

-- Read-committed snapshot reduces reader/writer blocking. It is set after
-- creation while the database has no user workload.
ALTER DATABASE [AFS_CoreBanking] SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE [AFS_Payments] SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE [AFS_CustomerService] SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE [AFS_Audit] SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE [AFS_Reporting] SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE [AFS_Fraud] SET READ_COMMITTED_SNAPSHOT ON;
GO

PRINT N'AFS database creation/configuration complete.';
GO

SELECT name, recovery_model_desc, page_verify_option_desc, compatibility_level, state_desc
FROM sys.databases
WHERE name LIKE N'AFS[_]%'
ORDER BY name;
GO
