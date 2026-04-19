-- =============================================================================
-- DATA EXPLORATION: Financial & Economic Indicators
-- =============================================================================
-- Project: US Labor Market Monitor — Conversational BI with Cortex Analyst
--
-- Dataset: Cybersyn Financial & Economic Indicators (free Snowflake Marketplace)
-- Database: SNOWFLAKE_PUBLIC_DATA_FREE
-- Schema:   PUBLIC_DATA_FREE
-- Tables:
--   FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES  (dimension — describes variables)
--   FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES  (fact — values over time by geo)
--   GEOGRAPHY_INDEX                           (lookup — maps GEO_ID to names)
--
-- This file walks through the data exploration that informed the semantic
-- model. Inline comments document the observations that shaped each decision.
-- =============================================================================


-- =============================================================================
-- PART 1: Data landscape — how big, how deep, how wide?
-- =============================================================================

-- Q1: Row counts and date range
SELECT
    (SELECT COUNT(*) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES) AS attribute_rows,
    (SELECT COUNT(*) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES) AS timeseries_rows,
    (SELECT MIN(DATE) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES) AS earliest_date,
    (SELECT MAX(DATE) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES) AS latest_date;

-- Observation: ~164K attribute rows, tens of millions of timeseries rows,
-- covering 1939-2025. Massive dataset — we'll need a focused scope.


-- =============================================================================
-- PART 2: What measures exist? What's the data really about?
-- =============================================================================

-- Q2: Top measures by variable count
SELECT MEASURE, COUNT(*) AS variable_count
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES
GROUP BY MEASURE
ORDER BY variable_count DESC
LIMIT 30;

-- Observation: Dominated by labor-market measures — Employment (25K),
-- Hours At Work (8.7K), Employment Level (7.9K), Unemployment (4.4K),
-- Hourly Earnings (4.1K), Unemployment Rate (4K). This is BLS labor data
-- with some financial accounts mixed in, not a general "finance &
-- economics" dataset.


-- Q3: Frequency, unit, and seasonal adjustment distributions
SELECT FREQUENCY, COUNT(*) AS cnt
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES
GROUP BY FREQUENCY ORDER BY cnt DESC;
-- Result: Annual (63K), Monthly (50K), Quarterly (50K), Weekly (1.5K),
-- Weekdays (143), Daily (39), Bi-Weekly (1).

SELECT SEASONALLY_ADJUSTED, COUNT(*) AS cnt
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES
GROUP BY SEASONALLY_ADJUSTED ORDER BY cnt DESC;
-- Result: Not seasonally adjusted (134K) vs Seasonally adjusted (30K).
-- CRITICAL: every measure exists in BOTH variants. Queries must filter
-- on this column or they'll return duplicate rows.


-- =============================================================================
-- PART 3: Geography — who's in this data?
-- =============================================================================

-- Q4: How many geographies, what do top ones look like?
SELECT COUNT(DISTINCT GEO_ID) AS total_geos
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES;
-- Result: 7,219 distinct geographies.

SELECT GEO_ID, COUNT(*) AS row_count
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES
GROUP BY GEO_ID
ORDER BY row_count DESC
LIMIT 15;
-- Result: country/USA dominates (31.5M rows), then US states (geoId/06 = California,
-- geoId/36 = New York, geoId/48 = Texas, etc.). Many counties, cities, metros too.
-- Decision: scope to country/USA + 50 states only. GEO_IDs are FIPS codes —
-- must join to GEOGRAPHY_INDEX for human-readable names.


-- Q5: Geography levels available in the GEOGRAPHY_INDEX table
SELECT LEVEL, COUNT(*) AS cnt
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.GEOGRAPHY_INDEX
GROUP BY LEVEL
ORDER BY cnt DESC
LIMIT 10;
-- Result: CensusBlockGroup (291K), CensusTract (111K), City (50K),
-- CensusZipCodeTabulationArea (41K), County (3.2K), State (69),
-- Country (264). The "State" level has 69 rows (US states + territories +
-- Canadian provinces). For our scope, filter on State level + geoId/ prefix.


-- =============================================================================
-- PART 4: Join integrity — can we trust the data?
-- =============================================================================

