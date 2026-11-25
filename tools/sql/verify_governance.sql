/* Verification for the three governance databases: structure, seeded volume,
   hash-chain integrity and a deliberate tamper that must be detected. */
SET NOCOUNT ON;

PRINT '=== estate ==='
SELECT CAST(name AS varchar(30)) AS database_name,
       CAST(SUM(size) * 8.0 / 1024 AS decimal(10,1)) AS size_mb
FROM sys.master_files
WHERE database_id > 4 AND name NOT LIKE '%[_]log'
GROUP BY name
ORDER BY name;

PRINT ''
PRINT '=== tables and foreign keys per database ==='
GO

SELECT 'AFS_Identity' AS database_name,
       (SELECT COUNT(*) FROM AFS_Identity.sys.tables WHERE type = 'U') AS tables,
       (SELECT COUNT(*) FROM AFS_Identity.sys.foreign_keys) AS foreign_keys
UNION ALL
SELECT 'AFS_Compliance',
       (SELECT COUNT(*) FROM AFS_Compliance.sys.tables WHERE type = 'U'),
       (SELECT COUNT(*) FROM AFS_Compliance.sys.foreign_keys)
UNION ALL
SELECT 'AFS_Archive',
       (SELECT COUNT(*) FROM AFS_Archive.sys.tables WHERE type = 'U'),
       (SELECT COUNT(*) FROM AFS_Archive.sys.foreign_keys);
GO

PRINT ''
PRINT '=== seeded volume ==='
SELECT 'iam.Principal' AS object_name, COUNT_BIG(*) AS rows FROM AFS_Identity.iam.Principal
UNION ALL SELECT 'iam.Role', COUNT_BIG(*) FROM AFS_Identity.iam.Role
UNION ALL SELECT 'iam.RoleAssignment', COUNT_BIG(*) FROM AFS_Identity.iam.RoleAssignment
UNION ALL SELECT 'iam.AccessRequest', COUNT_BIG(*) FROM AFS_Identity.iam.AccessRequest
UNION ALL SELECT 'iam.AccessReview', COUNT_BIG(*) FROM AFS_Identity.iam.AccessReview
UNION ALL SELECT 'iam.AccessReviewDecision', COUNT_BIG(*) FROM AFS_Identity.iam.AccessReviewDecision
UNION ALL SELECT 'iam.SessionEvent', COUNT_BIG(*) FROM AFS_Identity.iam.SessionEvent
UNION ALL SELECT 'grc.Obligation', COUNT_BIG(*) FROM AFS_Compliance.grc.Obligation
UNION ALL SELECT 'grc.Control', COUNT_BIG(*) FROM AFS_Compliance.grc.Control
UNION ALL SELECT 'grc.ControlObligation', COUNT_BIG(*) FROM AFS_Compliance.grc.ControlObligation
UNION ALL SELECT 'grc.ControlTest', COUNT_BIG(*) FROM AFS_Compliance.grc.ControlTest
UNION ALL SELECT 'grc.Finding', COUNT_BIG(*) FROM AFS_Compliance.grc.Finding
UNION ALL SELECT 'grc.Remediation', COUNT_BIG(*) FROM AFS_Compliance.grc.Remediation
UNION ALL SELECT 'retention.ArchivedRecord', COUNT_BIG(*) FROM AFS_Archive.retention.ArchivedRecord
UNION ALL SELECT 'retention.LegalHoldRecord', COUNT_BIG(*) FROM AFS_Archive.retention.LegalHoldRecord;
GO

