--DOI: https://doi.org/10.5281/zenodo.4589127
--This script is used to process the weekly UI certified
--claims file from the Illinois Department of Employment Security (IDES)

--This script:
--  1. Selects records from the source table for certification weeks that are not yet in the target table
--  2. Selects a subset of columns, converts them to their final datatypes, and performs some recoding
--  3. Ensures this selection contains only one record per claimant per benefit week
--  4. Replaces (in this case hashed) Social Security number with an integer surrogate value
--  5. Calculates benefit year start week based on benefit year start date
--  6. Appends the updated records to the target table

--Sources: il_des_claimants.promis_continued, which contains raw certified claims records. 
--			The new certified claims file is appended to this each week.
--		   il_covid_wf.occupation_major_code, which relates integer occupation code from the IDES system to Standard Occupation Code

--Targets: il_covid_wf.claimant_weeks, which contains a selection of certified claimants data cleaned for research
--         il_covid_wf.claimant_wage_ssn, which relates the surrogate ssn_id to the original hashed Social Security number
--         Note: there are also versions of these tables with a _s suffix. 
--          Those tables are meant to temporarily store records as an intermediate
--			step when updating the similarly-named tables without the suffix.

--Update frequency: weekly

--Limit to records that have not yet been loaded into the target table by selecting all the source records 
--with a certification week that does not appear in the target table.
DROP VIEW IF EXISTS il_covid_wf.new_records;

CREATE OR REPLACE VIEW il_covid_wf.new_records AS
SELECT claimant_id_number, 
	social_security_number,
	week_end_date, 
	claimant_birth_date, 
	gender, 
	race, 
	ethnic, 
	claimant_disability, 
	claimant_education_, 
	veteran_status, 
	claimant_county_resident, 
	claimant_state, 
	city, 
	zip_code, 
	industry, 
	standard_occupation_code,
	last_employer_name,
	last_employer_account_number,
	date_filed,
	benefit_year_end::varchar(8),
	sub_program_type,
	program_type,
	claim_type::varchar(1),
	payment_type,
	certification_status,
	total_pay,
	weekly_benefit_amount,
	earned_income,
	max_benefit_amount,
	mba_balance,
	week,
	last_payment_indicator
FROM il_des_claimants.promis_continued
WHERE (to_date(week, 'MMDDYY')) NOT IN (
	SELECT DISTINCT certification_week
	FROM il_covid_wf.claimant_weeks
)
AND week_end_date != '19691231'; --Exclude records with known bad week_end_date values


--Convert data types, recode, and rename some fields from PROMIS continuing claimants
--Select a maximum of one record per claimant per benefit week
--Calculate benefit year start date based on benefit year end date, benefit week sequence within a certification week
--and benefit week sequence within a filing date

DROP TABLE IF EXISTS il_covid_wf.claimant_weeks_s CASCADE;

CREATE TABLE il_covid_wf.claimant_weeks_s AS
SELECT DISTINCT ON (social_security_number, week_end_date) --This ensures results will have one record for each claimant in each benefit week
	claimant_id_number::integer AS id_number,
	social_security_number::varchar(64),
	week_end_date::date,
	claimant_birth_date::date AS birth_date,
	gender::smallint,
	race::smallint,
	ethnic::smallint AS ethnicity,
	claimant_disability::smallint AS disability,
	claimant_education_::smallint AS education,
	(veteran_status='Y')::integer AS veteran_status,
	LPAD(claimant_county_resident,3,'0')::varchar(3) AS county_fips_code,
	claimant_state::varchar(2) AS state,
	city::varchar(20),
	zip_code::varchar(10),
	industry::varchar(6) AS naics_code,
	standard_occupation_code::integer AS system_occ_code, --Integer key, we join the standard code in a later step
	last_employer_name::varchar(50),
	last_employer_account_number::varchar(8),
	date_filed::date,
	(benefit_year_end::varchar(8)::date - interval '1 year' + interval '1 day')::date AS benefit_year_start,
	benefit_year_end::varchar(8)::date,
	sub_program_type::smallint,
	program_type::smallint,
	claim_type::smallint,
	payment_type::smallint,
	certification_status::smallint,
	total_pay::integer,
	weekly_benefit_amount::integer,
	earned_income::integer,
	max_benefit_amount::integer,
	mba_balance::integer,
	to_date(week, 'MMDDYY') AS certification_week,
	row_number() OVER (PARTITION BY social_security_number, to_date(week, 'MMDDYY') 
		ORDER BY week_end_date DESC) AS certification_order,
	(last_payment_indicator='Y')::integer AS last_payment_indicator,
	row_number() OVER (PARTITION BY social_security_number, date_filed ORDER BY week_end_date)::integer AS claim_sequence
