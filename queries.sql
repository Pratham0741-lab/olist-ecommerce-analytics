-- Olist business questions (SQLite).
-- Each query starts with "-- name: <id>" so analysis.ipynb and app.py can run it by name.
-- Conventions used throughout:
--   * Analysis window = orders purchased 2017-01-01 .. 2018-08-31 (orders.in_window = 1).
--   * Revenue = sum of item price (excludes freight) for orders that became a sale
--     (status not 'canceled' / 'unavailable', orders.is_sale = 1).
--   * Items are aggregated to one row per order BEFORE joining, to avoid the row
--     multiplication you get when an order with 3 items is joined to its reviews.
--   * A "customer" is customer_unique_id. customer_id is new for every order.
-- FINDING lines come from the outputs in analysis.ipynb.

-- name: monthly_revenue
-- QUESTION: How did monthly revenue and order volume trend, and how fast did it grow?
-- FINDING: Revenue grew from R$120k (Jan 2017) to a plateau of R$838k-994k/month in 2018.
-- Jan-Aug 2018 revenue (R$7.34M) was 138.3% above Jan-Aug 2017 (R$3.08M). Nov 2017 is the
-- single biggest month (R$1.00M, +52.1% MoM, Black Friday). Growth flattened after Jan 2018.
WITH order_value AS (
    SELECT order_id, SUM(price) AS item_value
    FROM order_items
    GROUP BY order_id
),
monthly AS (
    SELECT o.purchase_month,
           COUNT(*)                      AS orders,
           ROUND(SUM(v.item_value), 2)   AS revenue
    FROM orders o
    JOIN order_value v ON v.order_id = o.order_id
    WHERE o.in_window = 1 AND o.is_sale = 1
    GROUP BY o.purchase_month
)
SELECT purchase_month,
       orders,
       revenue,
       ROUND(SUM(revenue) OVER (ORDER BY purchase_month), 2)                  AS running_revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY purchase_month))
             / LAG(revenue) OVER (ORDER BY purchase_month), 1)                AS mom_growth_pct
FROM monthly
ORDER BY purchase_month;

-- name: top_categories
-- QUESTION: Which product categories bring in the most revenue, and how concentrated is it?
-- FINDING: health_beauty (9.30%), watches_gifts (8.88%) and bed_bath_table (7.70%) lead. Revenue is
-- spread out: the top 7 categories make up 49.88% of revenue, the top 15 make up 76.32%.
WITH cat AS (
    SELECT p.product_category                AS category,
           COUNT(DISTINCT oi.order_id)       AS orders,
           ROUND(SUM(oi.price), 2)           AS revenue
    FROM order_items oi
    JOIN orders o   ON o.order_id = oi.order_id
    JOIN products p ON p.product_id = oi.product_id
    WHERE o.in_window = 1 AND o.is_sale = 1
    GROUP BY p.product_category
)
SELECT RANK() OVER (ORDER BY revenue DESC)                               AS revenue_rank,
       category,
       orders,
       revenue,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)                  AS revenue_share_pct,
       ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC
                                        ROWS UNBOUNDED PRECEDING)
             / SUM(revenue) OVER (), 2)                                  AS cumulative_share_pct
FROM cat
ORDER BY revenue_rank
LIMIT 15;

-- name: delay_vs_review
-- QUESTION: How does delivery delay relative to the promised date relate to review score?
-- Uses COUNT(*) for orders and COUNT(review_score) for reviewed orders: they differ
-- because some delivered orders have no review (NULL score after the LEFT JOIN).
-- FINDING: Review scores fall sharply once an order is late. Orders arriving 7+ days early average
-- 4.31 stars; 1-3 days late average 3.29; 4-7 days late average 2.10, and 67.7% of those are
-- 1-2 star reviews. Most orders (75,882 of 96,203) arrive 7+ days before the promised date.
WITH delivered AS (
    SELECT o.order_id,
           o.delay_days,
           r.review_score,
           CASE
               WHEN o.delay_days <= -7 THEN '1. 7+ days early'
               WHEN o.delay_days <= 0  THEN '2. 0-6 days early'
               WHEN o.delay_days <= 3  THEN '3. 1-3 days late'
               WHEN o.delay_days <= 7  THEN '4. 4-7 days late'
               WHEN o.delay_days <= 14 THEN '5. 8-14 days late'
               ELSE                         '6. 15+ days late'
           END AS delay_bucket
    FROM orders o
    LEFT JOIN order_reviews r ON r.order_id = o.order_id
    WHERE o.in_window = 1
      AND o.order_status = 'delivered'
      AND o.delay_days IS NOT NULL
)
SELECT delay_bucket,
       COUNT(*)                                        AS delivered_orders,
       COUNT(review_score)                             AS reviewed_orders,
       ROUND(AVG(review_score), 3)                     AS avg_review,
       ROUND(100.0 * SUM(review_score <= 2) / COUNT(review_score), 1) AS pct_1_or_2_stars
