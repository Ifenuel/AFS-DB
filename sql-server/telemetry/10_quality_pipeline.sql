/*
  AFS-DBA-001
  P-02 telemetry quality pipeline.

  Rules are derived from the tag metadata that already exists (unit, nominal
  range) rather than from hard-coded per-tag assumptions where possible.
  Quarantine is used instead of imputation: an invalid measurement is never
  turned into a plausible-looking number.
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE AFS_Archive;
GO

CREATE OR ALTER PROCEDURE telemetry.usp_ValidateStaging
    @RunId int
AS
BEGIN
    SET NOCOUNT ON;

    /* 1. duplicates: same tag, source and observed timestamp, later receipt loses */
    ;WITH ranked AS
    (
        SELECT StagingId,
               ROW_NUMBER() OVER (PARTITION BY TagCode, SourceId, ObservedAt
                                  ORDER BY ReceivedAt, StagingId) AS rn
        FROM telemetry.Staging
        WHERE RunId = @RunId AND Outcome IS NULL
    )
    UPDATE s
       SET Outcome = 'DUPLICATE',
           OutcomeDetail = 'same tag/source/timestamp already received'
    FROM telemetry.Staging s
    JOIN ranked r ON r.StagingId = s.StagingId
    WHERE r.rn > 1;

    INSERT INTO telemetry.Quarantine
        (RunId, StagingId, TagCode, SourceId, ObservedAt, RawValue, RawUnit, Reason, Detail)
    SELECT s.RunId, s.StagingId, s.TagCode, s.SourceId, s.ObservedAt, s.RawValue, s.RawUnit,
           'DUPLICATE', s.OutcomeDetail
    FROM telemetry.Staging s
    WHERE s.RunId = @RunId AND s.Outcome = 'DUPLICATE'
      AND NOT EXISTS (SELECT 1 FROM telemetry.Quarantine q WHERE q.StagingId = s.StagingId);

    /* 2. normalize units and test physical plausibility */
    ;WITH base AS
    (
        SELECT s.StagingId, s.TagCode, s.SourceId, s.ObservedAt, s.ReceivedAt,
               s.RawValue, s.RawUnit, t.TagId, t.Unit AS CanonicalUnit,
               t.NominalLow, t.NominalHigh,
               CASE
                   WHEN s.RawUnit = t.Unit THEN s.RawValue
                   WHEN t.TagCode = 'WELLHEAD_PRESS' AND s.RawUnit = 'kPa'  THEN s.RawValue / 100.0
                   WHEN t.TagCode = 'WELLHEAD_PRESS' AND s.RawUnit = 'psi'  THEN s.RawValue / 14.5038
                   WHEN t.TagCode = 'SEP_TEMP'      AND s.RawUnit = 'F'     THEN (s.RawValue - 32) * 5.0 / 9.0
                   WHEN t.TagCode = 'FLOW_RATE'     AND s.RawUnit = 'L/min' THEN s.RawValue / 16.6667
                   ELSE NULL
               END AS Converted,
               CASE
                   WHEN t.TagId IS NULL THEN 0
                   WHEN s.RawUnit = t.Unit THEN 1
                   WHEN t.TagCode = 'WELLHEAD_PRESS' AND s.RawUnit IN ('kPa','psi') THEN 1
                   WHEN t.TagCode = 'SEP_TEMP'      AND s.RawUnit = 'F' THEN 1
                   WHEN t.TagCode = 'FLOW_RATE'     AND s.RawUnit = 'L/min' THEN 1
                   ELSE 0
               END AS UnitRecognised
        FROM telemetry.Staging s
        LEFT JOIN telemetry.Tag t ON t.TagCode = s.TagCode
        WHERE s.RunId = @RunId AND s.Outcome IS NULL
    )
    UPDATE s
       SET Outcome = 'INVALID',
           OutcomeDetail = CASE
               WHEN b.TagId IS NULL THEN 'UNKNOWN_TAG'
               WHEN b.RawValue IS NULL THEN 'NULL_VALUE'
               WHEN b.UnitRecognised = 0 OR b.Converted IS NULL THEN 'UNIT_MISMATCH'
               WHEN b.Converted < b.NominalLow * 0.75 OR b.Converted > b.NominalHigh * 1.25 THEN 'OUT_OF_RANGE'
               ELSE NULL END
    FROM telemetry.Staging s
    JOIN base b ON b.StagingId = s.StagingId
    WHERE b.TagId IS NULL
       OR b.RawValue IS NULL
       OR b.UnitRecognised = 0
       OR b.Converted IS NULL
       OR b.Converted < b.NominalLow * 0.75
       OR b.Converted > b.NominalHigh * 1.25;

    INSERT INTO telemetry.Quarantine
        (RunId, StagingId, TagCode, SourceId, ObservedAt, RawValue, RawUnit, Reason, Detail)
    SELECT s.RunId, s.StagingId, s.TagCode, s.SourceId, s.ObservedAt, s.RawValue, s.RawUnit,
           CASE WHEN s.OutcomeDetail IN ('UNKNOWN_TAG','NULL_VALUE','UNIT_MISMATCH','OUT_OF_RANGE')
                THEN s.OutcomeDetail ELSE 'INVALID' END,
           CONCAT('raw=', ISNULL(CAST(s.RawValue AS varchar(30)), 'NULL'), ' ', ISNULL(s.RawUnit,''))
    FROM telemetry.Staging s
    WHERE s.RunId = @RunId AND s.Outcome = 'INVALID'
      AND NOT EXISTS (SELECT 1 FROM telemetry.Quarantine q WHERE q.StagingId = s.StagingId);

    /* 3. classify accepted rows: late arrival and out-of-order timestamps */
    ;WITH accepted AS
    (
        SELECT s.StagingId, s.TagCode, s.ObservedAt, s.ReceivedAt,
               CASE
                   WHEN s.RawUnit = t.Unit THEN s.RawValue
                   WHEN t.TagCode = 'WELLHEAD_PRESS' AND s.RawUnit = 'kPa'  THEN s.RawValue / 100.0
                   WHEN t.TagCode = 'WELLHEAD_PRESS' AND s.RawUnit = 'psi'  THEN s.RawValue / 14.5038
                   WHEN t.TagCode = 'SEP_TEMP'      AND s.RawUnit = 'F'     THEN (s.RawValue - 32) * 5.0 / 9.0
                   WHEN t.TagCode = 'FLOW_RATE'     AND s.RawUnit = 'L/min' THEN s.RawValue / 16.6667
               END AS Converted,
               t.TagId,
               MAX(s.ObservedAt) OVER (PARTITION BY s.TagCode ORDER BY s.StagingId
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS PreviousObserved
        FROM telemetry.Staging s
        JOIN telemetry.Tag t ON t.TagCode = s.TagCode
        WHERE s.RunId = @RunId AND s.Outcome IS NULL
    ),
    classified AS
    (
        SELECT a.*,
               CASE
                   WHEN a.PreviousObserved IS NOT NULL AND a.ObservedAt < a.PreviousObserved THEN 'VALID_OUT_OF_ORDER'
                   WHEN DATEDIFF_BIG(second, a.ObservedAt, a.ReceivedAt) > 5 THEN 'VALID_LATE'
                   ELSE 'VALID'
               END AS Verdict
        FROM accepted a
    )
    UPDATE s
       SET Outcome = c.Verdict,
           OutcomeDetail = CONCAT('converted=', CAST(c.Converted AS varchar(30)), ' ', t.Unit)
    FROM telemetry.Staging s
    JOIN classified c ON c.StagingId = s.StagingId
    JOIN telemetry.Tag t ON t.TagId = c.TagId;

    /* 4. promote accepted measurements into the historian */
    INSERT INTO telemetry.Reading (TagId, ObservedAt, Value, Quality, SourceRunId)
    SELECT t.TagId, s.ObservedAt, CAST(s.RawValue AS decimal(10,3)),
           CASE s.Outcome WHEN 'VALID_LATE' THEN 2 WHEN 'VALID_OUT_OF_ORDER' THEN 3 ELSE 1 END,
           s.RunId
    FROM telemetry.Staging s
    JOIN telemetry.Tag t ON t.TagCode = s.TagCode
    WHERE s.RunId = @RunId
      AND s.Outcome IN ('VALID','VALID_LATE','VALID_OUT_OF_ORDER')
      AND NOT EXISTS (
          SELECT 1 FROM telemetry.Reading r
          WHERE r.SourceRunId = s.RunId AND r.TagId = t.TagId AND r.ObservedAt = s.ObservedAt);

    /* the promoted rows must carry normalized values, not raw ones */
    UPDATE r
       SET Value = CAST(
             CASE
                 WHEN s.RawUnit = t.Unit THEN s.RawValue
                 WHEN t.TagCode = 'WELLHEAD_PRESS' AND s.RawUnit = 'kPa'  THEN s.RawValue / 100.0
                 WHEN t.TagCode = 'WELLHEAD_PRESS' AND s.RawUnit = 'psi'  THEN s.RawValue / 14.5038
                 WHEN t.TagCode = 'SEP_TEMP'      AND s.RawUnit = 'F'     THEN (s.RawValue - 32) * 5.0 / 9.0
                 WHEN t.TagCode = 'FLOW_RATE'     AND s.RawUnit = 'L/min' THEN s.RawValue / 16.6667
             END AS decimal(10,3))
    FROM telemetry.Reading r
    JOIN telemetry.Staging s
      ON s.RunId = r.SourceRunId AND s.TagCode = (SELECT TagCode FROM telemetry.Tag WHERE TagId = r.TagId)
     AND s.ObservedAt = r.ObservedAt
    JOIN telemetry.Tag t ON t.TagId = r.TagId
    WHERE r.SourceRunId = @RunId
      AND s.RawUnit <> t.Unit;

    SELECT Outcome, COUNT(*) AS rows FROM telemetry.Staging
    WHERE RunId = @RunId GROUP BY Outcome ORDER BY Outcome;
END
GO

/* Completeness: expected count derived from the run's configured interval and
   the elapsed window, not from a fixed assumption about how many samples exist.
   GapProbability = exp(-maxGap / interval): the chance of a gap that long from
   ordinary scheduling jitter. It is a simplified model, not the BISE method. */
CREATE OR ALTER PROCEDURE telemetry.usp_ScoreCompleteness
    @RunId int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @intervalMs int =
        ISNULL((SELECT IntervalMs FROM telemetry.CollectorRun WHERE RunId = @RunId), 1000);

    ;WITH deltas AS
    (
        SELECT r.TagId, t.TagCode, r.ObservedAt,
               DATEDIFF_BIG(millisecond,
                   LAG(r.ObservedAt) OVER (PARTITION BY r.TagId ORDER BY r.ObservedAt),
                   r.ObservedAt) AS gap_ms
        FROM telemetry.Reading r
        JOIN telemetry.Tag t ON t.TagId = r.TagId
        WHERE r.SourceRunId = @RunId
    ),
    agg AS
    (
        SELECT TagId, TagCode, COUNT(*) AS observed,
               MIN(ObservedAt) AS started, MAX(ObservedAt) AS ended,
               MAX(gap_ms) AS max_gap_ms
        FROM deltas GROUP BY TagId, TagCode
    )
    INSERT INTO telemetry.CompletenessScore
        (RunId, TagCode, IntervalStart, IntervalEnd, Observed, Expected,
         CompletenessRatio, MaxGapSeconds, GapProbability, Method)
    SELECT @RunId, a.TagCode, a.started, a.ended, a.observed,
           CAST(DATEDIFF_BIG(millisecond, a.started, a.ended) * 1.0 / @intervalMs + 1 AS decimal(10,2)),
           CAST(a.observed / (DATEDIFF_BIG(millisecond, a.started, a.ended) * 1.0 / @intervalMs + 1) AS decimal(6,4)),
           CAST(ISNULL(a.max_gap_ms, 0) / 1000.0 AS decimal(10,3)),
           CAST(EXP(-ISNULL(a.max_gap_ms, 0) * 1.0 / @intervalMs) AS decimal(8,6)),
           CONCAT('expected from ', @intervalMs, ' ms cadence; Poisson-style gap tail')
    FROM agg a;

    SELECT TagCode, Observed, Expected, CompletenessRatio, MaxGapSeconds, GapProbability
    FROM telemetry.CompletenessScore WHERE RunId = @RunId ORDER BY TagCode;
END
GO

/* Correct a reading without destroying the original. */
CREATE OR ALTER PROCEDURE telemetry.usp_CorrectReading
    @ReadingId bigint,
    @NewValue  decimal(10,3),
    @Reason    nvarchar(300),
    @Actor     nvarchar(128)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @old decimal(10,3) = (SELECT Value FROM telemetry.Reading WHERE ReadingId = @ReadingId);
    IF @old IS NULL THROW 50020, 'reading not found', 1;

    INSERT INTO telemetry.Correction (ReadingId, OldValue, NewValue, Reason, Actor)
    VALUES (@ReadingId, @old, @NewValue, @Reason, @Actor);

    UPDATE telemetry.Reading SET Value = @NewValue WHERE ReadingId = @ReadingId;

    SELECT @ReadingId AS ReadingId, @old AS OriginalValue, @NewValue AS CorrectedValue;
END
GO

CREATE OR ALTER PROCEDURE telemetry.usp_ResetQualityRun @RunId int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM telemetry.Correction WHERE ReadingId IN
        (SELECT ReadingId FROM telemetry.Reading WHERE SourceRunId = @RunId);
    DELETE FROM telemetry.Quarantine WHERE RunId = @RunId;
    DELETE FROM telemetry.Reading WHERE SourceRunId = @RunId;
    DELETE FROM telemetry.Staging WHERE RunId = @RunId;
    DELETE FROM telemetry.CompletenessScore WHERE RunId = @RunId;
    DELETE FROM telemetry.CollectorRun WHERE RunId = @RunId;
    SELECT 'reset' AS result;
END
GO

PRINT 'quality pipeline ready';
GO
