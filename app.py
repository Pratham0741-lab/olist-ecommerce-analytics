"""Four-page Streamlit dashboard for the Olist analysis.

Pages: Revenue & trends, Delivery & satisfaction, Sellers & customers,
Cohort retention. KPI tiles and charts run the named queries in queries.sql
(the same ones analysis.ipynb uses), plus two small extra queries below, against
data/olist.db. Run analysis.ipynb first to build the database.

Run: streamlit run app.py
"""

from __future__ import annotations

import re
import sqlite3
from pathlib import Path

import pandas as pd
import plotly.express as px
import streamlit as st

HERE = Path(__file__).resolve().parent
DB_PATH = HERE / "data" / "olist.db"
QUERY_FILE = HERE / "queries.sql"

st.set_page_config(page_title="Olist analytics", layout="wide")

ACCENT = "#2a6f97"
LATE = "#c8553d"

SELLER_SCATTER_SQL = """
WITH so AS (SELECT DISTINCT seller_id, order_id FROM order_items)
SELECT so.seller_id,
       COUNT(*)                         AS delivered_orders,
       ROUND(AVG(r.review_score), 3)    AS avg_review,
       ROUND(100.0 * AVG(o.is_late), 1) AS late_rate_pct
FROM so
JOIN orders o             ON o.order_id = so.order_id
LEFT JOIN order_reviews r ON r.order_id = so.order_id
WHERE o.in_window = 1 AND o.order_status = 'delivered'
GROUP BY so.seller_id
HAVING COUNT(*) >= 50
"""

ORDERS_PER_CUSTOMER_SQL = """
WITH per_person AS (
    SELECT c.customer_unique_id, COUNT(*) AS n_orders
    FROM orders o JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.in_window = 1 AND o.is_sale = 1
    GROUP BY c.customer_unique_id
)
SELECT CASE WHEN n_orders >= 4 THEN '4+' ELSE CAST(n_orders AS TEXT) END AS orders_per_customer,
       COUNT(*) AS customers
FROM per_person
GROUP BY 1
ORDER BY 1
"""


@st.cache_data
def q(name: str) -> pd.DataFrame:
    """Run a named query from queries.sql (cached)."""
    parts = re.split(r"^-- name: (\w+)\s*$", QUERY_FILE.read_text(encoding="utf-8"), flags=re.MULTILINE)
    queries = {parts[i]: parts[i + 1].strip() for i in range(1, len(parts), 2)}
    return sql(queries[name])


@st.cache_data
def metric(name: str) -> pd.Series:
    """One canonical metric from queries.sql (definitions in analysis.ipynb, Part 3)."""
    return q(name).iloc[0]


@st.cache_data
def sql(text: str) -> pd.DataFrame:
    """Run an ad-hoc SQL string (cached)."""
    with sqlite3.connect(DB_PATH) as con:
        return pd.read_sql_query(text, con)


def money(x: float) -> str:
    """Format Brazilian reais in millions or thousands."""
    return f"R$ {x / 1e6:,.2f}M" if x >= 1e6 else f"R$ {x / 1e3:,.0f}k"


