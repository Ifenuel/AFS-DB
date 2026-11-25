/*
  AFS-DBA-001
  Purpose: Seed reference/controlled values.
  Safety: Idempotent (insert only when the code does not exist).
  Note: This is not synthetic customer data; it is static reference data.
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'US')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('US', N'United States');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'GB')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('GB', N'United Kingdom');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'CA')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('CA', N'Canada');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'DE')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('DE', N'Germany');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'FR')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('FR', N'France');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'NG')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('NG', N'Nigeria');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'ZA')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('ZA', N'South Africa');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'KE')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('KE', N'Kenya');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'AU')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('AU', N'Australia');
IF NOT EXISTS (SELECT 1 FROM reference.Country WHERE CountryCode = 'IN')
    INSERT reference.Country (CountryCode, CountryName) VALUES ('IN', N'India');
GO

IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'USD')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('USD', N'US Dollar', 2);
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'GBP')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('GBP', N'Pound Sterling', 2);
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'EUR')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('EUR', N'Euro', 2);
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'CAD')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('CAD', N'Canadian Dollar', 2);
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'NGN')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('NGN', N'Nigerian Naira', 2);
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'ZAR')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('ZAR', N'South African Rand', 2);
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'KES')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('KES', N'Kenyan Shilling', 2);
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'AUD')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('AUD', N'Australian Dollar', 2);
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'INR')
    INSERT reference.Currency (CurrencyCode, CurrencyName, MinorUnit) VALUES ('INR', N'Indian Rupee', 2);
GO

IF NOT EXISTS (SELECT 1 FROM reference.AccountType WHERE TypeCode = 'CHECKING')
    INSERT reference.AccountType (TypeCode, TypeName) VALUES ('CHECKING', N'Personal Checking');
IF NOT EXISTS (SELECT 1 FROM reference.AccountType WHERE TypeCode = 'SAVINGS')
    INSERT reference.AccountType (TypeCode, TypeName) VALUES ('SAVINGS', N'Personal Savings');
IF NOT EXISTS (SELECT 1 FROM reference.AccountType WHERE TypeCode = 'BUSINESS_CHECKING')
    INSERT reference.AccountType (TypeCode, TypeName) VALUES ('BUSINESS_CHECKING', N'Business Checking');
IF NOT EXISTS (SELECT 1 FROM reference.AccountType WHERE TypeCode = 'BUSINESS_SAVINGS')
    INSERT reference.AccountType (TypeCode, TypeName) VALUES ('BUSINESS_SAVINGS', N'Business Savings');
GO

IF NOT EXISTS (SELECT 1 FROM reference.AccountStatus WHERE StatusCode = 'ACTIVE')
    INSERT reference.AccountStatus (StatusCode, StatusName, AllowsTransfers) VALUES ('ACTIVE', N'Active', 1);
IF NOT EXISTS (SELECT 1 FROM reference.AccountStatus WHERE StatusCode = 'DORMANT')
    INSERT reference.AccountStatus (StatusCode, StatusName, AllowsTransfers) VALUES ('DORMANT', N'Dormant', 0);
IF NOT EXISTS (SELECT 1 FROM reference.AccountStatus WHERE StatusCode = 'FROZEN')
    INSERT reference.AccountStatus (StatusCode, StatusName, AllowsTransfers) VALUES ('FROZEN', N'Frozen', 0);
IF NOT EXISTS (SELECT 1 FROM reference.AccountStatus WHERE StatusCode = 'CLOSED')
    INSERT reference.AccountStatus (StatusCode, StatusName, AllowsTransfers) VALUES ('CLOSED', N'Closed', 0);
GO

USE [AFS_Payments];
GO
IF OBJECT_ID(N'payment.PaymentReferenceSequence', N'SO') IS NULL
    EXEC(N'CREATE SEQUENCE payment.PaymentReferenceSequence AS BIGINT START WITH 1 INCREMENT BY 1;');
GO
IF NOT EXISTS (SELECT 1 FROM payment.PaymentStatus WHERE StatusCode = 'PENDING')
    INSERT payment.PaymentStatus (StatusCode, StatusName, IsTerminal) VALUES ('PENDING', N'Pending', 0);
IF NOT EXISTS (SELECT 1 FROM payment.PaymentStatus WHERE StatusCode = 'COMPLETED')
    INSERT payment.PaymentStatus (StatusCode, StatusName, IsTerminal) VALUES ('COMPLETED', N'Completed', 1);
IF NOT EXISTS (SELECT 1 FROM payment.PaymentStatus WHERE StatusCode = 'FAILED')
    INSERT payment.PaymentStatus (StatusCode, StatusName, IsTerminal) VALUES ('FAILED', N'Failed', 1);
IF NOT EXISTS (SELECT 1 FROM payment.PaymentStatus WHERE StatusCode = 'CANCELLED')
    INSERT payment.PaymentStatus (StatusCode, StatusName, IsTerminal) VALUES ('CANCELLED', N'Cancelled', 1);
GO

IF NOT EXISTS (SELECT 1 FROM payment.PaymentMethod WHERE MethodCode = 'INTERNAL')
    INSERT payment.PaymentMethod (MethodCode, MethodName) VALUES ('INTERNAL', N'Internal transfer');
IF NOT EXISTS (SELECT 1 FROM payment.PaymentMethod WHERE MethodCode = 'ACH')
    INSERT payment.PaymentMethod (MethodCode, MethodName) VALUES ('ACH', N'ACH');
IF NOT EXISTS (SELECT 1 FROM payment.PaymentMethod WHERE MethodCode = 'WIRE')
    INSERT payment.PaymentMethod (MethodCode, MethodName) VALUES ('WIRE', N'Wire');
IF NOT EXISTS (SELECT 1 FROM payment.PaymentMethod WHERE MethodCode = 'CARD')
    INSERT payment.PaymentMethod (MethodCode, MethodName) VALUES ('CARD', N'Card payment');
GO

USE [AFS_CustomerService];
GO
IF NOT EXISTS (SELECT 1 FROM support.CaseCategory WHERE CategoryCode = 'ACCOUNT_ACCESS')
    INSERT support.CaseCategory (CategoryCode, CategoryName) VALUES ('ACCOUNT_ACCESS', N'Account access');
IF NOT EXISTS (SELECT 1 FROM support.CaseCategory WHERE CategoryCode = 'PAYMENT_ISSUE')
    INSERT support.CaseCategory (CategoryCode, CategoryName) VALUES ('PAYMENT_ISSUE', N'Payment issue');
IF NOT EXISTS (SELECT 1 FROM support.CaseCategory WHERE CategoryCode = 'FRAUD')
    INSERT support.CaseCategory (CategoryCode, CategoryName) VALUES ('FRAUD', N'Fraud concern');
IF NOT EXISTS (SELECT 1 FROM support.CaseCategory WHERE CategoryCode = 'STATEMENT')
    INSERT support.CaseCategory (CategoryCode, CategoryName) VALUES ('STATEMENT', N'Statement request');
IF NOT EXISTS (SELECT 1 FROM support.CaseCategory WHERE CategoryCode = 'OTHER')
    INSERT support.CaseCategory (CategoryCode, CategoryName) VALUES ('OTHER', N'Other');
GO

USE [AFS_Fraud];
GO
IF NOT EXISTS (SELECT 1 FROM fraud.FraudRule WHERE RuleCode = 'LARGE_TRANSFER')
    INSERT fraud.FraudRule (RuleCode, RuleName, ThresholdAmount, WindowMinutes)
    VALUES ('LARGE_TRANSFER', N'Transfer above high-value threshold', 10000.00, 60);
IF NOT EXISTS (SELECT 1 FROM fraud.FraudRule WHERE RuleCode = 'VELOCITY')
    INSERT fraud.FraudRule (RuleCode, RuleName, ThresholdAmount, WindowMinutes)
    VALUES ('VELOCITY', N'Multiple transfers in a short window', 5000.00, 15);
IF NOT EXISTS (SELECT 1 FROM fraud.FraudRule WHERE RuleCode = 'NEW_BENEFICIARY')
    INSERT fraud.FraudRule (RuleCode, RuleName, ThresholdAmount, WindowMinutes)
    VALUES ('NEW_BENEFICIARY', N'High-value transfer to a new beneficiary', 2500.00, 1440);
GO

PRINT N'Reference data seeded.';
GO
