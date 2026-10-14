/*
============================================================================
 NHS PRESCRIPTIONS ANALYSIS - BOLTON
============================================================================
 Platform : Microsoft SQL Server 2017 or later (T-SQL)
 Data     : Extract of the NHS English Prescribing Data for practices in
            Bolton. Contains public sector information licensed under the
            Open Government Licence v3.0.
============================================================================
*/


-- ============================================================================
-- SECTION 1: DATABASE CREATION
-- ============================================================================

USE master;
GO

IF DB_ID('PrescriptionsDB') IS NOT NULL
BEGIN
    ALTER DATABASE PrescriptionsDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE PrescriptionsDB;
END;
GO

CREATE DATABASE PrescriptionsDB;
GO

USE PrescriptionsDB;
GO


-- ============================================================================
-- SECTION 2: TABLES
-- ============================================================================
-- Column names are kept exactly as they appear in the source CSV files.
-- QUANTITY and the cost columns hold non-integer values, so they use FLOAT.

CREATE TABLE Medical_Practice (
    PRACTICE_CODE  NVARCHAR(10)  NOT NULL,
    PRACTICE_NAME  NVARCHAR(100) NOT NULL,
    ADDRESS_1      NVARCHAR(100) NULL,
    ADDRESS_2      NVARCHAR(100) NULL,
    ADDRESS_3      NVARCHAR(100) NULL,
    ADDRESS_4      NVARCHAR(100) NULL,
    POSTCODE       NVARCHAR(10)  NULL
);

CREATE TABLE Drugs (
    BNF_CODE                      NVARCHAR(20)  NOT NULL,
    CHEMICAL_SUBSTANCE_BNF_DESCR  NVARCHAR(200) NOT NULL,
    BNF_DESCRIPTION               NVARCHAR(255) NOT NULL,
    BNF_CHAPTER_PLUS_CODE         NVARCHAR(100) NOT NULL
);

CREATE TABLE Prescriptions (
    PRESCRIPTION_CODE  INT           NOT NULL,
    PRACTICE_CODE      NVARCHAR(10)  NOT NULL,
    BNF_CODE           NVARCHAR(20)  NOT NULL,
    QUANTITY           FLOAT         NOT NULL,
    ITEMS              INT           NOT NULL,
    ACTUAL_COST        FLOAT         NOT NULL
);

CREATE TABLE [Prescription Summary] (
    PRACTICE_CODE   NVARCHAR(10)  NOT NULL,
    TOTAL_ITEMS     INT           NOT NULL,
    TOTAL_QUANTITY  FLOAT         NOT NULL,
    TOTAL_COST      FLOAT         NOT NULL,
    REPORT_MONTH    NVARCHAR(20)  NOT NULL
);
GO


-- ============================================================================
-- SECTION 3: LOAD THE CSV FILES
-- ============================================================================
-- Change the folder path to wherever the four CSV files are saved.
-- FORMAT = 'CSV' handles quoted values that contain commas, such as
-- addresses and drug descriptions.

BULK INSERT Medical_Practice
FROM 'C:\PrescriptionsData\Medical_Practice.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);

BULK INSERT Drugs
FROM 'C:\PrescriptionsData\Drugs.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);

BULK INSERT Prescriptions
FROM 'C:\PrescriptionsData\Prescriptions.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);

BULK INSERT [Prescription Summary]
FROM 'C:\PrescriptionsData\Prescriptions Summary.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
GO


-- ============================================================================
-- SECTION 4: KEYS AND INDEXES
-- ============================================================================
-- Keys are added after loading, which makes the bulk load faster, and then
-- guarantee every prescription points at a real practice and a real drug.

ALTER TABLE Medical_Practice
    ADD CONSTRAINT PK_Medical_Practice PRIMARY KEY (PRACTICE_CODE);

ALTER TABLE Drugs
    ADD CONSTRAINT PK_Drugs PRIMARY KEY (BNF_CODE);

ALTER TABLE Prescriptions
    ADD CONSTRAINT PK_Prescriptions PRIMARY KEY (PRESCRIPTION_CODE);

ALTER TABLE Prescriptions
    ADD CONSTRAINT FK_Prescriptions_Practice
        FOREIGN KEY (PRACTICE_CODE) REFERENCES Medical_Practice(PRACTICE_CODE);

ALTER TABLE Prescriptions
    ADD CONSTRAINT FK_Prescriptions_Drugs
        FOREIGN KEY (BNF_CODE) REFERENCES Drugs(BNF_CODE);

ALTER TABLE [Prescription Summary]
    ADD CONSTRAINT FK_PrescSummary_Practice
        FOREIGN KEY (PRACTICE_CODE) REFERENCES Medical_Practice(PRACTICE_CODE);

