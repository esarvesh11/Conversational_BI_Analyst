# Snowflake Notebook: US Labor Market Monitor — Modeling Decisions

This file contains the cell-by-cell content for a Snowflake Notebook that
documents the modeling decisions behind the US Labor Market Monitor app.
Each section below is one notebook cell. Cell types are labeled as
**[MARKDOWN]** or **[SQL]** — create the appropriate cell type in
Snowsight and paste the content.

Where to create the notebook:
- Snowsight -> Projects -> Notebooks -> + Notebook
- Database: LABOR_MARKET_MONITOR, Schema: APP, Warehouse: LMM_WH
- Runtime: Run on Warehouse

---

## Cell 1 [MARKDOWN]

```markdown
# US Labor Market Monitor

**Conversational BI with Snowflake Cortex Analyst**

A natural language analytics interface for US labor market data. Users ask
questions in plain English like *"What is the unemployment rate in California?"*
or *"Compare hiring trends in Texas and New York"* — the app returns SQL-backed
charts, data tables, and LLM-generated executive summaries, with full SQL
transparency. Zero SQL knowledge required from the end user.

This notebook documents the modeling decisions behind the semantic model,
the data exploration that shaped our scope, the bugs we caught during
testing, and the final architecture.
```

---

## Cell 2 [MARKDOWN]

```markdown
## 1. Problem Framing

**Who is this for?**
- Economic analysts at think tanks, banks, consulting firms
- Journalists writing about jobs and the economy
- Policy researchers at government agencies
- Students learning applied economics

**What problem does it solve?**
Traditional BI tools require SQL knowledge and hunting through dashboards.
Users who want to quickly answer questions like *"How are wages changing
in Colorado?"* either have to learn SQL, find a dashboard, or ask a data
analyst. Our app removes that friction — ask in English, get a chart and
a summary immediately.

**Why Snowflake Cortex Analyst?**
- Semantic model makes the AI grounded in our actual data, not hallucinating
- Runs entirely inside Snowflake — no external LLM APIs, no data egress
- Cortex COMPLETE() generates narrative insight from the query results
- Streamlit in Snowflake serves the UI natively, no external hosting needed
```

---

## Cell 3 [MARKDOWN]

```markdown
## 2. Data Source: Cybersyn Financial & Economic Indicators

We used two tables from the free Snowflake Marketplace dataset
`SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE`:

1. **FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES** — dimension table
   describing each economic variable (measure, industry, frequency, unit,
   seasonal adjustment, release source).

2. **FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES** — fact table with the
   actual values (date, value, geography, variable).

Plus a third table for geography lookups:

3. **GEOGRAPHY_INDEX** — maps opaque GEO_ID codes like `geoId/06` to
   human-readable names like `California`.

These form a classic star schema: one fact table, two dimension tables.
```

---

## Cell 4 [SQL]

```sql
-- Data landscape: how big, how deep, how wide?
SELECT
    (SELECT COUNT(*) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES) AS attribute_rows,
    (SELECT COUNT(*) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES) AS timeseries_rows,
    (SELECT MIN(DATE) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES) AS earliest_date,
    (SELECT MAX(DATE) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES) AS latest_date,
    (SELECT COUNT(DISTINCT GEO_ID) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_TIMESERIES) AS distinct_geos;
```

---

## Cell 5 [MARKDOWN]

```markdown
## 3. Scope Decision: Why BLS Only

The dataset contains ~164K variables across 9 government sources:

| Source | Variables | What They Track |
|---|---|---|
| Bureau of Labor Statistics (BLS) | 92K | Jobs, wages, unemployment, JOLTS, CPI |
| Federal Reserve | 44K | Financial accounts, assets, money flows |
| Bureau of Economic Analysis (BEA) | 19K | GDP, personal income, trade |
| US Census Bureau | 6.7K | Retail sales, business formation, housing |
| Consumer Financial Protection Bureau | 1.4K | Consumer credit, mortgages |
| University of Michigan | 358 | Consumer sentiment surveys |
| Others (NY Fed, DOL, Freddie Mac) | <100 | Specialized |

**We chose BLS only.** Here's why:

- **Coherent story**: All data is labor-market focused, so measures play
  well together on the same charts (same units, similar scales, same geo
  coverage).
- **State-level depth**: BLS has the richest state-level coverage,
  enabling powerful comparison queries ("which state has the highest
  unemployment?") that cross-source data can't match.
- **Semantic model quality over breadth**: A tight model covering 15 BLS
  measures well beats a sprawling model covering 50 measures poorly —
  Cortex Analyst has fewer ambiguous choices to make, and accuracy goes up.
- **Debugging simplicity**: When something goes wrong, we know exactly
  where to look. No cross-source naming conflicts.
```

---

## Cell 6 [SQL]