-- Q6: Are there any orphan variables in the timeseries? (Expect 0)
SELECT COUNT(DISTINCT t.VARIABLE) AS orphan_variables
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES t
LEFT JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES a
    ON t.VARIABLE = a.VARIABLE
WHERE a.VARIABLE IS NULL;
-- Result: 0 orphan variables. Clean join.

-- Q7: Is VARIABLE unique in the attributes table? (Expect no rows)
SELECT VARIABLE, COUNT(*) AS cnt
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES
GROUP BY VARIABLE
HAVING cnt > 1
LIMIT 5;
-- Result: no rows returned — VARIABLE is unique (1:many with timeseries).
-- Safe to use as the join key without fear of row explosion.


-- =============================================================================
-- PART 5: Source decision — why focus on Bureau of Labor Statistics?
-- =============================================================================

-- Q8: All data sources and their coverage
SELECT
    RELEASE_SOURCE,
    COUNT(DISTINCT MEASURE) AS measure_count,
    COUNT(DISTINCT VARIABLE) AS variable_count
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES
GROUP BY RELEASE_SOURCE
ORDER BY variable_count DESC;

-- Result: BLS (92K vars), Federal Reserve (44K), BEA (19K), Census (6.7K),
-- CFPB (1.4K), U. of Michigan (358), smaller sources.
-- Decision: restrict to BLS. Coherent labor story, richest state-level
-- coverage, cleaner semantic model than mixing 9 sources.


-- =============================================================================
-- PART 6: Which BLS measures work at state level?
-- =============================================================================

-- Q9: BLS measures available at state level (30+ states, monthly)
SELECT
    a.MEASURE,
    COUNT(DISTINCT t.GEO_ID) AS state_count,
    COUNT(*) AS rows_count
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES a
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES t
    ON a.VARIABLE = t.VARIABLE
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.GEOGRAPHY_INDEX g
    ON t.GEO_ID = g.GEO_ID
WHERE a.RELEASE_SOURCE = 'Bureau of Labor Statistics'
  AND g.LEVEL = 'State' AND g.GEO_ID LIKE 'geoId/%'
  AND a.FREQUENCY = 'Monthly'
GROUP BY a.MEASURE
HAVING state_count >= 30
ORDER BY rows_count DESC
LIMIT 25;

-- This query drove the final measure selection for the semantic model:
-- - All Employees (by industry) — 53 states, 2.4M rows
-- - Unemployment Rate, Unemployment, Employment, Labor Force — 52 states
-- - Avg Hourly/Weekly Earnings, Avg Weekly Hours — 52 states
-- - JOLTS: Job Openings, Hires, Quits, Layoffs, Total Separations — 51 states
-- - Labor Force Participation Rate, Employment-Population Ratio — 51 states


-- Q10: BLS frequencies at state level
SELECT a.FREQUENCY, COUNT(DISTINCT a.MEASURE) AS measure_count, COUNT(*) AS rows_count
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES a
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES t ON a.VARIABLE = t.VARIABLE
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.GEOGRAPHY_INDEX g ON t.GEO_ID = g.GEO_ID
WHERE a.RELEASE_SOURCE = 'Bureau of Labor Statistics'
  AND g.LEVEL = 'State' AND g.GEO_ID LIKE 'geoId/%'
GROUP BY a.FREQUENCY
ORDER BY rows_count DESC;
-- Result: Monthly (22 measures, 3.8M rows), Annual (20 measures, 222K rows).
-- No Weekly at state level. Decision: support both Monthly + Annual.


-- =============================================================================
-- PART 7: Value distribution — understanding scales and outliers
-- =============================================================================

-- Q11: Value stats per measure (for understanding chart scales)
SELECT
    a.MEASURE,
    COUNT(*) AS rows_count,
    MIN(t.VALUE) AS min_val,
    MAX(t.VALUE) AS max_val,
    AVG(t.VALUE)::DECIMAL(18,2) AS avg_val,
    MEDIAN(t.VALUE)::DECIMAL(18,2) AS median_val,
    COUNT(DISTINCT t.GEO_ID) AS geo_count
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES t
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES a
    ON t.VARIABLE = a.VARIABLE
