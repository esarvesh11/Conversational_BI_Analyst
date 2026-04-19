"""
US Labor Market Monitor — Conversational BI App

This app runs in Streamlit in Snowflake. It lets users ask plain-English
questions about US labor market data (unemployment, employment, wages,
job openings, etc.) and returns SQL-backed charts with LLM-generated
narrative summaries, powered by Snowflake Cortex Analyst and Cortex COMPLETE.

Required Streamlit in Snowflake packages (add via the Packages panel):
  - snowflake-snowpark-python
  - pandas
  - altair
"""

import json
import _snowflake
import streamlit as st
import pandas as pd
import altair as alt
from snowflake.snowpark.context import get_active_session


# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
SEMANTIC_MODEL_FILE = "@LABOR_MARKET_MONITOR.APP.SEMANTIC_MODELS/us_labor_market_monitor.yaml"
CORTEX_ANALYST_ENDPOINT = "/api/v2/cortex/analyst/message"
SUMMARY_MODEL = "mistral-large"
API_TIMEOUT_MS = 50_000

SUGGESTED_QUESTIONS = [
    "What is the unemployment rate in California?",
    "Which 5 states have the highest unemployment rate?",
    "Compare average hourly earnings in New York and Massachusetts",
    "How many employees work in each industry in Ohio?",
    "Show hiring trends in Colorado since 2021",
    "What is the national unemployment rate trend since 2020?",
]


# -----------------------------------------------------------------------------
# PAGE SETUP
# -----------------------------------------------------------------------------
st.set_page_config(
    page_title="US Labor Market Monitor",
    page_icon="📊",
    layout="wide",
)

st.title("US Labor Market Monitor")
st.caption(
    "Ask questions in plain English about US labor market data — "
    "unemployment, employment, wages, job openings, and more. "
    "Powered by Snowflake Cortex Analyst."
)

session = get_active_session()


# -----------------------------------------------------------------------------
# SESSION STATE — keep chat history between reruns
# -----------------------------------------------------------------------------
if "messages" not in st.session_state:
    st.session_state.messages = []

if "pending_question" not in st.session_state:
    st.session_state.pending_question = None


# -----------------------------------------------------------------------------
# CORTEX ANALYST — send question, get SQL back
# -----------------------------------------------------------------------------
def call_cortex_analyst(question: str) -> dict:
    """Send a user question to Cortex Analyst and return the parsed response."""
    request_body = {
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": question}],
            }
        ],
        "semantic_model_file": SEMANTIC_MODEL_FILE,
    }

    response = _snowflake.send_snow_api_request(
        "POST",
        CORTEX_ANALYST_ENDPOINT,
        {},
        {},
        request_body,
        {},
        API_TIMEOUT_MS,
    )

    if response["status"] < 400:
        return json.loads(response["content"])

    error_content = response.get("content", "")
    try:
        error_json = json.loads(error_content)
        error_msg = error_json.get("message", error_content)
    except Exception:
        error_msg = error_content
    raise RuntimeError(f"Cortex Analyst error ({response['status']}): {error_msg}")


def extract_sql_and_text(analyst_response: dict) -> tuple[str, str]:
    """Pull the generated SQL and any explanation text out of the Analyst response."""
    sql = ""
    explanation = ""
    message = analyst_response.get("message", {})
    for item in message.get("content", []):
        if item.get("type") == "sql":
            sql = item.get("statement", "")
        elif item.get("type") == "text":
            explanation = item.get("text", "")
    return sql, explanation


# -----------------------------------------------------------------------------
# LLM NARRATIVE SUMMARY — Cortex COMPLETE() generates executive insight
# -----------------------------------------------------------------------------
def generate_narrative(question: str, df: pd.DataFrame) -> str:
    """Use Cortex COMPLETE to create a short executive summary of the data."""
    if df.empty:
        return "No data was returned for this question."

    sample = df.head(25).to_csv(index=False)
    prompt = f"""You are an economic analyst writing a brief executive summary.

User question: {question}

Query results (first 25 rows):
{sample}

Write a 2-3 sentence executive summary highlighting the key insight,
trend, or comparison. Be concrete — cite specific numbers, states, or
time periods from the data. Do not repeat the question. Do not describe
the table structure. Focus on what the data tells us."""

    escaped_prompt = prompt.replace("'", "''")
    sql = f"SELECT SNOWFLAKE.CORTEX.COMPLETE('{SUMMARY_MODEL}', '{escaped_prompt}') AS summary"
    try:
        result = session.sql(sql).collect()
        return result[0]["SUMMARY"].strip()
    except Exception as e:
        return f"(Summary generation failed: {e})"


