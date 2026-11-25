/*
  AFS-DBA-001
  Purpose: Deterministic seed data for AFS_Identity, AFS_Compliance and AFS_Archive.
  Safety: Inserts only when a table is empty; safe to re-run.
  Prerequisites: The three governance databases and their tables exist.
  Run as: AFS_DBA.
*/
SET NOCOUNT ON;

/* ---------------- AFS_Identity ---------------- */
USE AFS_Identity;
GO

IF NOT EXISTS (SELECT 1 FROM iam.Principal)
BEGIN
    DECLARE @names TABLE (n int IDENTITY(1,1), full_name nvarchar(120), dept nvarchar(80));
    INSERT @names (full_name, dept) VALUES
      ('A. Adeyemi','Operations'),('B. Okoro','Payments'),('C. Balogun','Compliance'),
      ('D. Nwosu','Risk'),('E. Okafor','Technology'),('F. Ibrahim','Customer Service'),
      ('G. Adesina','Treasury'),('H. Musa','Audit'),('I. Chukwu','Payments'),
      ('J. Lawal','Operations'),('K. Eze','Technology'),('L. Bello','Compliance'),
      ('M. Ogunleye','Risk'),('N. Yakubu','Treasury'),('O. Obi','Audit'),
      ('P. Sanni','Payments'),('Q. Uche','Operations'),('R. Danjuma','Technology'),
      ('S. Aliyu','Compliance'),('T. Ekong','Risk'),('U. Ojo','Customer Service'),
      ('V. Kalu','Treasury'),('W. Bala','Audit'),('X. Oni','Payments'),
      ('Y. Adamu','Operations'),('Z. Ibe','Technology'),('AA. Olatunji','Compliance'),
      ('AB. Garba','Risk'),('AC. Nnaji','Treasury'),('AD. Sule','Audit'),
      ('AE. Fashola','Payments'),('AF. Udo','Operations'),('AG. Abubakar','Technology'),
      ('AH. Okonkwo','Compliance'),('AI. Sowore','Risk'),('AJ. Danladi','Customer Service'),
      ('AK. Ajayi','Treasury'),('AL. Nwankwo','Audit'),('AM. Hassan','Payments'),
      ('AN. Ogbonna','Operations'),('AO. Zakari','Technology'),('AP. Oluwole','Compliance'),
      ('AQ. Bassey','Risk'),('AR. Aminu','Treasury'),('AS. Chinedu','Audit'),
      ('AT. Oyinlola','Payments'),('AU. Salihu','Operations'),('AV. Ezeani','Technology'),
      ('AW. Oyelaran','Compliance'),('AX. Tukur','Risk'),('AY. Nkemdirim','Customer Service'),
      ('AZ. Ogunbiyi','Treasury'),('BA. Aliyu','Audit'),('BB. Okereke','Payments'),
      ('BC. Sanusi','Operations'),('BD. Ilori','Technology'),('BE. Nwabueze','Compliance'),
      ('BF. Oladipo','Risk'),('BG. Ahmed','Treasury'),('BH. Chukwuma','Audit');

    INSERT iam.Principal (PrincipalName, PrincipalType, Department, IsActive, CreatedAt)
    SELECT full_name, 'human', dept, 1, DATEADD(day, -(300 - n), '2026-01-01')
    FROM @names;

    INSERT iam.Principal (PrincipalName, PrincipalType, Department, IsActive, CreatedAt) VALUES
      ('svc.payments-api','service','Payments',1,'2026-01-05'),
      ('svc.reporting','service','Technology',1,'2026-01-05'),
      ('svc.etl-nightly','service','Technology',1,'2026-01-05');
END
GO

IF NOT EXISTS (SELECT 1 FROM iam.Role)
INSERT iam.Role (RoleName, Description, IsPrivileged) VALUES
  ('db_owner_app','Owns application objects in one database',1),
  ('app_read','Read access through approved views',0),
  ('app_write','Insert and update through procedures',0),
  ('reporting_reader','Read access to the warehouse only',0),
  ('fraud_analyst','Read fraud alerts and cases',0),
  ('compliance_officer','Read audit and compliance records',0),
  ('payments_operator','Post and settle payments',0),
  ('auditor_read','Read-only over audit evidence',0),
  ('backup_operator','Run and verify backups',1),
  ('support_read','Read customer records under ticket',0);
GO

