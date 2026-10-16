USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TEST_WH;
USE SCHEMA AIRBNB_DB.RAW;

-- 1) Confirmation that data was loaded from S3
SELECT FILE_NAME, STATUS, ROW_COUNT, ROW_PARSED, LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'LISTINGS_RAW',
  START_TIME => DATEADD(day, -3, CURRENT_TIMESTAMP())))
ORDER BY LAST_LOAD_TIME DESC;

-- 2) Data profiling
SELECT COUNT(*) AS total_rows,
       COUNT(price) AS price_filled,
       COUNT(neighbourhood_cleansed) AS borough_filled,
       COUNT(room_type) AS room_type_filled,
       COUNT(accommodates) AS accommodates_filled,
       COUNT(bedrooms) AS bedrooms_filled,
       COUNT(availability_365) AS availability_filled,
       COUNT(review_scores_rating) AS rating_filled,
       COUNT(calculated_host_listings_count) AS host_count_filled,
       COUNT(host_is_superhost) AS superhost_filled
FROM listings_raw;

-- 3) PRICE DISTRIBUTION
SELECT MIN(price) AS min_price,
       APPROX_PERCENTILE(price, 0.01) AS p01,
       APPROX_PERCENTILE(price, 0.25) AS p25,
       MEDIAN(price)                  AS median,
       APPROX_PERCENTILE(price, 0.75) AS p75,
       APPROX_PERCENTILE(price, 0.99) AS p99,
       MAX(price) AS max_price
FROM listings_raw;

-- 4) VIEW creation
CREATE SCHEMA IF NOT EXISTS AIRBNB_DB.ANALYTICS;
CREATE OR REPLACE VIEW AIRBNB_DB.ANALYTICS.listings_clean AS
SELECT
  id AS listing_id, host_id, last_scraped,
  neighbourhood_cleansed AS borough,
  property_type, room_type, accommodates, bedrooms,
  price, minimum_nights, availability_365,
  number_of_reviews, review_scores_rating AS rating, last_review,
  calculated_host_listings_count AS host_listing_count,
  latitude, longitude,
  CASE WHEN price IS NULL THEN 'missing'
       WHEN price < 10    THEN 'too_low'
       WHEN price > 2000  THEN 'too_high'      -- adjust after looking at step 3
       ELSE 'ok' END AS price_flag,
  CASE WHEN calculated_host_listings_count >= 10 THEN '3. Large operator (10+)'
       WHEN calculated_host_listings_count >= 2  THEN '2. Multi-listing host (2-9)'
       ELSE '1. Single-listing host' END AS host_type
FROM AIRBNB_DB.RAW.listings_raw;

USE SCHEMA AIRBNB_DB.ANALYTICS;

-- 5) Data quality analysis
SELECT price_flag, COUNT(*) AS listings,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS pct
FROM listings_clean GROUP BY price_flag ORDER BY listings DESC;

-- 6) MEDIAN PRICE BY BOROUGH
SELECT borough, COUNT(*) AS listings, ROUND(MEDIAN(price), 0) AS median_price
FROM listings_clean
WHERE price_flag = 'ok'
GROUP BY borough
HAVING COUNT(*) >= 100
ORDER BY median_price DESC;

-- 7) ROOM TYPE MIX AND PRICE
SELECT room_type, COUNT(*) AS listings,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS pct_of_listings,
       ROUND(MEDIAN(price), 0) AS median_price
FROM listings_clean WHERE price_flag = 'ok'
GROUP BY room_type ORDER BY listings DESC;

-- 8) BOROUGH RANKING WITHIN EACH ROOM TYPE
WITH stats AS (
  SELECT room_type, borough, COUNT(*) AS listings, MEDIAN(price) AS median_price
  FROM listings_clean WHERE price_flag = 'ok'
  GROUP BY room_type, borough HAVING COUNT(*) >= 50
)
SELECT room_type, borough, listings, ROUND(median_price, 0) AS median_price,
       RANK() OVER (PARTITION BY room_type ORDER BY median_price DESC) AS price_rank
FROM stats
QUALIFY price_rank <= 5
ORDER BY room_type, price_rank;

-- 9) HOST CONCENTRATION or who runs the listings?
SELECT host_type, COUNT(*) AS listings,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS pct_of_listings,
       ROUND(MEDIAN(price), 0) AS median_price
FROM listings_clean WHERE price_flag = 'ok'
GROUP BY host_type ORDER BY host_type;

-- 10) price per guest vs rating, well-reviewed listings only
SELECT borough, COUNT(*) AS listings,
       ROUND(MEDIAN(price / NULLIF(accommodates, 0)), 1) AS median_price_per_guest,
       ROUND(AVG(rating), 2) AS avg_rating
FROM listings_clean
WHERE price_flag = 'ok' AND number_of_reviews >= 10 AND rating IS NOT NULL
GROUP BY borough HAVING COUNT(*) >= 50
ORDER BY avg_rating DESC, median_price_per_guest ASC
LIMIT 10;

-- 11) INACTIVE LISTINGS: no availability or no recent review
SELECT borough, COUNT(*) AS listings,
       ROUND(100 * AVG(IFF(availability_365 = 0, 1, 0)), 1) AS pct_no_availability,
       ROUND(100 * AVG(IFF(last_review IS NULL
                           OR DATEDIFF('day', last_review, last_scraped) > 365, 1, 0)), 1) AS pct_no_recent_review
FROM listings_clean
GROUP BY borough HAVING COUNT(*) >= 100
ORDER BY pct_no_availability DESC;

-- 12) PRICE BY NUMBER OF BEDROOMS (entire homes only)
SELECT CASE WHEN bedrooms >= 5 THEN '5+' ELSE TO_VARCHAR(bedrooms::INT) END AS "Bedrooms",
       COUNT(*) AS "Priced listings",
       ROUND(MEDIAN(price), 0) AS "Median nightly price"
FROM listings_clean
WHERE price_flag = 'ok' AND room_type = 'Entire home/apt' AND bedrooms IS NOT NULL
GROUP BY 1
ORDER BY MIN(bedrooms);

-- 13) Followup query to find why are so many prices missing?
SELECT availability_365 = 0 AS no_availability,
       COUNT(*) AS listings,
       COUNT_IF(price IS NULL) AS missing_price,
       ROUND(100 * AVG(IFF(price IS NULL, 1, 0)), 1) AS pct_missing_price
FROM listings_clean
GROUP BY 1;