WHERE a.RELEASE_SOURCE = 'Bureau of Labor Statistics'
GROUP BY a.MEASURE
ORDER BY rows_count DESC
LIMIT 15;

-- Critical observation from this output: Unemployment Rate has median = 0.05
-- (meaning 5%). The data stores percents as DECIMAL FRACTIONS, not as
-- percentage numbers. The semantic model must multiply VALUE * 100 when
-- displaying any measure with UNIT = 'Percent'.


-- =============================================================================
-- PART 8: Final measure validation — what we'll model
-- =============================================================================

-- Q12: Final list of BLS measures for the semantic model — frequency, unit,
-- state coverage, and date range for each
SELECT
    a.MEASURE,
    a.FREQUENCY,
    a.UNIT,
    COUNT(DISTINCT t.GEO_ID) AS state_count,
    COUNT(*) AS rows_count,
    MIN(t.DATE) AS first_date,
    MAX(t.DATE) AS last_date
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES a
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES t
    ON a.VARIABLE = t.VARIABLE
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.GEOGRAPHY_INDEX g
    ON t.GEO_ID = g.GEO_ID
WHERE a.RELEASE_SOURCE = 'Bureau of Labor Statistics'
  AND g.LEVEL = 'State' AND g.GEO_ID LIKE 'geoId/%'
  AND a.MEASURE IN (
    'Unemployment Rate', 'Unemployment', 'Employment', 'Labor Force',
    'Labor Force Participation Rate', 'Employment-Population Ratio',
    'Average Hourly Earnings Of All Employees',
    'Average Weekly Earnings Of All Employees',
    'Average Weekly Hours Of All Employees', 'All Employees',
    'Job Openings: All Size Classes', 'Hires: All Size Classes',
    'Quits: All Size Classes', 'Layoffs And Discharges: All Size Classes',
    'Total Separations: All Size Classes'
  )
GROUP BY a.MEASURE, a.FREQUENCY, a.UNIT
ORDER BY a.MEASURE, a.FREQUENCY;

-- Key findings that shaped the final YAML:
-- - JOLTS measures (Hires, Quits, Layoffs, Job Openings, Total Separations)
--   exist in TWO units: 'Level' (counts) and 'Percent' (rates). Queries
--   must filter on UNIT or results mix the two series.
-- - Wages (Hourly/Weekly Earnings) only available from 2007 onward.
-- - JOLTS data only available from 2000 onward.
-- - Core labor measures (Unemployment, Employment) go back to 1976.
-- - All Employees goes back to 1939 (deepest history).


-- Q13: Industry dimension for "All Employees" (the industry-breakdown measure)
SELECT DISTINCT a.INDUSTRY, COUNT(DISTINCT t.GEO_ID) AS state_count
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES a
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES t
    ON a.VARIABLE = t.VARIABLE
JOIN SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.GEOGRAPHY_INDEX g
    ON t.GEO_ID = g.GEO_ID
WHERE a.RELEASE_SOURCE = 'Bureau of Labor Statistics'
  AND a.MEASURE = 'All Employees'
  AND a.FREQUENCY = 'Monthly'
  AND g.LEVEL = 'State' AND g.GEO_ID LIKE 'geoId/%'
GROUP BY a.INDUSTRY
HAVING state_count >= 50
ORDER BY state_count DESC;

-- Result: ~30 industries covering 50+ states, including Total Nonfarm,
-- Total Private, Manufacturing, Retail Trade, Government (Federal/State/Local),
-- Education And Health Services, Professional And Business Services,
-- Financial Activities, Leisure And Hospitality, Information, Construction,
-- etc. These become the sample_values for the INDUSTRY dimension in the YAML.


-- =============================================================================
-- Summary: this exploration produced the final semantic model scope
--   - 1 data source: Bureau of Labor Statistics
--   - 15 measures across 4 groups (labor health, wages, industry, JOLTS)
--   - 2 frequencies: Monthly + Annual
--   - 51 geographies: 50 US states/territories + national (country/USA)
--   - Date range: 1939-2025 (varies by measure)
-- =============================================================================
