# Olist e-commerce analytics

SQL analysis and a 4-page Streamlit dashboard built on ~99k real orders from Olist, a Brazilian marketplace. The aim is to answer questions a marketplace manager would act on: where revenue comes from, what delivery delays do to customer reviews, which sellers drag ratings down, and how many customers come back.

## Problem

Olist's 2018 revenue was flat month to month. Management wants to know where to focus: delivery, seller quality or customer retention. Every answer should come with a number behind it.

## Data source and license

- **Brazilian E-Commerce Public Dataset by Olist**, Kaggle: <https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce>
- **License: CC BY-NC-SA 4.0** (checked against the Kaggle metadata). You can use it for non-commercial work with attribution, and must share derivatives under the same license. Raw data is not committed.
- 9 linked CSVs: orders, customers, items, payments, reviews, products, sellers, geolocation, category translation. Orders are from Sep 2016 to Oct 2018.

## What's in the project

| File | What it is |
| --- | --- |
| `analysis.ipynb` | All the analysis: data quality, cleaning + validation, SQL, metrics, cohorts, sizing and the memo |
| `queries.sql` | The named SQL queries and metric definitions, used by both the notebook and the dashboard |
| `app.py` | 4-page Streamlit dashboard |
| `requirements.txt` | Pinned dependencies |

The notebook is saved with its outputs (tables and charts), so you can read it on GitHub without running it:

1. **Raw data profile and data quality**: 42 checks (impossible or inverted dates, orphan rows, duplicate reviews, missing and odd values), each with a count and the rule the pipeline applies.
2. **Cleaning, SQLite load and validation** with vectorised pandas. A customer is `customer_unique_id`; the analysis window is Jan 2017 to Aug 2018; revenue is item price excluding canceled and unavailable orders. 27 validation checks stop the notebook if any fails.
3. **SQL analysis** (CTEs, window functions, aggregating items before joining), headline metrics and a metric definitions page generated from `queries.sql`.
4. **Cohort retention** by month of first purchase.
5. **Sizing** each recommendation from the data, with stated assumptions.
6. **Memo**: three actions for marketplace operations.

## Results

Window: 97,905 orders, Jan 2017 to Aug 2018. All figures come from `analysis.ipynb`.

| Finding | Number |
| --- | --- |
| Revenue in window (item price) | R$ 13.45M |
| Growth, Jan-Aug 2018 vs Jan-Aug 2017 | +138.3% |
| 2018 monthly revenue | flat, R$ 838k to 994k |
| Delivered orders that arrived late | 6.79% (6,531) |
| Average review, late vs on time | 2.27 vs 4.29 stars |
| 1-2 star share for orders 4-7 days late | 67.7% (vs 9.0% for 7+ days early) |
| Revenue in late orders | R$ 986k (7.48% of delivered revenue) |
| Late rate, RJ vs SP | 12.1% vs 4.5% |
| State late rate vs avg review (24 states) | r = -0.91 |
| Repeat-customer rate (customer_unique_id) | 3.04% (2,875 of 94,707) |
| Repeat rate using customer_id by mistake | 0.00% |
| Bottom 10% of sellers (42 of 424 with 50+ orders) | 6.61% of seller orders, 13.1% of 1-2 star reviews |
| Credit card share of payment value | 78.46%, avg 3.5 instalments |

**Data quality**: 32 of 42 checks found at least one row. No order is delivered before it was bought and there are no orphan rows, but 1,359 orders were handed to the carrier before payment approval, 166 before purchase, 23 reached the customer before the carrier, and 789 review IDs are shared across 1,603 rows (one review covering several orders). None of these feed a metric except as documented. All 27 validation checks pass on the cleaned data.

**Cohort retention**: month-1 retention is **0.48%** (customer-weighted, 19 cohorts) and no cohort keeps 1% of its customers active in any later month (highest cell 0.71%). Within 6 months, 3.28% of customers order again, but almost half of that (1.60 points) is a second order in the same month as the first. Olist is a one-purchase marketplace in this data, and cohort-to-cohort differences are a few customers per cell, so they are mostly noise.

**Sized recommendations** (all estimates with stated assumptions):

| Recommendation | Estimated effect |
| --- | --- |
| Bring every state's late rate down to SP's (4.50%) | ~2,234 fewer late orders, ~1,188 fewer 1-2 star reviews; only ~R$1.6k extra revenue via repeat buying |
| Bottom 42 sellers reach the median 1-2 star rate (12.0% vs 26.4%) | ~919 fewer 1-2 star reviews (7.1% of all) |
| Second-purchase offer after an on-time 4-5 star order (baseline 90-day repeat 1.33%) | +0.5 / +1 / +2 pp lift ≈ R$22k / R$45k / R$89k a year, net of a 10% discount |

**Recommendations** (details in the memo): fix late deliveries into RJ and the Northeast first, put the lowest-rated sellers on a performance plan, and A/B test a second-purchase offer.

## What didn't work

- **A seller count that didn't match (417 vs 424).** The first metrics script joined orders to reviews with an INNER JOIN, so unreviewed orders vanished and some sellers dropped under 50 orders. A LEFT JOIN fixed it.
- **A dashboard bar that silently disappeared.** Plotly read the order-count labels "1", "2", "3" as numbers and dropped "4+". It was caught because the bars summed to 94,659 instead of 94,707; forcing a categorical axis fixed it.
- **Late deliveries as a revenue lever.** The memo's first recommendation looked like a revenue win. Sizing it showed it isn't: customers whose first order was late return almost as often (2.58% vs 3.12%), so fixing lateness is worth about R$1.6k through repeat purchases. It's still worth doing for reviews, not for revenue.
- **Cohort trends.** I hoped the cohort heatmap would show whether retention was improving. With month-1 retention at 0.48%, each cell is a handful of customers, so there's no trend to read. And almost half of the "repeat within 6 months" customers just placed a second order in the same month.

## Limitations

- **Sizing estimates assume cause.** They treat associations (late → bad review) as if removing the cause removes the effect, and the second-purchase lift is an assumption, not a measurement. They are for ranking ideas, not forecasts.

- **Correlation, not cause.** Late orders get much worse reviews, but region, product type or seller could drive both. A controlled comparison or experiment would be needed to claim cause.
- **Revenue excludes freight**, and orders with status `shipped`/`invoiced`/`processing` count as sales even though some may later have been canceled.
- **Latest review per order** is a judgment call. For 202 orders the multiple reviews disagree; taking the first or the average would shift results very slightly.
- **Repeat rate is low partly by design of the sample.** It covers 20 months, and the public dataset is a sample of Olist orders, so the true repeat rate could differ.
- **Seller ratings** treat an order with two sellers as one order for each seller, so a bad experience caused by one seller also counts against the other.
- **Dashboard is local only.** It has not been deployed (Streamlit Community Cloud would need the database built at startup, because data isn't committed).

## How to run

Needs Python 3.11.

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate    macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
```

Get the data (free Kaggle download), then unzip the 9 CSVs into `data/`:

```bash
curl -L -o data/olist.zip https://www.kaggle.com/api/v1/datasets/download/olistbr/brazilian-ecommerce
cd data && unzip olist.zip && rm olist.zip && cd ..
```

Run the analysis (or open `analysis.ipynb` and run all cells):

```bash
jupyter nbconvert --to notebook --execute --inplace analysis.ipynb
```

Then start the app:

```bash
streamlit run app.py
```