PRINT ''
PRINT '=== governance questions the model answers ==='
SELECT 'privileged grants still active' AS question, COUNT(*) AS answer
FROM AFS_Identity.iam.RoleAssignment ra
JOIN AFS_Identity.iam.Role r ON r.RoleId = ra.RoleId
WHERE r.IsPrivileged = 1 AND ra.IsActive = 1
UNION ALL
SELECT 'assignments revoked by the latest review', COUNT(*)
FROM AFS_Identity.iam.AccessReviewDecision d
WHERE d.AccessReviewId = 4 AND d.Decision = 'revoke'
UNION ALL
SELECT 'grants with no matching access request', COUNT(*)
FROM AFS_Identity.iam.RoleAssignment ra
WHERE NOT EXISTS (SELECT 1 FROM AFS_Identity.iam.AccessRequest ar
                  WHERE ar.PrincipalId = ra.PrincipalId AND ar.RoleId = ra.RoleId)
UNION ALL
SELECT 'controls with no obligation mapped', COUNT(*)
FROM AFS_Compliance.grc.Control c
WHERE NOT EXISTS (SELECT 1 FROM AFS_Compliance.grc.ControlObligation m WHERE m.ControlId = c.ControlId)
UNION ALL
SELECT 'controls failing their last test', COUNT(*)
FROM AFS_Compliance.grc.Control c
WHERE EXISTS (
    SELECT 1 FROM AFS_Compliance.grc.ControlTest t
    WHERE t.ControlId = c.ControlId
      AND t.TestedAt = (SELECT MAX(t2.TestedAt) FROM AFS_Compliance.grc.ControlTest t2 WHERE t2.ControlId = c.ControlId)
      AND t.Result = 'fail')
UNION ALL
SELECT 'open high or critical findings', COUNT(*)
FROM AFS_Compliance.grc.Finding WHERE Status = 'open' AND Severity IN ('high','critical')
UNION ALL
SELECT 'archived records under legal hold', COUNT(*)
FROM AFS_Archive.retention.LegalHoldRecord h
JOIN AFS_Archive.retention.LegalHold l ON l.LegalHoldId = h.LegalHoldId
WHERE l.ReleasedAt IS NULL
UNION ALL
SELECT 'purge runs blocked by a hold', SUM(BlockedByHold)
FROM AFS_Archive.retention.PurgeRun;
GO

PRINT ''
PRINT '=== archive hash chain ==='
SELECT COUNT(*) AS broken_links
FROM (
    SELECT PreviousHash, LAG(PayloadHash) OVER (ORDER BY ArchivedRecordId) AS prior
    FROM AFS_Archive.retention.ArchivedRecord
) x
WHERE prior IS NOT NULL AND PreviousHash <> prior;
GO

SELECT COUNT(*) AS payload_mismatches
FROM AFS_Archive.retention.ArchivedRecord
WHERE PayloadHash <> CONVERT(char(64), HASHBYTES('SHA2_256',
        PreviousHash + CONCAT(SourceDatabase, '|', SourceTable, '|', RecordKey, '|',
                              CONVERT(varchar(33), ArchivedAt, 126))), 2);
GO

PRINT ''
PRINT '=== tamper test: alter one stored hash inside a transaction ==='
BEGIN TRANSACTION;
UPDATE AFS_Archive.retention.ArchivedRecord
SET PayloadHash = REPLICATE('A', 64)
WHERE ArchivedRecordId = 1000;

SELECT COUNT(*) AS mismatches_after_tamper
FROM AFS_Archive.retention.ArchivedRecord
WHERE PayloadHash <> CONVERT(char(64), HASHBYTES('SHA2_256',
        PreviousHash + CONCAT(SourceDatabase, '|', SourceTable, '|', RecordKey, '|',
                              CONVERT(varchar(33), ArchivedAt, 126))), 2);

ROLLBACK TRANSACTION;
PRINT 'rolled back: the evidence is unchanged';

SELECT COUNT(*) AS mismatches_after_rollback
FROM AFS_Archive.retention.ArchivedRecord
WHERE PayloadHash <> CONVERT(char(64), HASHBYTES('SHA2_256',
        PreviousHash + CONCAT(SourceDatabase, '|', SourceTable, '|', RecordKey, '|',
                              CONVERT(varchar(33), ArchivedAt, 126))), 2);
GO