```sql
-- Release sources and their coverage
SELECT
    RELEASE_SOURCE,
    COUNT(DISTINCT MEASURE) AS measure_count,
    COUNT(DISTINCT VARIABLE) AS variable_count
FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.FINANCIAL_ECONOMIC_INDICATORS_ATTRIBUTES
GROUP BY RELEASE_SOURCE
ORDER BY variable_count DESC;
```

---

## Cell 7 [SQL]

```sql
-- BLS measures available at state level (the core of our semantic model)
SELECT a.MEASURE, COUNT(DISTINCT t.GEO_ID) AS state_count, COUNT(*) AS rows_count
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
LIMIT 20;
```

---

## Cell 8 [MARKDOWN]

```markdown
## 4. The 15 Measures In Our Semantic Model

Grouped by what they tell you about the labor market:

**Labor Market Health**
1. Unemployment Rate (Percent)
2. Unemployment (Persons)
3. Employment (Persons)
4. Labor Force (Persons)
5. Labor Force Participation Rate (Percent)
6. Employment-Population Ratio (Percent)

**Wages and Hours**
7. Average Hourly Earnings Of All Employees (USD)
8. Average Weekly Earnings Of All Employees (USD)
9. Average Weekly Hours Of All Employees (Hours)

**Employment by Industry**
10. All Employees (Count) — with INDUSTRY dimension covering ~30 sectors

**Job Dynamics (JOLTS)**
11. Job Openings: All Size Classes (Level or Percent)
12. Hires: All Size Classes (Level or Percent)
13. Quits: All Size Classes (Level or Percent)
14. Layoffs And Discharges: All Size Classes (Level or Percent)
15. Total Separations: All Size Classes (Level or Percent)

**Coverage**: All measures have Monthly + Annual frequencies, all 50+ US
states plus national (country/USA). Date ranges go back to 1976 for the
core labor measures and as far as 1939 for employment. JOLTS data starts
in 2000. Wages data starts in 2007.
```

---

## Cell 9 [MARKDOWN]

```markdown
## 5. Semantic Model Architecture

The semantic model YAML (`us_labor_market_monitor.yaml`) defines three
logical tables and the relationships between them:

```
      ┌──────────────────┐
      │    TIMESERIES    │  (the facts)
      │  VARIABLE        │
      │  GEO_ID          │──────┐
      │  DATE            │      │
      │  VALUE           │      │
      └──────────────────┘      │
           │                    │
           │ VARIABLE           │ GEO_ID
           ▼                    ▼
      ┌──────────────────┐  ┌──────────────────┐
      │    ATTRIBUTES    │  │ GEOGRAPHY_INDEX  │
      │  MEASURE         │  │  GEO_NAME        │
      │  INDUSTRY        │  │  LEVEL           │
      │  FREQUENCY       │  │                  │
      │  SEASONALLY_ADJ  │  │  (filtered to    │
      │  UNIT            │  │   State +        │
      │  (filtered to    │  │   Country)       │
      │   BLS only)      │  │                  │
      └──────────────────┘  └──────────────────┘
```

**Every query joins all 3 tables:**
- Timeseries -> Attributes (on VARIABLE) — to know *what* VALUE means
- Timeseries -> Geography_Index (on GEO_ID) — to filter by human-readable
  state names like "California" instead of opaque codes like "geoId/06"

The YAML also includes:
- 7 critical filtering rules in `custom_instructions` (see next section)
- Rich synonyms for each column so users can say "wages", "pay", "salary"
  and all resolve to `Average Hourly Earnings Of All Employees`
- 10 verified example questions with correct SQL — these teach Cortex
  Analyst the patterns to follow for new questions
```

---

## Cell 10 [MARKDOWN]

```markdown
## 6. Bugs We Caught During Testing (And How We Fixed Them)

Testing revealed 5 subtle issues that would have caused wrong results.
Each is now encoded as a rule in `custom_instructions`:

**Bug #1: Duplicate rows from seasonal adjustment.**
Every BLS measure exists in both `Seasonally adjusted` and `Not seasonally
adjusted` variants. Without a filter, queries returned exactly 2x the
expected rows. **Fix:** Default to `SEASONALLY_ADJUSTED = 'Not seasonally
adjusted'` unless the user specifies otherwise.

**Bug #2: "New York" matching both state and city.**
The geography table contains both `geoId/36` (New York state) and
`geoId/3651000` (New York City). A filter on `GEO_NAME = 'New York'`
returned both, doubling the rows. **Fix:** Add `g.LEVEL = 'State'` when
the question is about states.

**Bug #3: National unemployment returning 1,200+ demographic slices.**
At `country/USA`, the measure `Unemployment Rate` expands into hundreds
of demographic breakdowns (by age, race, gender). **Fix:** For national
queries, add `VARIABLE_NAME LIKE 'Current Labor Force: Unemployment Rate,
Monthly%'` to isolate the headline rate.