FROM delivered
GROUP BY delay_bucket
ORDER BY delay_bucket;

-- name: late_vs_ontime
-- QUESTION: Overall, what is the review gap between late and on-time orders, and how much
-- revenue sits in late orders?
-- FINDING: 6.79% of delivered orders (6,531) were late. They average 2.27 stars vs 4.29 for on-time
-- orders (a 2.02-point gap) and account for R$986k, or 7.48%, of delivered-order revenue.
WITH order_value AS (
    SELECT order_id, SUM(price) AS item_value FROM order_items GROUP BY order_id
)
SELECT CASE WHEN o.is_late = 1 THEN 'late' ELSE 'on_time' END   AS delivery,
       COUNT(*)                                                   AS delivered_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)         AS pct_of_orders,
       COUNT(r.review_score)                                      AS reviewed_orders,
       ROUND(AVG(r.review_score), 3)                              AS avg_review,
       ROUND(SUM(v.item_value), 2)                                AS revenue
FROM orders o
JOIN order_value v        ON v.order_id = o.order_id
LEFT JOIN order_reviews r ON r.order_id = o.order_id
WHERE o.in_window = 1 AND o.order_status = 'delivered' AND o.is_late IS NOT NULL
GROUP BY delivery
ORDER BY delivery;

-- name: repeat_customer_rate
-- QUESTION: What share of customers buy more than once? And how wrong would we be if we
-- counted customer_id instead of customer_unique_id?
-- FINDING: Only 3.04% of customers (2,875 of 94,707 customer_unique_ids) ordered more than once.
-- Using customer_id instead reports 0 repeat customers, because customer_id is new per order.
WITH per_person AS (
    SELECT c.customer_unique_id, COUNT(*) AS n_orders
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.in_window = 1 AND o.is_sale = 1
    GROUP BY c.customer_unique_id
),
per_customer_id AS (
    SELECT customer_id, COUNT(*) AS n_orders
    FROM orders
    WHERE in_window = 1 AND is_sale = 1
    GROUP BY customer_id
)
SELECT 'customer_unique_id' AS customer_key,
       COUNT(*)                                             AS customers,
       SUM(n_orders >= 2)                                   AS repeat_customers,
       ROUND(100.0 * SUM(n_orders >= 2) / COUNT(*), 2)      AS repeat_rate_pct,
       ROUND(AVG(n_orders), 4)                              AS avg_orders_per_customer
FROM per_person
UNION ALL
SELECT 'customer_id (wrong key)',
       COUNT(*),
       SUM(n_orders >= 2),
       ROUND(100.0 * SUM(n_orders >= 2) / COUNT(*), 2),
       ROUND(AVG(n_orders), 4)
FROM per_customer_id;