FROM il_covid_wf.new_records
ORDER BY social_security_number,
	week_end_date,
	week DESC; --When used in combination with DISTINCT ON, 
			   --this will select the record with the most recent certification week if there are duplicates


--The next several blocks of code replace hashed Social Security number with an integer surrogate.
--This makes the table take up less space on disk and is especially useful when many people will
--be using a large dataset at once, but it is not a requirement for analyzing this data.

--These two tables should exist at the time the code is run, but the definition statements are included for reference.
--This table will store all the incoming hashed Social Security numbers
CREATE TABLE IF NOT EXISTS il_covid_wf.claimant_wage_ssn_s (
	ssn varchar(64),
	PRIMARY KEY (ssn)
);

--This table relates each original hashed Social Security number to its integer surrogate
CREATE TABLE IF NOT EXISTS il_covid_wf.claimant_wage_ssn (
	ssn_id serial,
	ssn varchar(64),
	PRIMARY KEY (ssn_id)
);


--Insert all incoming hashed SSNs into claimant_wage_ssn_s
TRUNCATE TABLE il_covid_wf.claimant_wage_ssn_s;

INSERT INTO il_covid_wf.claimant_wage_ssn_s
SELECT DISTINCT social_security_number
FROM il_covid_wf.claimant_weeks_s;

--If any of these do not yet appear in il_covid_wf.claimant_wage_ssn, insert them.
--Inserting these records will generate additional values of ssn_id
INSERT INTO il_covid_wf.claimant_wage_ssn (ssn)
SELECT a.ssn
FROM il_covid_wf.claimant_wage_ssn_s a
LEFT JOIN il_covid_wf.claimant_wage_ssn b
ON a.ssn = b.ssn
WHERE b.ssn IS NULL;

--If there are any ssn_id + week_end_date combinations in the incoming data that already appear in
--il_covid_wf.claimant_weeks, we will update that table with the incoming records.

--Join surrogate SSN to the incoming records
CREATE OR REPLACE VIEW il_covid_wf.claimant_weeks_s_id AS
SELECT a.*,
	b.ssn_id
FROM il_covid_wf.claimant_weeks_s a
LEFT JOIN il_covid_wf.claimant_wage_ssn b
ON a.social_security_number = b.ssn;

--Delete any records in the target table with week_end_date + ssn_id that match the incoming records
--The effect is that we replace the old records with the incoming records in the next insert statement.
DELETE FROM il_covid_wf.claimant_weeks
WHERE (ssn_id, week_end_date) IN
(
	SELECT ssn_id, week_end_date
	FROM il_covid_wf.claimant_weeks_s_id
);