CREATE INDEX IX_Prescriptions_Practice ON Prescriptions(PRACTICE_CODE);
CREATE INDEX IX_Prescriptions_Drug     ON Prescriptions(BNF_CODE);
CREATE INDEX IX_Summary_Practice       ON [Prescription Summary](PRACTICE_CODE);
GO


-- ============================================================================
-- SECTION 5: ANALYSIS QUERIES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 5.1 Drugs supplied as tablets or capsules
-- ----------------------------------------------------------------------------
SELECT
    BNF_CODE,
    CHEMICAL_SUBSTANCE_BNF_DESCR,
    BNF_DESCRIPTION,
    BNF_CHAPTER_PLUS_CODE
FROM Drugs
WHERE BNF_DESCRIPTION LIKE '%tablet%'
   OR BNF_DESCRIPTION LIKE '%capsule%'
ORDER BY BNF_CHAPTER_PLUS_CODE, CHEMICAL_SUBSTANCE_BNF_DESCR;

-- ----------------------------------------------------------------------------
-- 5.2 Total units dispensed per prescription
-- Units in a pack (QUANTITY) multiplied by number of packs (ITEMS), rounded
-- to the nearest whole unit.
-- ----------------------------------------------------------------------------
SELECT
    PRESCRIPTION_CODE,
    PRACTICE_CODE,
    BNF_CODE,
    QUANTITY,
    ITEMS,
    ACTUAL_COST,
    CAST(ROUND(QUANTITY * ITEMS, 0) AS INT) AS TOTAL_QUANTITY_ROUNDED
FROM Prescriptions
ORDER BY PRESCRIPTION_CODE;