def page_revenue() -> None:
    """Page 1: revenue trend, categories and payment mix."""
    st.title("Revenue and trends")
    st.caption(
        "Orders purchased Jan 2017 - Aug 2018, excluding canceled/unavailable. Revenue = item price, no freight."
    )
    monthly = q("monthly_revenue")
    rev17 = monthly.loc[monthly["purchase_month"].between("2017-01", "2017-08"), "revenue"].sum()
    rev18 = monthly.loc[monthly["purchase_month"].between("2018-01", "2018-08"), "revenue"].sum()
    revenue = metric("revenue")
    c1, c2, c3 = st.columns(3)
    c1.metric("Revenue (20 months)", money(revenue["value"]))
    c2.metric("Orders", f"{int(revenue['orders']):,}")
    c3.metric("Jan-Aug 2018 vs 2017", f"{100 * (rev18 / rev17 - 1):+.1f}%")

    fig = px.bar(
        monthly,
        x="purchase_month",
        y="revenue",
        color_discrete_sequence=[ACCENT],
        labels={"purchase_month": "Month", "revenue": "Revenue (R$)"},
        title="Monthly revenue",
    )
    fig.update_layout(xaxis_type="category")
    st.plotly_chart(fig, width="stretch")

    left, right = st.columns(2)
    cats = q("top_categories")
    fig = px.bar(
        cats.sort_values("revenue"),
        x="revenue",
        y="category",
        orientation="h",
        color_discrete_sequence=[ACCENT],
        title="Top 15 categories by revenue",
        labels={"revenue": "Revenue (R$)", "category": ""},
        hover_data=["revenue_share_pct"],
    )
    left.plotly_chart(fig, width="stretch")

    pay = q("payment_mix")
    fig = px.bar(
        pay,
        x="payment_type",
        y="value_share_pct",
        color_discrete_sequence=[ACCENT],
        title="Share of payment value by type",
        text="value_share_pct",
        labels={"payment_type": "", "value_share_pct": "% of payment value"},
        hover_data=["orders_using_type", "avg_installments"],
    )
    right.plotly_chart(fig, width="stretch")


def page_delivery() -> None:
    """Page 2: delivery delay versus review score, and by state."""
    st.title("Delivery and satisfaction")
    st.caption("Delivered orders in the window. Late = delivered after the estimated delivery date.")
    lv = q("late_vs_ontime").set_index("delivery")
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Late deliveries", f"{metric('late_delivery_rate')['value']:.2f}%")
    c2.metric(
        "Avg review: late vs on time", f"{lv.loc['late', 'avg_review']:.2f} vs {lv.loc['on_time', 'avg_review']:.2f}"
    )
    c3.metric("Revenue in late orders", money(lv.loc["late", "revenue"]))
    c4.metric("Average review (all delivered)", f"{metric('avg_review_score')['value']:.2f}")

    delay = q("delay_vs_review")
    delay["late"] = delay["delay_bucket"].str.contains("late").map({True: "late", False: "on time / early"})
    fig = px.bar(
        delay,
        x="delay_bucket",
        y="avg_review",
        color="late",
        color_discrete_map={"late": LATE, "on time / early": ACCENT},
        text="avg_review",
        hover_data=["delivered_orders", "pct_1_or_2_stars"],
        labels={"delay_bucket": "Delivery vs promised date", "avg_review": "Average review (1-5)"},
        title="Average review score by delivery delay",
    )
    fig.update_yaxes(range=[0, 5])
    st.plotly_chart(fig, width="stretch")

    states = q("state_delivery")
    left, right = st.columns(2)
    fig = px.bar(
        states.sort_values("late_rate_pct"),
        x="late_rate_pct",
        y="customer_state",
        orientation="h",
        color_discrete_sequence=[LATE],
        title="Late rate by customer state (100+ orders)",
        labels={"late_rate_pct": "% delivered late", "customer_state": ""},
        hover_data=["delivered_orders", "avg_delivery_days"],
    )
    fig.update_layout(height=600)
    left.plotly_chart(fig, width="stretch")
    corr = states["late_rate_pct"].corr(states["avg_review"])
    fig = px.scatter(
        states,
        x="late_rate_pct",
        y="avg_review",
        size="delivered_orders",
        text="customer_state",
        color_discrete_sequence=[ACCENT],
        title=f"State late rate vs review (r = {corr:.2f})",
        labels={"late_rate_pct": "% delivered late", "avg_review": "Average review"},
    )
    fig.update_traces(textposition="top center")
    fig.update_layout(height=600)
    right.plotly_chart(fig, width="stretch")


