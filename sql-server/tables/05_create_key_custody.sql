/*
  AFS-DBA-001
  Purpose: Key custody registry for protectors that encrypt data.
  Safety: Idempotent (creates the table only when it is absent).
*/
/* Key custody registry. One row per protector that has ever encrypted data,
   including the ones that are retired but still needed to read old backups. */
SET NOCOUNT ON;
USE AFS_Compliance;
GO
IF OBJECT_ID('grc.KeyCustodyRecord') IS NULL
BEGIN
    CREATE TABLE grc.KeyCustodyRecord
    (
        KeyCustodyId      int           IDENTITY(1,1) NOT NULL,
        KeyName           sysname       NOT NULL,
        Thumbprint        char(40)      NOT NULL,
        Purpose           varchar(40)   NOT NULL,
        CreatedAt         datetime2(3)  NOT NULL CONSTRAINT DF_KeyCustody_CreatedAt DEFAULT SYSUTCDATETIME(),
        RetiredAt         datetime2(3)  NULL,
        CustodyPath       nvarchar(260) NOT NULL,
        RotationReason    varchar(200)  NULL,
        VerifiedRestoreAt datetime2(3)  NULL,
        CONSTRAINT PK_KeyCustodyRecord PRIMARY KEY CLUSTERED (KeyCustodyId),
        CONSTRAINT UQ_KeyCustodyRecord UNIQUE (KeyName, Thumbprint)
    );
    PRINT 'created grc.KeyCustodyRecord';
END
ELSE
    PRINT 'grc.KeyCustodyRecord already present';
GO