-- name: worst_sellers
-- QUESTION: Which sellers with meaningful volume (>= 50 delivered orders) have the worst
-- reviews, and is lateness part of the story?
-- An order with items from two sellers counts once for each seller.
-- FINDING: Of 424 sellers with 50+ delivered orders, the worst averages 2.39 stars (108 orders, 16.7%
-- late). Lateness explains part but not all of it: the bottom 10 have late rates of 6.5%-30.1%,
-- so product or listing quality likely matters for some (not testable with this data).
WITH seller_orders AS (
    SELECT DISTINCT oi.seller_id, oi.order_id
    FROM order_items oi
),
stats AS (
    SELECT so.seller_id,
           COUNT(*)                          AS delivered_orders,
           COUNT(r.review_score)             AS reviewed_orders,
           ROUND(AVG(r.review_score), 3)     AS avg_review,
           ROUND(100.0 * AVG(o.is_late), 1)  AS late_rate_pct
    FROM seller_orders so
    JOIN orders o             ON o.order_id = so.order_id
    LEFT JOIN order_reviews r ON r.order_id = so.order_id
    WHERE o.in_window = 1 AND o.order_status = 'delivered'
    GROUP BY so.seller_id
    HAVING COUNT(*) >= 50
)
SELECT RANK() OVER (ORDER BY avg_review ASC) AS worst_rank,
       s.seller_id,
       se.seller_state,
       s.delivered_orders,
       s.reviewed_orders,
       s.avg_review,
       s.late_rate_pct,
       (SELECT COUNT(*) FROM stats)          AS sellers_with_50_plus
FROM stats s
JOIN sellers se ON se.seller_id = s.seller_id
ORDER BY worst_rank
LIMIT 10;

-- name: payment_mix
-- QUESTION: How do customers pay, and how many instalments do card buyers use?
-- COUNT(*) counts payment rows; COUNT(DISTINCT order_id) counts orders, because one
-- order can be split across several payment rows (e.g. card + voucher).
-- FINDING: Credit card carries 78.46% of payment value, with an average of 3.5 instalments. Boleto
-- (bank slip) is 17.96%. Vouchers appear on 3,734 orders but in 5,590 rows, so vouchers are
-- often split into several payment rows: COUNT(*) would overstate voucher orders by ~50%.
SELECT p.payment_type,
       COUNT(*)                                              AS payment_rows,
       COUNT(DISTINCT p.order_id)                            AS orders_using_type,
       ROUND(SUM(p.payment_value), 2)                        AS payment_value,
       ROUND(100.0 * SUM(p.payment_value)
             / SUM(SUM(p.payment_value)) OVER (), 2)         AS value_share_pct,
       ROUND(AVG(p.payment_installments), 2)                 AS avg_installments
FROM order_payments p
JOIN orders o ON o.order_id = p.order_id
WHERE o.in_window = 1 AND o.is_sale = 1
GROUP BY p.payment_type
ORDER BY payment_value DESC;

-- name: state_delivery
-- QUESTION: Which customer states get the slowest and latest deliveries?
-- FINDING: Northeastern states wait longest and are late most often: AL 21.5% late (24.5 days avg),
-- MA 17.5%. RJ is the largest problem by volume: 12,310 orders with a 12.1% late rate vs 4.5% in
-- SP. Across the 24 states with 100+ orders, late rate and avg review correlate at r = -0.91.
SELECT c.customer_state,
       COUNT(*)                                   AS delivered_orders,
       ROUND(AVG(o.delivery_days), 1)             AS avg_delivery_days,
       ROUND(100.0 * AVG(o.is_late), 1)           AS late_rate_pct,
       ROUND(AVG(r.review_score), 3)              AS avg_review
FROM orders o
JOIN customers c          ON c.customer_id = o.customer_id
LEFT JOIN order_reviews r ON r.order_id = o.order_id
WHERE o.in_window = 1 AND o.order_status = 'delivered' AND o.delivery_days IS NOT NULL
GROUP BY c.customer_state
HAVING COUNT(*) >= 100
ORDER BY late_rate_pct DESC;