**Bug #4: Wage queries returning multiple industries.**
`Average Hourly Earnings Of All Employees` exists for ~12 industries per
state. **Fix:** Default to `INDUSTRY = 'Total Private'` unless the user
asks about a specific industry.

**Bug #5: Percent values stored as decimal fractions.**
Unemployment Rate is stored as 0.051 (meaning 5.1%), not as 5.1. Raw
display showed "0.051" which is misleading. **Fix:** Multiply `VALUE * 100`
in the SELECT for any measure with `UNIT = 'Percent'`.

**Bug #6: JOLTS measures returning both Level and Percent units.**
Hires, Quits, Layoffs, etc. exist in both unit variants. Without a
UNIT filter, queries mixed them together. **Fix:** Default to
`UNIT = 'Level'` for count questions, `'Percent'` for rate questions.
```

---

## Cell 11 [MARKDOWN]

```markdown
## 7. Testing Results

We tested 18 natural language questions covering different patterns:

| Pattern | Example | Result |
|---|---|---|
| Single state | "Unemployment rate in California" | ✅ Correct |
| State comparison | "Compare earnings in NY and MA" | ✅ Correct |
| Top-N ranking | "5 states with highest unemployment" | ✅ Correct |
| Bottom-N ranking | "Bottom 5 by labor force participation" | ✅ Correct |
| National trend | "National unemployment since 2020" | ✅ Correct |
| Industry breakdown | "Employees by industry in Ohio" | ✅ Correct |
| JOLTS / job dynamics | "Hiring trends in Colorado since 2021" | ✅ Correct (after Bug #6 fix) |
| Annual frequency | "Annual unemployment by state 2024" | ✅ Correct |
| Year-over-year | "Employment change in Washington 2022-2024" | ✅ Correct |

**Final accuracy: 18/18 correct after iteration.** The bugs listed in
Section 6 were all caught and fixed through this testing loop.

One real data limitation we documented: wage data (`Average Hourly
Earnings`) is only available at the state level, not nationally. The
YAML's MEASURE description notes this so Cortex Analyst handles it
gracefully.
```

---

## Cell 12 [MARKDOWN]

```markdown
## 8. End-to-End Architecture

```
User types question
        │
        ▼
┌─────────────────────────────────────┐
│  Streamlit in Snowflake (UI)        │
│  - Chat input                       │
│  - Suggested questions sidebar      │
│  - Chart / Data / SQL tabs          │
└─────────────────────────────────────┘
        │
        ▼ send_snow_api_request
┌─────────────────────────────────────┐
│  Cortex Analyst                     │
│  - Reads semantic_model.yaml        │
│  - Applies custom_instructions      │
│  - Learns from verified_queries     │
│  - Generates SQL                    │
└─────────────────────────────────────┘
        │
        ▼ session.sql(...).to_pandas()
┌─────────────────────────────────────┐
│  Snowflake SQL execution            │
│  - Joins 3 tables                   │
│  - Returns DataFrame                │
└─────────────────────────────────────┘
        │
        ├──────────────────────┐
        ▼                      ▼
┌────────────────────┐  ┌────────────────────────┐
│  Altair chart      │  │  Cortex COMPLETE       │
│  (auto-selected    │  │  (mistral-large)       │
│   by data shape)   │  │  - Executive summary   │
└────────────────────┘  └────────────────────────┘
        │                      │
        └──────────┬───────────┘
                   ▼
          Rendered to user:
          summary + chart + data table + SQL
```

**Snowflake features leveraged:**
- Cortex Analyst (SQL generation from NL)
- Cortex COMPLETE with mistral-large (narrative summaries)
- Snowflake Stages (YAML file storage)
- Streamlit in Snowflake (native UI, no external hosting)
- Snowpark Python (DataFrame ops inside the app)
- Marketplace data (Cybersyn Financial & Economic Indicators)
- Custom warehouse with auto-suspend (cost control)
```

---

## Cell 13 [MARKDOWN]

```markdown
## 9. Future Enhancements

Things we'd add with more time:

- **Conversational memory** — follow-up questions like "now show that
  for Texas" using previous context
- **Additional sources** — layer in BEA (GDP), Census (retail sales),
  Freddie Mac (mortgage rates) as separate semantic models the user
  can switch between
- **Scheduled alerts** — use Snowflake Tasks to watch for threshold
  breaches (e.g., unemployment > X%) and notify
- **Forecasting** — integrate Snowflake ML time series forecasting for
  "what will unemployment look like in 6 months?" questions
- **Multi-country** — the GEOGRAPHY_INDEX includes Canadian provinces;
  could extend to Canadian labor data if available

## Summary

We shipped a fully Snowflake-native conversational BI app that answers
labor market questions with SQL-backed charts and LLM narratives. The
semantic model covers 15 BLS measures across 50+ states and national,
with tested accuracy on 18 NL patterns and 7 encoded rules that prevent
common data pitfalls.
```