# -----------------------------------------------------------------------------
# CHART BUILDER — pick a reasonable chart based on the data shape
# -----------------------------------------------------------------------------
def render_chart(df: pd.DataFrame) -> None:
    """Render a chart based on the columns present in the dataframe."""
    if df.empty:
        st.info("No data returned.")
        return

    cols = [c.lower() for c in df.columns]
    date_col = next((c for c in df.columns if c.lower() == "date"), None)
    geo_col = next((c for c in df.columns if c.lower() == "geo_name"), None)
    industry_col = next((c for c in df.columns if c.lower() == "industry"), None)

    numeric_cols = df.select_dtypes(include="number").columns.tolist()
    if not numeric_cols:
        st.info("No numeric data to chart — showing table only.")
        return

    value_col = numeric_cols[0]

    if date_col and geo_col and df[geo_col].nunique() > 1:
        # Multi-state time series → colored line chart
        chart = (
            alt.Chart(df)
            .mark_line(point=True)
            .encode(
                x=alt.X(f"{date_col}:T", title="Date"),
                y=alt.Y(f"{value_col}:Q", title=value_col),
                color=alt.Color(f"{geo_col}:N", title="State"),
                tooltip=list(df.columns),
            )
            .properties(height=400)
        )
        st.altair_chart(chart, use_container_width=True)

    elif date_col:
        # Single time series → line chart
        chart = (
            alt.Chart(df)
            .mark_line(point=True)
            .encode(
                x=alt.X(f"{date_col}:T", title="Date"),
                y=alt.Y(f"{value_col}:Q", title=value_col),
                tooltip=list(df.columns),
            )
            .properties(height=400)
        )
        st.altair_chart(chart, use_container_width=True)

    elif geo_col and not date_col:
        # State ranking → horizontal bar
        chart = (
            alt.Chart(df)
            .mark_bar()
            .encode(
                x=alt.X(f"{value_col}:Q", title=value_col),
                y=alt.Y(f"{geo_col}:N", sort="-x", title="State"),
                tooltip=list(df.columns),
            )
            .properties(height=max(300, 25 * len(df)))
        )
        st.altair_chart(chart, use_container_width=True)

    elif industry_col:
        # Industry breakdown → horizontal bar
        chart = (
            alt.Chart(df)
            .mark_bar()
            .encode(
                x=alt.X(f"{value_col}:Q", title=value_col),
                y=alt.Y(f"{industry_col}:N", sort="-x", title="Industry"),
                tooltip=list(df.columns),
            )
            .properties(height=max(300, 25 * len(df)))
        )
        st.altair_chart(chart, use_container_width=True)

    else:
        st.bar_chart(df[value_col])


# -----------------------------------------------------------------------------
# ANSWER PIPELINE — full flow from question to visualized answer
# -----------------------------------------------------------------------------
def answer_question(question: str) -> dict:
    """Run the full pipeline and return the result payload for rendering."""
    result = {"question": question, "sql": "", "explanation": "", "df": None,
              "summary": "", "error": None}

    try:
        with st.spinner("Cortex Analyst is generating SQL…"):
            analyst_response = call_cortex_analyst(question)
            sql, explanation = extract_sql_and_text(analyst_response)
            result["sql"] = sql
            result["explanation"] = explanation

        if not sql:
            result["error"] = (
                explanation or "Cortex Analyst did not return a SQL query."
            )
            return result

        with st.spinner("Running query on Snowflake…"):
            df = session.sql(sql).to_pandas()
            result["df"] = df

        with st.spinner("Generating executive summary…"):
            result["summary"] = generate_narrative(question, df)

    except Exception as e:
        result["error"] = str(e)

    return result


def render_answer(result: dict) -> None:
    """Render the question, summary, chart, data table, and SQL panel."""
    st.markdown(f"**Q: {result['question']}**")

    if result["error"]:
        st.error(result["error"])
        if result["sql"]:
            with st.expander("Generated SQL"):
                st.code(result["sql"], language="sql")
        return

    df = result["df"]

    if result["summary"]:
        st.info(result["summary"])

    if df is not None and not df.empty:
        tab_chart, tab_data, tab_sql = st.tabs(["Chart", "Data", "SQL"])
        with tab_chart:
            render_chart(df)
        with tab_data:
            st.dataframe(df, use_container_width=True)
        with tab_sql:
            st.code(result["sql"], language="sql")
            if result["explanation"]:
                st.caption(result["explanation"])
    else:
        st.warning("No data returned for this question.")
        with st.expander("Generated SQL"):
            st.code(result["sql"], language="sql")


# -----------------------------------------------------------------------------
# SIDEBAR — suggested questions
# -----------------------------------------------------------------------------
with st.sidebar:
    st.subheader("Try a question")
    for q in SUGGESTED_QUESTIONS:
        if st.button(q, key=f"suggest_{q}", use_container_width=True):
            st.session_state.pending_question = q

    st.divider()
    st.caption(
        "Data source: Bureau of Labor Statistics, via Snowflake Marketplace "
        "(SNOWFLAKE_PUBLIC_DATA_FREE). Coverage: US national + 50+ states. "
        "Monthly and annual frequencies, decades of history."
    )

    if st.button("Clear chat"):
        st.session_state.messages = []
        st.session_state.pending_question = None
        st.rerun()


# -----------------------------------------------------------------------------
# MAIN — chat history + input
# -----------------------------------------------------------------------------
for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        if msg["role"] == "user":
            st.write(msg["content"])
        else:
            render_answer(msg["content"])

user_input = st.chat_input("Ask about unemployment, wages, jobs, hiring in any US state…")

question_to_run = st.session_state.pending_question or user_input
if question_to_run:
    st.session_state.pending_question = None

    st.session_state.messages.append({"role": "user", "content": question_to_run})
    with st.chat_message("user"):
        st.write(question_to_run)

    with st.chat_message("assistant"):
        result = answer_question(question_to_run)
        render_answer(result)

    st.session_state.messages.append({"role": "assistant", "content": result})