def page_sellers() -> None:
    """Page 3: repeat customers and seller quality."""
    st.title("Sellers and customers")
    rep = metric("repeat_customers")
    c1, c2 = st.columns(2)
    c1.metric("Active customers", f"{int(metric('active_customers')['value']):,}")
    c2.metric("Repeat-customer rate", f"{rep['rate_pct']:.2f}%")

    left, right = st.columns(2)
    opc = sql(ORDERS_PER_CUSTOMER_SQL)
    fig = px.bar(
        opc,
        x="orders_per_customer",
        y="customers",
        log_y=True,
        color_discrete_sequence=[ACCENT],
        text="customers",
        title="Customers by number of orders (log scale)",
        labels={"orders_per_customer": "Orders per customer", "customers": "Customers"},
    )
    # "1","2","3" look numeric, so without this Plotly uses a numeric axis and drops "4+".
    fig.update_layout(xaxis_type="category")
    left.plotly_chart(fig, width="stretch")

    sellers = sql(SELLER_SCATTER_SQL)
    fig = px.scatter(
        sellers,
        x="late_rate_pct",
        y="avg_review",
        size="delivered_orders",
        color_discrete_sequence=[ACCENT],
        hover_data=["seller_id"],
        title=f"Sellers with 50+ delivered orders (n = {len(sellers)})",
        labels={"late_rate_pct": "% delivered late", "avg_review": "Average review"},
    )
    right.plotly_chart(fig, width="stretch")

    st.subheader("10 lowest-rated sellers (50+ delivered orders)")
    st.dataframe(q("worst_sellers").drop(columns="sellers_with_50_plus"), hide_index=True, width="stretch")


def page_cohorts() -> None:
    """Page 4: monthly acquisition cohorts and their retention."""
    st.title("Cohort retention")
    st.caption(
        "Cohort = month of a customer's first sale order. Cell = % of the cohort with a sale order "
        "k months later. Month 0 (always 100%) is hidden so the colour scale is readable."
    )
    long = q("cohort_retention")
    sizes = long[long["month_offset"] == 0].set_index("cohort_month")["cohort_customers"]
    later = long[long["month_offset"] > 0]
    eligible = later[later["month_offset"] == 1]
    m1 = 100 * eligible["active_customers"].sum() / sizes.loc[eligible["cohort_month"]].sum()
    c1, c2, c3 = st.columns(3)
    c1.metric("Cohorts", f"{len(sizes)}")
    c2.metric("Month-1 retention (weighted)", f"{m1:.2f}%")
    c3.metric("Highest cell after month 0", f"{later['retention_pct'].max():.2f}%")

    mat = later.pivot(index="cohort_month", columns="month_offset", values="retention_pct")
    fig = px.imshow(
        mat,
        color_continuous_scale="Blues",
        aspect="auto",
        text_auto=".2f",
        labels={"x": "Months since first order", "y": "Cohort (first-order month)", "color": "% active"},
        title="Retention by acquisition cohort (%)",
    )
    fig.update_xaxes(dtick=1)
    fig.update_layout(height=650)
    st.plotly_chart(fig, width="stretch")
    st.info(
        "Fewer than 1% of any cohort buys again in a later month. Olist is a one-purchase marketplace "
        "in this data, so cells differ by a handful of customers and small changes are noise. "
        "Details: analysis.ipynb, Part 4."
    )

    fig = px.bar(
        sizes.reset_index(),
        x="cohort_month",
        y="cohort_customers",
        color_discrete_sequence=[ACCENT],
        title="New customers per cohort",
        labels={"cohort_month": "Cohort", "cohort_customers": "New customers"},
    )
    fig.update_layout(xaxis_type="category")
    st.plotly_chart(fig, width="stretch")


if not DB_PATH.exists():
    st.error("Database not found. Run analysis.ipynb first to build data/olist.db.")
    st.stop()

nav = st.navigation(
    [
        st.Page(page_revenue, title="Revenue and trends", url_path="revenue", default=True),
        st.Page(page_delivery, title="Delivery and satisfaction", url_path="delivery"),
        st.Page(page_sellers, title="Sellers and customers", url_path="sellers"),
        st.Page(page_cohorts, title="Cohort retention", url_path="cohorts"),
    ]
)
nav.run()
