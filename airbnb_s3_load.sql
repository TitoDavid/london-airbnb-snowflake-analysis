-- 0) Setup:
USE ROLE ACCOUNTADMIN;
CREATE WAREHOUSE IF NOT EXISTS TEST_WH WAREHOUSE_SIZE='XSMALL' AUTO_SUSPEND=60 AUTO_RESUME=TRUE;
USE WAREHOUSE TEST_WH;
CREATE DATABASE IF NOT EXISTS AIRBNB_DB;
CREATE SCHEMA IF NOT EXISTS AIRBNB_DB.RAW;
USE SCHEMA AIRBNB_DB.RAW;

CREATE OR REPLACE TABLE listings_raw (
  id NUMBER(38,0), last_scraped DATE, host_id NUMBER(38,0),
  host_is_superhost STRING, host_listings_count NUMBER(10,0), host_total_listings_count NUMBER(10,0),
  host_identity_verified STRING, neighbourhood_cleansed STRING, latitude FLOAT, longitude FLOAT,
  property_type STRING, room_type STRING, accommodates NUMBER(5,0), bathrooms FLOAT, bedrooms FLOAT,
  beds FLOAT, price NUMBER(10,2), minimum_nights NUMBER(10,0), maximum_nights NUMBER(10,0),
  availability_30 NUMBER(5,0), availability_365 NUMBER(5,0), number_of_reviews NUMBER(10,0),
  number_of_reviews_ltm NUMBER(10,0), first_review DATE, last_review DATE,
  review_scores_rating FLOAT, review_scores_cleanliness FLOAT, review_scores_location FLOAT,
  review_scores_value FLOAT, calculated_host_listings_count NUMBER(10,0),
  reviews_per_month FLOAT
);

-- 1) Storage integration
CREATE OR REPLACE STORAGE INTEGRATION s3_airbnb_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/<your_role_name>'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<your-bucket>/airbnb/');

DESC INTEGRATION s3_airbnb_int;

-- 2) File format and external stage
CREATE OR REPLACE FILE FORMAT csv_ff
  TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('');

CREATE OR REPLACE STAGE airbnb_s3_stage
  URL = 's3://<your-bucket>/airbnb/'
  STORAGE_INTEGRATION = s3_airbnb_int
  FILE_FORMAT = csv_ff;

LIST @airbnb_s3_stage;                          
SELECT $1, $2, $3, $4 FROM @airbnb_s3_stage LIMIT 5;

-- 3) Load from S3 into the table

COPY INTO listings_raw
FROM @airbnb_s3_stage
FILES = ('listings_slim.csv')
ON_ERROR = 'ABORT_STATEMENT';

-- 4) Verify
SELECT COUNT(*) AS rows_loaded, COUNT(DISTINCT id) AS unique_ids FROM listings_raw;
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'LISTINGS_RAW',
  START_TIME => DATEADD(hour, -2, CURRENT_TIMESTAMP())));