--This table should already exist, but the definition statement is included for reference
CREATE TABLE IF NOT EXISTS il_covid_wf.claimant_weeks (
	id_number integer,
	ssn_id integer,
	week_end_date date,
	certification_week date,
	certification_order integer,
	birth_date date,
	gender integer,
	race integer,
	ethnicity integer,
	disability integer,
	education integer,
	veteran_status integer,
	county_fips_code varchar(3),
	state varchar(2),
	city varchar(20),
	zip_code varchar(10),
	naics_code varchar(6),
	occupation_major_code varchar(2),
	last_employer_name varchar(50),
	last_employer_account_number varchar(8),
	date_filed date,
	claim_sequence integer,
	byr_start_date date,
	byr_end_date date,
	byr_start_week date,
	byr_sequence integer,
	sub_program_type integer,
	program_type integer,
	claim_type integer,
	payment_type integer,
	certification_status integer,
	weekly_benefit_amount integer,
	max_benefit_amount integer,
	earned_income integer,
	total_pay integer,
	mba_balance_orig integer,
	last_payment_indicator integer,
	date_updated date,
	PRIMARY KEY (ssn_id, week_end_date) --This primary key will ensure that there is only one record per person in each benefit week
);

--Insert the incoming records into il_covid_wf.claimant_weeks.
--Calculate benefit year start week as well as benefit year sequence.
--Join the Standard Occupation Code to the integer key from IDES
INSERT INTO il_covid_wf.claimant_weeks
SELECT id_number, --System ID number from IDES
	ssn_id, --Surrogate ID for SSN
	week_end_date, --Saturday ending the benefit week
	certification_week, --Week of certification
	certification_order, --Sequential order of benefit week within certification date
	birth_date, --Claimant date of birth
	gender, --Claimant gender
	race, --Claimant race
	ethnicity, --Claimant ethnicity
	disability, --Claimant disability
	education, --Claimant educational attainment
	veteran_status, --Claimant vereran status
	county_fips_code, --Claimant county of residence FIPS code
	state, --Claimant state of residence
	city, --Claimant city of residence
	zip_code, --Claimant ZIP code of residence
	naics_code, --NAICS code (6 digits) for the last employer
	occupation_major_code, --Standard Occupation Code (2 digits) for the last employer
	last_employer_name, --Name of the last employer
	last_employer_account_number, --ID number of the last employer
	date_filed, --Claim filing date
	claim_sequence, --Order of the benefit week within one claimant and filing date
	benefit_year_start AS byr_start_date, --Benefit year start day
	benefit_year_end AS byr_end_date, --Benefit year end day
	byr_start_week, --Benefit year start week
	(week_end_date - byr_start_week)/7 + 1 AS byr_sequence, --Weeks since benefit start week
	sub_program_type, --Entitlement type (regular, extended, etc.)
	program_type, --Program type (regular, UCFE, UCX, etc.)
	claim_type, --Claim type (new, additional, transitional, etc)
	payment_type, --Payment type (regular, supplement, waiting week, overpayment)
	certification_status, --Certification status (these are all certified, however)
	weekly_benefit_amount, --Weekly benefit amount
	max_benefit_amount, --Maximum weekly benefit amount
	earned_income, --Income earned in the week
	total_pay, --Total benefit amount actually paid for the week. (Includes WBA plus supplements minus deductions.)
	mba_balance AS mba_balance_orig, --Maximum benefit allotment for the benefit year
	last_payment_indicator, --Flags whether the benefit week is a claimant's final payment for the benefit year
	now()::date AS date_updated --Date the new records are inserted into the table
FROM (
	SELECT a.*,
		CASE WHEN extract(dow FROM a.benefit_year_start) IN (0,6) THEN date_trunc('week', a.benefit_year_start) + interval '1 week 5 days' 
				ELSE date_trunc('week', a.benefit_year_start) + interval '5 days' END::date AS byr_start_week,
				--This case statement finds the Saturday following benefit_year_start. 
				--In the event benefit_year_start is a Saturday, we take the next Saturday.
				--The date_trunc() function returns the previous Monday, which is why we need to add
				--an additional week when benefit_year_start is a Sunday or Monday to get the following Saturday.
		b.occupation_major_code
	FROM il_covid_wf.claimant_weeks_s_id a
	LEFT JOIN il_covid_wf.occupation_major_code b
	ON a.system_occ_code = b.system_occ_code
) _;