-- name: cohort_retention
-- QUESTION: Of the customers who first bought in a given month, what share bought again
-- 1, 2, 3 ... months later?
-- A cohort is the month of a person's (customer_unique_id) first sale order in the window.
-- month_offset 0 is the first-purchase month; retention_pct at offset k is the share of the
-- cohort with at least one sale order k calendar months later. Later cohorts are observed
-- for fewer months (the data stops in Aug 2018), so the triangle is incomplete.
-- FINDING: see the cohort retention section of analysis.ipynb.
WITH person_orders AS (
    SELECT DISTINCT c.customer_unique_id,
           CAST(substr(o.purchase_month, 1, 4) AS INTEGER) * 12
             + CAST(substr(o.purchase_month, 6, 2) AS INTEGER) AS month_idx,
           o.purchase_month
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.in_window = 1 AND o.is_sale = 1
),
first_month AS (
    SELECT customer_unique_id, MIN(month_idx) AS cohort_idx
    FROM person_orders
    GROUP BY customer_unique_id
),
cohort_size AS (
    SELECT cohort_idx, COUNT(*) AS cohort_customers FROM first_month GROUP BY cohort_idx
),
activity AS (
    SELECT f.cohort_idx,
           p.month_idx - f.cohort_idx               AS month_offset,
           COUNT(DISTINCT p.customer_unique_id)     AS active_customers
    FROM person_orders p
    JOIN first_month f ON f.customer_unique_id = p.customer_unique_id
    GROUP BY f.cohort_idx, month_offset
)
SELECT printf('%04d-%02d', (a.cohort_idx - 1) / 12, (a.cohort_idx - 1) % 12 + 1) AS cohort_month,
       s.cohort_customers,
       a.month_offset,
       a.active_customers,
       ROUND(100.0 * a.active_customers / s.cohort_customers, 3)              AS retention_pct
FROM activity a
JOIN cohort_size s ON s.cohort_idx = a.cohort_idx
ORDER BY cohort_month, a.month_offset;

-- ===========================================================================
-- Canonical metric definitions. The single source of truth: the metric
-- definitions page in analysis.ipynb is generated from these, and the
-- dashboard's KPI tiles run them.
-- Each query returns one row with a column called `value` (plus context columns).
-- Every metric uses the analysis window: orders purchased 2017-01-01 .. 2018-08-31.

-- name: revenue
-- DEFINITION: Sum of item prices (excluding freight) on orders purchased in the window
-- whose status is not 'canceled' or 'unavailable'. In Brazilian reais (R$).
SELECT ROUND(SUM(oi.price), 2) AS value,
       COUNT(DISTINCT o.order_id) AS orders
FROM order_items oi
JOIN orders o ON o.order_id = oi.order_id
WHERE o.in_window = 1 AND o.is_sale = 1;

-- name: active_customers
-- DEFINITION: Number of distinct people (customer_unique_id, not customer_id) with at
-- least one sale order (not canceled/unavailable) purchased in the period. For a single
-- month, add `AND o.purchase_month = 'YYYY-MM'`.
SELECT COUNT(DISTINCT c.customer_unique_id) AS value
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
WHERE o.in_window = 1 AND o.is_sale = 1;

-- name: repeat_customers
-- DEFINITION: Active customers with 2 or more sale orders in the window. The rate is
-- repeat customers divided by active customers. Two orders on the same day count as two.
WITH per_person AS (
    SELECT c.customer_unique_id, COUNT(*) AS n_orders
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.in_window = 1 AND o.is_sale = 1
    GROUP BY c.customer_unique_id
)
SELECT SUM(n_orders >= 2)                              AS value,
       COUNT(*)                                        AS active_customers,
       ROUND(100.0 * SUM(n_orders >= 2) / COUNT(*), 2) AS rate_pct
FROM per_person;

-- name: late_delivery_rate
-- DEFINITION: Share of delivered orders (status 'delivered' with a delivery date) whose
-- delivery date falls on a later calendar day than the estimated delivery date shown to
-- the customer. Delivered on the estimated day counts as on time. In percent.
SELECT ROUND(100.0 * AVG(is_late), 2) AS value,
       SUM(is_late = 1)               AS late_orders,
       COUNT(*)                       AS delivered_orders
FROM orders
WHERE in_window = 1 AND order_status = 'delivered' AND is_late IS NOT NULL;

-- name: avg_review_score
-- DEFINITION: Mean review score (1-5) over delivered orders in the window that have a
-- review. One review per order (the latest answered). Orders without a review are left
-- out, not counted as zero.
SELECT ROUND(AVG(r.review_score), 3) AS value,
       COUNT(r.review_score)         AS reviewed_orders
FROM orders o
JOIN order_reviews r ON r.order_id = o.order_id
WHERE o.in_window = 1 AND o.order_status = 'delivered';
