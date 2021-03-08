--This script is used to build the dataset for the ETA training program
--It joins certified claims data to wages and selects a subset of the columns most relevant for the training.
--Also creates a version of the table based on a 1% sample of 2020 claimants.

--This script:
--  1. Creates a view that aggregates 2019 wages to the earner level
--  2. Limit claim records to the year 2020 and onward, select a subset of columns for the ETA raining
--  3. Join claimant 2019 wage data to 2020 certified claims using hashed SSN
--  4. Select a random 1% sample of claimants appearing in 2020
--  5. Make a subset of the cleaned certified claimant data for the sample of claimants

--Sources:  il_covid_wf.claimant_weeks, which contains cleaned weekly certified claims data
--			il_covid_wf.quarter_wages, which contains cleaned quarterly wage data
--Targets:  il_covid_wf.il_des_promis, which contains the full ETA training dataset
--			il_covid_wf.il_des_promis_1pct, which contains a 1% sample of claimants from the full dataset

--Update frequency: intermittently depending on training program needs


--Aggregate 2019 quarterly wages to the earner level
DROP VIEW IF EXISTS il_covid_wf.wages_2019;

CREATE OR REPLACE VIEW il_covid_wf.wages_2019 AS
SELECT ssn_id,
	sum(wage) AS wages_2019
FROM il_covid_wf.quarter_wages
WHERE year = 2019
GROUP BY ssn_id;

--Join wages to subset of claimant records from 2020 onward
DROP TABLE IF EXISTS il_covid_wf.il_des_promis;

CREATE TABLE il_covid_wf.il_des_promis AS
SELECT a.ssn_id, --Surrogate SSN ID
	a.week_end_date, --Saturday ending the benefit week
	a.byr_start_week, --Benefit year start week
	a.sub_program_type, --Entitlement type (regular, extended, etc.)
	a.program_type, --Program type (regular, UCFE, UCX, etc.)
	a.claim_type, --Claim type (new, additional, transitional, etc)
	a.payment_type, --Payment type (regular, supplement, waiting week, overpayment)
	a.birth_date, --Claimant date of birth
	a.gender, --Claimant gender
	a.race, --Claimant race
	a.ethnicity, --Claimant ethnicity
	a.disability, --Claimant disability
	a.education, --Claimant educational attainment
	a.county_fips_code, --Claimant county of residence FIPS code
	a.naics_code, --NAICS code (6 digits) for the last employer
	a.occupation_major_code AS occupation_code, --Standard Occupation Code (2 digits) for the last employer
	a.weekly_benefit_amount, --Weekly benefit amount
	a.total_pay, --Total benefit amount actually paid for the week. (Includes WBA plus supplements minus deductions.)
	b.wages_2019, --2019 wages
	now()::date AS date_updated --The date the table was updated
FROM il_covid_wf.claimant_weeks a
LEFT JOIN il_covid_wf.wages_2019 b
ON a.ssn_id = b.ssn_id
WHERE a.week_end_date >= date '2020-01-01';

--Create a primary key on ssn_id + week_end_date. This will guarantee that there is only
--one record per claimant in each benefit week.
ALTER TABLE il_covid_wf.il_des_promis ADD PRIMARY KEY (ssn_id, week_end_date);

--Select a 1% random sample of claimants appearing in 2020
DROP TABLE IF EXISTS il_covid_wf.training_sample;

CREATE TABLE il_covid_wf.training_sample AS
WITH id_list AS (
	SELECT DISTINCT ssn_id
	FROM il_covid_wf.claimant_weeks_ada
)
SELECT ssn_id
FROM id_list
ORDER BY random()
LIMIT (SELECT count(*)*.01 FROM id_list);

--Subset il_covid_wf.il_des_promis to the individuals included in the 1% sample
DROP TABLE IF EXISTS il_covid_wf.il_des_promis_1pct;

CREATE TABLE il_covid_wf.il_des_promis_1pct AS
SELECT *
FROM il_covid_wf.claimant_weeks_ada
WHERE ssn_id IN
(
	SELECT ssn_id
	FROM il_covid_wf.il_des_promis
);

--Create a primary key on ssn_id + week_end_date. This will guarantee that there is only
--one record per claimant in each benefit week.
ALTER TABLE il_covid_wf.il_des_promis_1pct ADD PRIMARY KEY (ssn_id, week_end_date);
