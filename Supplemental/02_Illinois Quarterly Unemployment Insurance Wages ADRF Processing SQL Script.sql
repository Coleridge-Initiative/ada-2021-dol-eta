--DOI: https://doi.org/10.5281/zenodo.4588936
--This script is used to process the quarterly UI wages file 
--from the Illinois Department of Employment Security (IDES)

--This script:
--  1. Combines quarterly tables from 2019 into an annual table
--  2. Selects a subset of columns and converts them to their final datatypes
--  3. Replaces the hashed Social Security number with an integer surrogate value

--Sources: il_des_kcmo.il_wage_2019q1, which contains Illinois wages from Q1 2019
--         il_des_kcmo.il_wage_2019q2, which contains Illinois wages from Q2 2019 
--         il_des_kcmo.il_wage_2019q3, which contains Illinois wages from Q3 2019
--         il_des_kcmo.il_wage_2019q4, which contains Illinois wages from Q4 2019

--Targets: il_covid_wf.quarter_wages, which combines cleaned wages for the year 2019 into a single table
--         il_covid_wf.claimant_wage_ssn, which relates the surrogate ssn_id to the original hashed Social Security number
--         Note: there are also versions of these tables with a _s suffix. 
--          Those tables are meant to temporarily store records as an intermediate
--			step when updating the similarly-named tables without the suffix.

--Update frequency: quarterly


--Combine quarterly records for 2019 into one table.
--Select a subset of columns and convert column data types.
--Note that there is more recent data available at the time of this writing,
--but we will just be looking at 2019 wages for the training.

DROP TABLE IF EXISTS il_covid_wf.quarter_wages_s;

CREATE TABLE il_covid_wf.quarter_wages_s AS
SELECT year::smallint,
	quarter::smallint,
	ssn::varchar(64),
	empr_no::varchar(10),
	wage::numeric
FROM (
	SELECT year,
		quarter,
		ssn,
		empr_no,
		wage
	FROM il_des_kcmo.il_wage_2019q4
	WHERE year = 2019 --There are a small number known bad records that can be excluded by limiting to the expected year and quarter
	AND quarter = 4
	UNION
	SELECT year,
		quarter,
		ssn,
		empr_no,
		wage
	FROM il_des_kcmo.il_wage_2019q3
	WHERE year = 2019
	AND quarter = 3
	UNION
	SELECT year,
		quarter,
		ssn,
		empr_no,
		wage
	FROM il_des_kcmo.il_wage_2019q2
	WHERE year = 2019
	AND quarter = 2
	UNION
	SELECT year,
		quarter,
		ssn,
		empr_no,
		wage
	FROM il_des_kcmo.il_wage_2019q1
	WHERE year = 2019
	AND quarter = 1
) _;


--The next several blocks of code replace the hashed Social Security number with an integer surrogate.
--This makes the table take up less space on disk and is especially useful when many people will
--be using a large dataset at once, but it is not a requirement for analyzing this data.

--Insert all incoming hashed SSNs into claimant_wage_ssn_s
TRUNCATE TABLE il_covid_wf.claimant_wage_ssn_s;

INSERT INTO il_covid_wf.claimant_wage_ssn_s
SELECT DISTINCT ssn
FROM il_covid_wf.quarter_wages_s;

--If any of these do not yet appear in il_covid_wf.claimant_wage_ssn, insert them.
--Inserting these records will generate additional values of ssn_id
INSERT INTO il_covid_wf.claimant_wage_ssn (ssn)
SELECT a.ssn
FROM il_covid_wf.claimant_wage_ssn_s a
LEFT JOIN il_covid_wf.claimant_wage_ssn b
ON a.ssn = b.ssn
WHERE b.ssn IS NULL;


--Create the target table with a well-defined primary key
--(This table should already exist at this point of our process,
--but the table definition statement is included for reference.)
CREATE TABLE IF NOT EXISTS il_covid_wf.quarter_wages (
	year integer,
	quarter integer,
	ssn_id integer,
	empr_no varchar(10),
	wage numeric,
	date_updated date,
	PRIMARY KEY (year, quarter, ssn_id, empr_no) --This ensures that the resulting table has one record per earner and employer in each quarter
);

--Clear the target table; we reload the whole thing each time, but run the load infrequently.
TRUNCATE TABLE il_covid_wf.quarter_wages;

--Insert wage records with the surrogate SSN ID included into the target table
INSERT INTO il_covid_wf.quarter_wages
SELECT a.year, --The calendar year
	a.quarter, --The quarter number (1-4)
	b.ssn_id, --The surrogate SSN ID for the claimant
	a.empr_no, --Account number for the employer
	a.wage, --Wages earned in the quarter
	now()::date AS date_updated --The date the table was updated
FROM il_covid_wf.quarter_wages_s a
LEFT JOIN il_covid_wf.claimant_wage_ssn b
ON a.ssn = b.ssn;
