/*
  AFS-DBA-001
  Purpose: Create read models and masked views.
  Safety: Idempotent (CREATE OR ALTER).
  Note: Views are not a substitute for permissions. Grants are in the security scripts.
*/

USE [AFS_CoreBanking];
GO

CREATE OR ALTER VIEW customer.vw_CustomerProfile
AS
SELECT
    c.CustomerId,
    c.CustomerNumber,
    c.FirstName,
    c.LastName,
    c.CustomerStatus,
    c.RiskRating,
    CASE
        WHEN c.Email IS NULL THEN NULL
        ELSE LEFT(c.Email, 1) + N'***@***'
    END AS EmailMasked,
    CASE
        WHEN c.Phone IS NULL THEN NULL
        ELSE N'***' + RIGHT(c.Phone, 4)
    END AS PhoneMasked,
    c.CreatedAt
FROM customer.Customer AS c;
GO

CREATE OR ALTER VIEW account.vw_AccountSummary
AS
SELECT
    a.AccountId,
    a.AccountNumber,
    a.CustomerId,
    at.TypeCode AS AccountType,
    st.StatusCode AS AccountStatus,
    a.CurrencyCode,
    a.Balance,
    a.OpeningBalance,
    a.OverdraftLimit,
    a.Balance + a.OverdraftLimit AS AvailableBalance,
    a.PerTransferLimit,
    a.DailyTransferLimit,
    a.OpenedAt,
    a.ClosedAt
FROM account.Account AS a
JOIN reference.AccountType AS at ON at.AccountTypeId = a.AccountTypeId
JOIN reference.AccountStatus AS st ON st.AccountStatusId = a.AccountStatusId;
GO

CREATE OR ALTER VIEW account.vw_TransferProjection
AS
SELECT
    t.TransferId,
    t.RequestId,
    t.FromAccountId,
    t.ToAccountId,
    t.Amount,
    t.CurrencyCode,
    t.Status,
    t.Description,
    t.CorrelationId,
    t.CreatedAt,
    t.CompletedAt
FROM account.Transfer AS t;
GO

CREATE OR ALTER VIEW account.vw_TransferEventProjection
AS
SELECT
    e.TransferEventId,
    e.TransferId,
    e.EventType,
    e.EventData,
    e.Actor,
    e.CreatedAt
FROM account.TransferEvent AS e;
GO

CREATE OR ALTER VIEW audit.vw_AuditTimeline
AS
SELECT
    e.AuditEventId,
    e.EventType,
    e.EntityType,
    e.EntityId,
    e.Actor,
    e.CorrelationId,
    e.EventData,
    e.CreatedAt
FROM audit.AuditEvent AS e;
GO

USE [AFS_Payments];
GO

CREATE OR ALTER VIEW transfer.TransferProjection
AS
SELECT
    t.TransferId,
    t.RequestId,
    t.FromAccountId,
    t.ToAccountId,
    t.Amount,
    t.CurrencyCode,
    t.Status,
    t.Description,
    t.CorrelationId,
    t.CreatedAt,
    t.CompletedAt
FROM AFS_CoreBanking.account.vw_TransferProjection AS t;
GO

CREATE OR ALTER VIEW transfer.TransferEventProjection
AS
SELECT
    e.TransferEventId,
    e.TransferId,
    e.EventType,
    e.EventData,
    e.Actor,
    e.CreatedAt
FROM AFS_CoreBanking.account.vw_TransferEventProjection AS e;
GO

CREATE OR ALTER VIEW payment.vw_PaymentSummary
AS
SELECT
    p.PaymentId,
    p.PaymentReference,
    p.RequestId,
    p.DebitAccountId,
    p.BeneficiaryAccountId,
    p.BeneficiaryName,
    N'****' + RIGHT(p.BeneficiaryAccountNumber, 4) AS BeneficiaryAccountMasked,
    p.Amount,
    p.CurrencyCode,
    m.MethodCode AS PaymentMethod,
    s.StatusCode AS PaymentStatus,
    p.TransferId,
    p.FailureCode,
    p.FailureMessage,
    p.CreatedAt,
    p.ProcessedAt
FROM payment.Payment AS p
JOIN payment.PaymentMethod AS m ON m.PaymentMethodId = p.PaymentMethodId
JOIN payment.PaymentStatus AS s ON s.PaymentStatusId = p.PaymentStatusId;
GO

CREATE OR ALTER VIEW settlement.vw_SettlementSummary
AS
SELECT
    b.SettlementBatchId,
    b.BatchReference,
    b.SettlementDate,
    b.Status,
    COUNT(i.SettlementItemId) AS ItemCount,
    ISNULL(SUM(i.Amount), 0) AS TotalAmount,
    b.CreatedAt,
    b.ClosedAt
FROM settlement.SettlementBatch AS b
LEFT JOIN settlement.SettlementItem AS i
  ON i.SettlementBatchId = b.SettlementBatchId
GROUP BY b.SettlementBatchId, b.BatchReference, b.SettlementDate,
         b.Status, b.CreatedAt, b.ClosedAt;
GO

USE [AFS_Reporting];
GO

CREATE OR ALTER VIEW reporting.vw_DailyAccountSummary
AS
SELECT
    SummaryDate,
    AccountId,
    OpeningBalance,
    ClosingBalance,
    DebitTotal,
    CreditTotal,
    TransferCount
FROM reporting.DailyAccountSummary;
GO

CREATE OR ALTER VIEW reporting.vw_TransferVolume
AS
SELECT
    SummaryDate,
    CurrencyCode,
    TransferCount,
    TotalAmount
FROM reporting.TransferVolume;
GO

PRINT N'Views created.';
GO