-- ----------------------------------------------------------------------------
-- 5.3 Most prescribed chemical substance per month
-- The Prescriptions table has no month column; only the practice-level
-- Prescription Summary is broken down by month. Joining the two on practice
-- alone would repeat every prescription once for every month that practice
-- reports, inflating the counts.
--
-- Instead, each practice's monthly item total is shared out across chemical
-- substances in proportion to that practice's prescribing mix:
--   estimated items for a substance in a month
--     = sum over practices of (practice's monthly items x substance's share
--       of that practice's items)
-- RANK keeps ties, so if two substances share first place both are shown.
-- ----------------------------------------------------------------------------
WITH PracticeSubstanceShare AS (
    SELECT
        p.PRACTICE_CODE,
        d.CHEMICAL_SUBSTANCE_BNF_DESCR,
        SUM(p.ITEMS) * 1.0
            / SUM(SUM(p.ITEMS)) OVER (PARTITION BY p.PRACTICE_CODE) AS ShareOfPracticeItems
    FROM Prescriptions AS p
    INNER JOIN Drugs AS d ON p.BNF_CODE = d.BNF_CODE
    GROUP BY p.PRACTICE_CODE, d.CHEMICAL_SUBSTANCE_BNF_DESCR
),
MonthlySubstance AS (
    SELECT
        ps.REPORT_MONTH,
        s.CHEMICAL_SUBSTANCE_BNF_DESCR,
        SUM(ps.TOTAL_ITEMS * s.ShareOfPracticeItems) AS EstimatedItems
    FROM [Prescription Summary] AS ps
    INNER JOIN PracticeSubstanceShare AS s ON s.PRACTICE_CODE = ps.PRACTICE_CODE
    GROUP BY ps.REPORT_MONTH, s.CHEMICAL_SUBSTANCE_BNF_DESCR
),
Ranked AS (
    SELECT
        REPORT_MONTH,
        CHEMICAL_SUBSTANCE_BNF_DESCR,
        EstimatedItems,
        RANK() OVER (PARTITION BY REPORT_MONTH ORDER BY EstimatedItems DESC) AS RankNum
    FROM MonthlySubstance
)
SELECT
    REPORT_MONTH,
    CHEMICAL_SUBSTANCE_BNF_DESCR             AS MostPrescribedSubstance,
    CAST(ROUND(EstimatedItems, 0) AS INT)    AS EstimatedItems
FROM Ranked
WHERE RankNum = 1
ORDER BY
    CASE REPORT_MONTH
        WHEN 'January'   THEN 1   WHEN 'February'  THEN 2
        WHEN 'March'     THEN 3   WHEN 'April'     THEN 4
        WHEN 'May'       THEN 5   WHEN 'June'      THEN 6
        WHEN 'July'      THEN 7   WHEN 'August'    THEN 8
        WHEN 'September' THEN 9   WHEN 'October'   THEN 10
        WHEN 'November'  THEN 11  WHEN 'December'  THEN 12
    END;

-- ----------------------------------------------------------------------------
-- 5.4 Prescribing volume and cost by BNF chapter
-- ----------------------------------------------------------------------------
SELECT
    d.BNF_CHAPTER_PLUS_CODE,
    COUNT(p.PRESCRIPTION_CODE)                AS NumberOfPrescriptions,
    CAST(AVG(p.ACTUAL_COST) AS DECIMAL(10,2)) AS AvgCost,
    CAST(MIN(p.ACTUAL_COST) AS DECIMAL(10,2)) AS MinCost,
    CAST(MAX(p.ACTUAL_COST) AS DECIMAL(10,2)) AS MaxCost
FROM Prescriptions AS p
INNER JOIN Drugs AS d ON p.BNF_CODE = d.BNF_CODE
GROUP BY d.BNF_CHAPTER_PLUS_CODE
ORDER BY d.BNF_CHAPTER_PLUS_CODE;

-- ----------------------------------------------------------------------------
-- 5.5 Most expensive prescription per practice, where it exceeds 4,000
-- The subquery finds each practice's highest cost and applies the threshold
-- before the join, then the outer query fetches the matching prescription.
-- ----------------------------------------------------------------------------
SELECT
    mp.PRACTICE_CODE,
    mp.PRACTICE_NAME,
    d.BNF_DESCRIPTION                     AS MostExpensiveDrug,
    d.BNF_CHAPTER_PLUS_CODE,
    CAST(p.ACTUAL_COST AS DECIMAL(10,2))  AS MostExpensivePrescriptionCost
FROM Prescriptions AS p
INNER JOIN Medical_Practice AS mp ON p.PRACTICE_CODE = mp.PRACTICE_CODE
INNER JOIN Drugs            AS d  ON p.BNF_CODE      = d.BNF_CODE
INNER JOIN (
    SELECT PRACTICE_CODE, MAX(ACTUAL_COST) AS MaxCost
    FROM Prescriptions
    GROUP BY PRACTICE_CODE
    HAVING MAX(ACTUAL_COST) > 4000
) AS MaxByPractice
    ON  p.PRACTICE_CODE = MaxByPractice.PRACTICE_CODE
    AND p.ACTUAL_COST   = MaxByPractice.MaxCost
ORDER BY p.ACTUAL_COST DESC;


-- ============================================================================
-- SECTION 6: FURTHER BUSINESS QUESTIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 6.1 Practice specialisation: share of Central Nervous System prescribing
-- Conditional counting with CASE inside SUM. Practices with 100 or fewer
-- prescriptions are excluded so small samples do not distort the ranking.
-- ----------------------------------------------------------------------------
SELECT
    mp.PRACTICE_CODE,
    mp.PRACTICE_NAME,
    COUNT(p.PRESCRIPTION_CODE) AS TotalPrescriptions,
    SUM(CASE WHEN d.BNF_CHAPTER_PLUS_CODE = '04: Central Nervous System' THEN 1 ELSE 0 END) AS CNS_Prescriptions,
    CAST(
        SUM(CASE WHEN d.BNF_CHAPTER_PLUS_CODE = '04: Central Nervous System' THEN 1.0 ELSE 0 END) * 100.0
        / NULLIF(COUNT(p.PRESCRIPTION_CODE), 0)
    AS DECIMAL(5,2)) AS CNS_Percentage
FROM Medical_Practice AS mp
INNER JOIN Prescriptions AS p ON mp.PRACTICE_CODE = p.PRACTICE_CODE
INNER JOIN Drugs         AS d ON p.BNF_CODE       = d.BNF_CODE
GROUP BY mp.PRACTICE_CODE, mp.PRACTICE_NAME
HAVING COUNT(p.PRESCRIPTION_CODE) > 100
ORDER BY CNS_Percentage DESC;

-- ----------------------------------------------------------------------------
-- 6.2 Bulk purchasing: top 20 drugs by units dispensed
-- EXISTS keeps only drugs prescribed by at least five different practices,
-- so the list reflects widely used drugs rather than one-off specialist use.
-- ----------------------------------------------------------------------------
SELECT TOP 20
    d.BNF_CODE,
    d.CHEMICAL_SUBSTANCE_BNF_DESCR                          AS ChemicalSubstance,
    d.BNF_DESCRIPTION                                       AS DrugDescription,
    d.BNF_CHAPTER_PLUS_CODE,
    SUM(p.ITEMS)                                            AS TotalPacksDispensed,
    CAST(ROUND(SUM(p.QUANTITY * p.ITEMS), 0) AS BIGINT)     AS TotalUnitsDispensed,
    CAST(SUM(p.ACTUAL_COST) AS DECIMAL(12,2))               AS TotalCost,
    COUNT(DISTINCT p.PRACTICE_CODE)                         AS NumberOfPractices
FROM Drugs AS d
INNER JOIN Prescriptions AS p ON d.BNF_CODE = p.BNF_CODE
WHERE EXISTS (
    SELECT 1
    FROM Prescriptions AS p2
    WHERE p2.BNF_CODE = d.BNF_CODE
    GROUP BY p2.BNF_CODE
    HAVING COUNT(DISTINCT p2.PRACTICE_CODE) >= 5
)
GROUP BY d.BNF_CODE, d.CHEMICAL_SUBSTANCE_BNF_DESCR, d.BNF_DESCRIPTION, d.BNF_CHAPTER_PLUS_CODE
ORDER BY TotalUnitsDispensed DESC;

-- ----------------------------------------------------------------------------
-- 6.3 Unusual costs: prescriptions more than three standard deviations above
-- the average for their BNF chapter (z-score above 3)
-- ----------------------------------------------------------------------------
SELECT
    p.PRESCRIPTION_CODE,
    mp.PRACTICE_NAME,
    d.BNF_DESCRIPTION,
    d.BNF_CHAPTER_PLUS_CODE,
    CAST(p.ACTUAL_COST         AS DECIMAL(10,2)) AS ActualCost,
    CAST(ch.AvgChapterCost     AS DECIMAL(10,2)) AS AvgForChapter,
    CAST(ch.StDevChapterCost   AS DECIMAL(10,2)) AS StDevForChapter,
    CAST((p.ACTUAL_COST - ch.AvgChapterCost) / NULLIF(ch.StDevChapterCost, 0) AS DECIMAL(6,2)) AS ZScore
FROM Prescriptions AS p
INNER JOIN Medical_Practice AS mp ON p.PRACTICE_CODE = mp.PRACTICE_CODE
INNER JOIN Drugs            AS d  ON p.BNF_CODE      = d.BNF_CODE
INNER JOIN (
    SELECT
        d2.BNF_CHAPTER_PLUS_CODE,
        AVG(p2.ACTUAL_COST)   AS AvgChapterCost,
        STDEV(p2.ACTUAL_COST) AS StDevChapterCost
    FROM Prescriptions AS p2
    INNER JOIN Drugs AS d2 ON p2.BNF_CODE = d2.BNF_CODE
    GROUP BY d2.BNF_CHAPTER_PLUS_CODE
) AS ch ON d.BNF_CHAPTER_PLUS_CODE = ch.BNF_CHAPTER_PLUS_CODE
WHERE (p.ACTUAL_COST - ch.AvgChapterCost) / NULLIF(ch.StDevChapterCost, 0) > 3
ORDER BY ZScore DESC;

-- ----------------------------------------------------------------------------
-- 6.4 Month-on-month spending: each month against the month before
-- The CTE gives each month a number, then a self join lines each month up
-- with the previous one. LEFT JOIN keeps January, which has no predecessor.
-- ----------------------------------------------------------------------------
WITH MonthlyCosts AS (
    SELECT
        REPORT_MONTH,
        CAST(SUM(TOTAL_COST) AS DECIMAL(12,2)) AS TotalMonthlyCost,
        CASE REPORT_MONTH
            WHEN 'January'   THEN  1  WHEN 'February'  THEN  2
            WHEN 'March'     THEN  3  WHEN 'April'     THEN  4
            WHEN 'May'       THEN  5  WHEN 'June'      THEN  6
            WHEN 'July'      THEN  7  WHEN 'August'    THEN  8
            WHEN 'September' THEN  9  WHEN 'October'   THEN 10
            WHEN 'November'  THEN 11  WHEN 'December'  THEN 12
        END AS MonthNumber
    FROM [Prescription Summary]
    GROUP BY REPORT_MONTH
)
SELECT
    curr.REPORT_MONTH                                            AS CurrentMonth,
    curr.TotalMonthlyCost                                        AS CurrentCost,
    prev.REPORT_MONTH                                            AS PreviousMonth,
    prev.TotalMonthlyCost                                        AS PreviousCost,
    CAST(curr.TotalMonthlyCost - prev.TotalMonthlyCost AS DECIMAL(12,2)) AS CostChange,
    CAST((curr.TotalMonthlyCost - prev.TotalMonthlyCost) * 100.0
         / NULLIF(prev.TotalMonthlyCost, 0) AS DECIMAL(5,2))     AS PctChange
FROM MonthlyCosts AS curr
LEFT JOIN MonthlyCosts AS prev ON curr.MonthNumber = prev.MonthNumber + 1
ORDER BY curr.MonthNumber;
GO