IF NOT EXISTS (SELECT 1 FROM iam.RoleAssignment)
BEGIN
    ;WITH n AS (SELECT TOP (240) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT iam.RoleAssignment (PrincipalId, RoleId, GrantedAt, GrantedBy, ExpiresAt, IsActive)
    SELECT ((i * 7) % 60) + 1,
           ((i * 3) % 10) + 1,
           DATEADD(day, -(400 - i), '2026-01-01'),
           'access.office',
           CASE WHEN i % 9 = 0 THEN DATEADD(day, 90, '2026-01-01') ELSE NULL END,
           1
    FROM n;
END
GO

IF NOT EXISTS (SELECT 1 FROM iam.AccessRequest)
BEGIN
    /* One request per grant, except the last twelve: those arrived without an
       approval, which the reconciliation query is expected to surface. */
    ;WITH n AS (SELECT TOP (228) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT iam.AccessRequest (PrincipalId, RoleId, RequestedAt, BusinessJustification, Approver, ApprovedAt, Status)
    SELECT ra.PrincipalId,
           ra.RoleId,
           DATEADD(day, -2, ra.GrantedAt),
           CHOOSE((n.i % 4) + 1,
             'Temporary cover for quarter-end settlement run',
             'New joiner in the payments operations team',
             'Investigation support for a fraud case',
             'Reporting access for the monthly board pack'),
           CASE WHEN n.i % 5 = 0 THEN NULL ELSE 'line.manager' END,
           CASE WHEN n.i % 5 = 0 THEN NULL ELSE DATEADD(day, -1, ra.GrantedAt) END,
           CASE WHEN n.i % 5 = 0 THEN 'pending' WHEN n.i % 7 = 0 THEN 'rejected'
                WHEN n.i % 11 = 0 THEN 'expired' ELSE 'approved' END
    FROM n
    JOIN iam.RoleAssignment ra ON ra.RoleAssignmentId = n.i;
END
GO

IF NOT EXISTS (SELECT 1 FROM iam.AccessReview)
INSERT iam.AccessReview (ReviewPeriod, Scope, Reviewer, CompletedAt) VALUES
  ('2025-12-31','All production databases','head.of.audit','2026-01-09T16:00:00'),
  ('2026-03-31','All production databases','head.of.audit','2026-04-08T15:20:00'),
  ('2026-06-30','Privileged roles only','head.of.audit','2026-07-07T11:05:00'),
  ('2026-09-30','All production databases','head.of.audit','2026-10-06T14:40:00');
GO

IF NOT EXISTS (SELECT 1 FROM iam.AccessReviewDecision)
BEGIN
    ;WITH n AS (SELECT TOP (240) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT iam.AccessReviewDecision (AccessReviewId, RoleAssignmentId, Decision, DecidedAt, Note)
    SELECT ((i - 1) / 60) + 1,
           i,
           CASE WHEN i % 8 = 0 THEN 'revoke' ELSE 'retain' END,
           DATEADD(day, 1, '2026-10-05T09:00:00'),
           CASE WHEN i % 8 = 0 THEN 'No current business need' ELSE 'Confirmed with line manager' END
    FROM n;

    /* The latest review actually acts on its revocations. */
    UPDATE ra SET IsActive = 0
    FROM iam.RoleAssignment ra
    JOIN iam.AccessReviewDecision d ON d.RoleAssignmentId = ra.RoleAssignmentId
    WHERE d.AccessReviewId = 4 AND d.Decision = 'revoke';
END
GO

IF NOT EXISTS (SELECT 1 FROM iam.SessionEvent)
BEGIN
    ;WITH n AS (SELECT TOP (3000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT iam.SessionEvent (PrincipalId, DatabaseName, StartedAt, EndedAt, ClientHost, AuthMethod)
    SELECT ((i * 13) % 60) + 1,
           CHOOSE((i % 9) + 1,'AFS_CoreBanking','AFS_Payments','AFS_Fraud','AFS_Audit',
                  'AFS_CustomerService','AFS_Reporting','AFS_Identity','AFS_Compliance','AFS_Archive'),
           DATEADD(minute, -(i * 9), '2026-11-25T08:00:00'),
           DATEADD(minute, -(i * 9) + (5 + i % 40), '2026-11-25T08:00:00'),
           'WS-' + RIGHT('0000' + CAST((i % 120) + 1 AS varchar(4)), 4),
           CASE WHEN i % 20 = 0 THEN 'sql' WHEN i % 15 = 0 THEN 'token' ELSE 'windows' END
    FROM n;
END
GO

/* ---------------- AFS_Compliance ---------------- */
USE AFS_Compliance;
GO

IF NOT EXISTS (SELECT 1 FROM grc.Obligation)
INSERT grc.Obligation (Framework, Reference, Requirement) VALUES
  ('DORA','Art.11','Test backup and restoration procedures at least annually'),
  ('DORA','Art.8','Identify and document all ICT dependencies and single points of failure'),
  ('DORA','Art.9','Protect confidentiality and integrity of data at rest and in transit'),
  ('DORA','Art.12','Maintain an up-to-date register of ICT third-party providers'),
  ('DORA','Art.17','Establish incident management with root-cause analysis'),
  ('DORA','Art.28','Retain logs sufficient to reconstruct incidents'),
  ('CBN','Sec.4.2','Localise payment data within the jurisdiction'),
  ('CBN','Sec.6.1','Enforce least privilege for application database identities'),
  ('CBN','Sec.6.4','Retain transaction records for at least five years'),
  ('CBN','Sec.7.3','Encrypt backups that leave the production environment'),
  ('CBN','Sec.9.1','Report cyber incidents within 24 hours'),
  ('CBN','Sec.10.2','Review user access at least quarterly'),
  ('PCI DSS','Req.3','Protect stored account data'),
  ('PCI DSS','Req.7','Restrict access by business need to know'),
  ('PCI DSS','Req.8','Identify users and authenticate all access'),
  ('PCI DSS','Req.10','Log and monitor all access to system components'),
  ('PCI DSS','Req.10.5','Retain audit logs for at least twelve months'),
  ('PCI DSS','Req.11','Test security controls and processes regularly'),
  ('ISO 27001','A.5.15','Control access to information and assets'),
  ('ISO 27001','A.8.15','Record, store and protect log information'),
  ('ISO 27001','A.8.13','Protect information during backup'),
  ('NIST CSF','PR.AA','Identity management and access control are enforced'),
  ('NIST CSF','PR.DS','Data at rest and in transit is protected'),
  ('NIST CSF','DE.CM','Monitoring detects adverse events');
GO

IF NOT EXISTS (SELECT 1 FROM grc.Control)
BEGIN
    ;WITH n AS (SELECT TOP (30) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects)
    INSERT grc.Control (ControlCode, Title, ControlType, Owner, Frequency)
    SELECT 'DB-' + RIGHT('00' + CAST(i AS varchar(2)), 2),
           CHOOSE((i % 10) + 1,
             'Encrypted backup media requiring the certificate',
             'Least-privilege application identity',
             'Quarterly access review with decisions recorded',
             'Change rehearsal with rollback',
             'Scheduled log backup with age alerting',
             'Failed-login capture with client detail',
             'Restore verification with CHECKSUM',
             'Reporting separated from operational databases',
             'Privileged session recording',
             'Tamper-evident archive hash chain'),
           CASE WHEN i % 3 = 0 THEN 'detective' ELSE 'preventive' END,
           CHOOSE((i % 5) + 1,'database.team','security.team','compliance.team','operations','audit'),
           CHOOSE((i % 5) + 1,'daily','monthly','quarterly','annual','continuous')
    FROM n;
END
GO

IF NOT EXISTS (SELECT 1 FROM grc.ControlObligation)
BEGIN
    ;WITH n AS (SELECT TOP (60) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT grc.ControlObligation (ControlObligationId, ControlId, ObligationId)
    SELECT i, ((i - 1) % 30) + 1, ((i * 7) % 24) + 1
    FROM n;
END
GO

IF NOT EXISTS (SELECT 1 FROM grc.ControlTest)
BEGIN
    ;WITH n AS (SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT grc.ControlTest (ControlId, TestedAt, Tester, Result, SampleSize, Exceptions, EvidenceRef)
    SELECT ((i - 1) % 30) + 1,
           DATEADD(day, -(360 - i * 3), '2026-11-25T00:00:00'),
           'audit.engine',
           CASE WHEN i % 10 = 0 THEN 'fail' ELSE 'pass' END,
           5 + (i % 46),
           CASE WHEN i % 10 = 0 THEN 1 + (i % 3) ELSE 0 END,
           'capture-' + RIGHT('0000' + CAST(i AS varchar(4)), 4)
    FROM n;
END
GO

IF NOT EXISTS (SELECT 1 FROM grc.Finding)
BEGIN
    ;WITH fails AS (
        SELECT ControlTestId, ROW_NUMBER() OVER (ORDER BY TestedAt) AS rn
        FROM grc.ControlTest WHERE Result = 'fail'
    )
    INSERT grc.Finding (ControlTestId, Severity, Description, RaisedAt, Status)
    SELECT t.ControlTestId,
           CHOOSE((f.rn % 4) + 1,'critical','high','medium','low'),
           CHOOSE((f.rn % 5) + 1,
             'Sample contained a grant with no matching approval',
             'Backup age exceeded the alert threshold before the job ran',
             'Reporting query referenced an operational database',
             'Access review decision recorded after the revocation',
             'Log backup gap of more than one hour detected'),
           DATEADD(day, 2, t.TestedAt),
           CASE WHEN f.rn <= 6 THEN 'open' WHEN f.rn <= 10 THEN 'remediating' ELSE 'closed' END
    FROM fails f
    JOIN grc.ControlTest t ON t.ControlTestId = f.ControlTestId
    WHERE f.rn <= 25;
END
GO

IF NOT EXISTS (SELECT 1 FROM grc.Remediation)
BEGIN
    ;WITH f AS (SELECT FindingId, status, ROW_NUMBER() OVER (ORDER BY FindingId) AS rn
                FROM grc.Finding)
    INSERT grc.Remediation (FindingId, Action, Owner, DueAt, ClosedAt)
    SELECT FindingId,
           'Remediate: ' + CHOOSE((rn % 3) + 1,
             'remove the unapproved grant and record the approval retroactively',
             'move the job window and lower the alert threshold',
             'repoint the report to the warehouse and re-test the plan'),
           'database.team',
           DATEADD(day, 30, '2026-06-01'),
           CASE WHEN status = 'closed' THEN DATEADD(day, 21, '2026-06-01') ELSE NULL END
    FROM f
    WHERE rn <= 20;
END
GO

/* ---------------- AFS_Archive ---------------- */
USE AFS_Archive;
GO

IF NOT EXISTS (SELECT 1 FROM retention.RetentionPolicy)
INSERT retention.RetentionPolicy (PolicyName, DataClass, RetentionMonths, LegalBasis) VALUES
  ('TransactionLedger','Financial ledger',84,'CBN 5-year minimum plus dispute window'),
  ('PaymentRecords','Card and transfer records',120,'PCI DSS Req.3 and scheme rules'),
  ('CustomerKYC','Identity documents and KYC',60,'CBN customer due diligence'),
  ('AuditTrail','Security audit events',24,'PCI DSS Req.10.5'),
  ('AccessReview','Review decisions and evidence',36,'DORA Art.11 evidence'),
  ('SessionLogs','Privileged session records',24,'NIST CSF PR.AA monitoring');
GO

IF NOT EXISTS (SELECT 1 FROM retention.ArchivedRecord)
BEGIN
    DECLARE @i int = 1, @prev char(64) = REPLICATE('0', 64), @payload nvarchar(400),
            @hash char(64), @when datetime2(3);
    WHILE @i <= 2000
    BEGIN
        SET @when = DATEADD(minute, -(@i * 7), '2026-11-25T00:00:00');
        SET @payload = CONCAT('AFS_CoreBanking|account.AccountLedgerEntry|L', @i, '|',
                              CONVERT(varchar(33), @when, 126));
        SET @hash = CONVERT(char(64), HASHBYTES('SHA2_256', @prev + @payload), 2);
        INSERT retention.ArchivedRecord
            (SourceDatabase, SourceTable, RecordKey, PayloadHash, PreviousHash, ArchivedAt, RetentionPolicyId, IsPurged)
        VALUES ('AFS_CoreBanking','account.AccountLedgerEntry', CONCAT('L', @i), @hash, @prev, @when,
                ((@i - 1) % 6) + 1, 0);
        SET @prev = @hash;
        SET @i += 1;
    END
END
GO

IF NOT EXISTS (SELECT 1 FROM retention.LegalHold)
INSERT retention.LegalHold (MatterReference, Custodian, PlacedAt, ReleasedAt) VALUES
  ('LIT-2026-014','legal.counsel','2026-03-02T10:00:00', NULL),
  ('REG-2026-007','compliance.office','2026-07-19T09:30:00', NULL),
  ('LIT-2025-031','legal.counsel','2025-11-04T08:15:00','2026-04-30T17:00:00');
GO

IF NOT EXISTS (SELECT 1 FROM retention.LegalHoldRecord)
BEGIN
    ;WITH picked AS (
        SELECT ArchivedRecordId, ROW_NUMBER() OVER (ORDER BY ArchivedRecordId) AS rn
        FROM retention.ArchivedRecord
    )
    INSERT retention.LegalHoldRecord (LegalHoldId, ArchivedRecordId)
    SELECT CASE WHEN rn <= 40 THEN 1 WHEN rn <= 80 THEN 2 ELSE 3 END, ArchivedRecordId
    FROM picked WHERE rn <= 120;
END
GO

IF NOT EXISTS (SELECT 1 FROM retention.PurgeRun)
BEGIN
    ;WITH n AS (SELECT TOP (12) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects)
    INSERT retention.PurgeRun (RunAt, RetentionPolicyId, Candidates, Purged, BlockedByHold)
    SELECT DATEADD(month, -(12 - i), '2026-11-01T02:00:00'),
           ((i - 1) % 6) + 1,
           40 + i * 3,
           35 + i * 3,
           5
    FROM n;
END
GO
