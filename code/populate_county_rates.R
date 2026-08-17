# =============================================================================
# populate_county_rates.R
#
# Transforms wide-format data from Ingest sources (CHR, Census) into long-format
# county_rates.csv.gz files in the us-rates folder structure.
#
# Usage:
#   Rscript code/populate_county_rates.R
# =============================================================================

library(dplyr)
library(tidyr)
library(tibble)
library(vroom)
library(stringr)
library(arrow)

# Config
REPO_ROOT <- "."
INGEST_PATH <- "../Ingest/data"

source(file.path(REPO_ROOT, "code", "geography_helpers.R"))

year_end <- function(y) as.Date(paste0(as.integer(y), "-12-31"))

month_end <- function(d) {
  lt <- as.POSIXlt(as.Date(d))
  lt$mon <- lt$mon + 1L
  lt$mday <- 1L
  as.Date(lt) - 1L
}

mdy_to_date <- function(x) as.Date(x, format = "%m-%d-%Y")

slugify <- function(x) {
  x %>%
    str_to_lower() %>%
    str_replace_all("[^a-z0-9]+", "_") %>%
    str_remove("^_|_$")
}

# Load FIPS reference to map FIPS codes to state/county folders
all_fips <- vroom(file.path(REPO_ROOT, "resources/all_fips.csv.gz"),
                  col_types = "cccc", show_col_types = FALSE)
county_fips <- all_fips %>%
  filter(nchar(geography) == 5) %>%
  rename(fips = geography)

state_name_lookup <- all_fips %>%
  filter(nchar(geography) == 2, geography != "00") %>%
  select(state_abbr = state, state_full = geography_name)

message("Loading CHR and Census data...")

# Read CHR (wide format: geography, time, measure columns)
# guess_max = Inf: several measure columns (e.g. WI-only supplemental
# measures) are sparse enough that vroom's default row sample can guess
# them as logical instead of numeric, silently corrupting real values.
chr_wide <- vroom(
  file.path(INGEST_PATH, "county_health_rankings/standard/data_county.csv.gz"),
  show_col_types = FALSE,
  guess_max = Inf
)

# Read Census (wide format)
census_wide <- vroom(
  file.path(INGEST_PATH, "census/standard/data_county.csv.gz"),
  show_col_types = FALSE
)

# Convert wide → long format for both sources
chr_long <- chr_wide %>%
  pivot_longer(
    cols = -c(geography, time),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

census_long <- census_wide %>%
  pivot_longer(
    cols = -c(geography, time),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# Retired Alaska borough/census-area FIPS codes still written to by some
# sources alongside their current successor(s) (see check_geography_renaming.R).
ALASKA_DEFUNCT_CODES <- c("02201", "02231", "02232", "02261", "02270", "02280")

# vaccine_exemptions_fattah always duplicates its value onto the retired code;
# census's PEP-derived county estimates sometimes carry a row for a retired
# code (e.g. Valdez-Cordova, 02261) alongside its current successor(s) even
# in an otherwise-current vintage -- drop it unconditionally rather than try
# to reconcile which value is "right".
drop_alaska_defunct_duplicates <- function(df) {
  df %>% filter(!(geography %in% ALASKA_DEFUNCT_CODES))
}

# Legacy Connecticut county codes, retired as of the 2022 planning-region
# cutover (see README). census's PEP/SAIPE/OQM/SAHIE feeds below are single-
# current-vintage patches, so any row still tagged with a legacy code is
# stale by definition once the vintage is 2022+ -- drop it rather than
# double-report the same year under both conventions.
CT_LEGACY_COUNTY_CODES <- c(
  "09001", "09003", "09005", "09007", "09009", "09011", "09013", "09015"
)

drop_ct_legacy_duplicates <- function(df) {
  df %>% filter(!(geography %in% CT_LEGACY_COUNTY_CODES))
}

# Census-native replacements for 17 measures historically sourced only from
# CHR's own redistribution (chr_population, chr_rural, etc.). Each of these
# Ingest files covers a single current vintage, so this only patches the
# latest data point per measure -- older CHR-sourced years for these same
# measure names are left untouched in chr_long below.
pep_wide   <- vroom(file.path(INGEST_PATH, "census/standard/data_pep.csv.gz"), show_col_types = FALSE)
saipe_wide <- vroom(file.path(INGEST_PATH, "census/standard/data_saipe.csv.gz"), show_col_types = FALSE)
oqm_wide   <- vroom(file.path(INGEST_PATH, "census/standard/data_oqm.csv.gz"), show_col_types = FALSE)
sahie_wide <- vroom(file.path(INGEST_PATH, "census/standard/data_sahie.csv.gz"), show_col_types = FALSE)

census_direct_long <- bind_rows(
  pep_wide %>%
    pivot_longer(cols = -c(geography, time), names_to = "measure", values_to = "value") %>%
    mutate(measure = recode(measure,
      pep_population   = "chr_population",
      pep_pct_65_older = "chr_65_and_older",
      pep_pct_under_18 = "chr_below_18_years_of_age",
      pep_pct_female   = "chr_female",
      pep_pct_aian     = "chr_american_indian_or_alaska_native",
      pep_pct_asian    = "chr_asian",
      pep_pct_nhpi     = "chr_native_hawaiian_or_other_pacific_islander",
      pep_pct_nh_black = "chr_non_hispanic_black",
      pep_pct_nh_white = "chr_non_hispanic_white",
      pep_pct_hispanic = "chr_hispanic"
    )),
  saipe_wide %>%
    pivot_longer(cols = -c(geography, time), names_to = "measure", values_to = "value") %>%
    mutate(measure = recode(measure,
      saipe_pct_children_poverty    = "chr_children_in_poverty",
      saipe_median_household_income = "chr_median_household_income"
    )),
  oqm_wide %>%
    pivot_longer(cols = -c(geography, time), names_to = "measure", values_to = "value") %>%
    mutate(measure = "chr_census_participation"),
  sahie_wide %>%
    pivot_longer(cols = -c(geography, time), names_to = "measure", values_to = "value") %>%
    mutate(measure = recode(measure,
      sahie_pct_uninsured          = "chr_uninsured",
      sahie_pct_uninsured_adults   = "chr_uninsured_adults",
      sahie_pct_uninsured_children = "chr_uninsured_children"
    )),
  # census_ur_pct_urban_pop is a static 2020-decennial value repeated across
  # every ACS vintage year in census_wide; take the latest one point only.
  census_wide %>%
    filter(time == max(time)) %>%
    transmute(geography, time, measure = "chr_rural", value = 1 - census_ur_pct_urban_pop)
) %>%
  filter(!is.na(value)) %>%
  drop_alaska_defunct_duplicates() %>%
  drop_ct_legacy_duplicates()

# chr_long (below) is CHR&R's own redistribution, which cuts over to a
# renamed/split/merged geography on its own schedule -- often later than the
# actual FIPS change (e.g. it still reports Valdez-Cordova, 02261, through
# 2023, and legacy CT counties through 2023, despite both changes taking
# effect earlier). For any date where census_direct_long already reports the
# current-generation code, drop chr_long's competing legacy/defunct-code row
# for that same date rather than double-report the year across generations --
# distinct() further down can't catch this since the geography keys differ.
census_direct_dates <- unique(census_direct_long$time)

chr_long <- chr_long %>%
  filter(!(
    (geography %in% ALASKA_DEFUNCT_CODES | geography %in% CT_LEGACY_COUNTY_CODES) &
      time %in% census_direct_dates
  ))

# area_health_resource_file sometimes duplicates and sometimes disagrees; see
# git history for how each row below was resolved.
ahrf_alaska_overrides <- tribble(
  ~geography, ~measure,                    ~time,
  "02063",    "ahrf_critical_access_hosp", "2023-12-31",
  "02063",    "ahrf_hospitals",            "2023-12-31",
  "02063",    "ahrf_hpsa_dental",          "2025-12-31",
  "02063",    "ahrf_hpsa_mental_health",   "2025-12-31",
  "02063",    "ahrf_hpsa_prim_care",       "2025-12-31",
  "02066",    "ahrf_critical_access_hosp", "2023-12-31",
  "02066",    "ahrf_hospitals",            "2023-12-31",
  "02066",    "ahrf_hpsa_dental",          "2025-12-31",
  "02066",    "ahrf_hpsa_mental_health",   "2025-12-31",
  "02066",    "ahrf_hpsa_prim_care",       "2025-12-31",
  "02105",    "ahrf_population",           "2011-12-31",
  "02105",    "ahrf_population",           "2012-12-31",
  "02195",    "ahrf_md_all",               "2011-12-31",
  "02195",    "ahrf_md_all",               "2012-12-31",
  "02195",    "ahrf_population",           "2011-12-31",
  "02195",    "ahrf_population",           "2012-12-31",
  "02198",    "ahrf_md_all",               "2011-12-31",
  "02198",    "ahrf_md_all",               "2012-12-31",
  "02198",    "ahrf_population",           "2011-12-31",
  "02198",    "ahrf_population",           "2012-12-31",
  "02201",    "ahrf_critical_access_hosp", "2011-12-31",
  "02201",    "ahrf_critical_access_hosp", "2012-12-31",
  "02201",    "ahrf_dentists",             "2011-12-31",
  "02201",    "ahrf_dentists",             "2012-12-31",
  "02201",    "ahrf_good_air_pct",         "2012-12-31",
  "02201",    "ahrf_hospitals",            "2011-12-31",
  "02201",    "ahrf_hospitals",            "2012-12-31",
  "02201",    "ahrf_pcp",                  "2011-12-31",
  "02201",    "ahrf_pcp",                  "2012-12-31",
  "02201",    "ahrf_pm25",                 "2012-12-31",
  "02201",    "ahrf_pop_density",          "2011-12-31",
  "02201",    "ahrf_pop_density",          "2012-12-31",
  "02201",    "ahrf_psych",                "2011-12-31",
  "02201",    "ahrf_psych",                "2012-12-31",
  "02201",    "ahrf_rural_urban_code",     "2011-12-31",
  "02201",    "ahrf_rural_urban_code",     "2012-12-31",
  "02230",    "ahrf_population",           "2011-12-31",
  "02230",    "ahrf_population",           "2012-12-31",
  "02232",    "ahrf_critical_access_hosp", "2011-12-31",
  "02232",    "ahrf_critical_access_hosp", "2012-12-31",
  "02232",    "ahrf_dentists",             "2011-12-31",
  "02232",    "ahrf_dentists",             "2012-12-31",
  "02232",    "ahrf_good_air_pct",         "2012-12-31",
  "02232",    "ahrf_hospitals",            "2011-12-31",
  "02232",    "ahrf_hospitals",            "2012-12-31",
  "02232",    "ahrf_md_all",               "2011-12-31",
  "02232",    "ahrf_md_all",               "2012-12-31",
  "02232",    "ahrf_medicare_per_capita",  "2014-12-31",
  "02232",    "ahrf_pcp",                  "2011-12-31",
  "02232",    "ahrf_pcp",                  "2012-12-31",
  "02232",    "ahrf_pm25",                 "2012-12-31",
  "02232",    "ahrf_pop_density",          "2011-12-31",
  "02232",    "ahrf_pop_density",          "2012-12-31",
  "02232",    "ahrf_psych",                "2011-12-31",
  "02232",    "ahrf_psych",                "2012-12-31",
  "02232",    "ahrf_rural_urban_code",     "2011-12-31",
  "02232",    "ahrf_rural_urban_code",     "2012-12-31",
  "02261",    "ahrf_critical_access_hosp", "2025-12-31",
  "02261",    "ahrf_hospitals",            "2025-12-31",
  "02275",    "ahrf_md_all",               "2011-12-31",
  "02275",    "ahrf_md_all",               "2012-12-31",
  "02275",    "ahrf_population",           "2011-12-31",
  "02275",    "ahrf_population",           "2012-12-31",
  "02280",    "ahrf_critical_access_hosp", "2011-12-31",
  "02280",    "ahrf_critical_access_hosp", "2012-12-31",
  "02280",    "ahrf_dentists",             "2011-12-31",
  "02280",    "ahrf_dentists",             "2012-12-31",
  "02280",    "ahrf_good_air_pct",         "2012-12-31",
  "02280",    "ahrf_hospitals",            "2011-12-31",
  "02280",    "ahrf_hospitals",            "2012-12-31",
  "02280",    "ahrf_pcp",                  "2011-12-31",
  "02280",    "ahrf_pcp",                  "2012-12-31",
  "02280",    "ahrf_pm25",                 "2012-12-31",
  "02280",    "ahrf_pop_density",          "2011-12-31",
  "02280",    "ahrf_pop_density",          "2012-12-31",
  "02280",    "ahrf_psych",                "2011-12-31",
  "02280",    "ahrf_psych",                "2012-12-31",
  "02280",    "ahrf_rural_urban_code",     "2011-12-31",
  "02280",    "ahrf_rural_urban_code",     "2012-12-31"
) %>%
  mutate(time = as.Date(time))

message("Loading chronic disease and immunization data...")

# Epic Cosmos diabetes (HbA1c) and obesity (BMI) prevalence.
# Medicare rows are dropped here; CMS claims-based prevalence comes from cms_mmd.
epic_long <- read_parquet(
  file.path(
    INGEST_PATH,
    "bundle_chronic_diseases/dist",
    "epic_prevalence_by_geography_county_and_source.parquet"
  )
) %>%
  filter(
    age == "Total",
    source %in% c("Epic Cosmos: HbA1c", "Epic Cosmos: BMI"),
    !is.na(value), !is.na(geography)
  ) %>%
  mutate(
    measure = paste0(
      "epic_", str_to_lower(outcome_name), "_",
      if_else(str_detect(source, "HbA1c"), "hba1c", "bmi")
    ),
    time = year_end(year)
  ) %>%
  select(geography, time, measure, value)

# MMR kindergarten coverage and herd-immunity threshold status
# (Washington Post / state health departments).
wapo_long <- read_parquet(
  file.path(
    INGEST_PATH,
    "bundle_childhood_immunizations/dist",
    "wapo_vax_counties.parquet"
  )
) %>%
  filter(!is.na(geography)) %>%
  mutate(
    wapo_met_herd_immunity_prepandemic  = recode(wapo_prepand_herd, y = 1, n = 0, .default = NA_real_),
    wapo_met_herd_immunity_postpandemic = recode(wapo_postpand_herd, y = 1, n = 0, .default = NA_real_)
  ) %>%
  pivot_longer(
    cols = c(
      wapo_county_vax_rate, wapo_met_herd_immunity_prepandemic,
      wapo_met_herd_immunity_postpandemic
    ),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = recode(measure, wapo_county_vax_rate = "wapo_mmr_coverage"),
    time    = mdy_to_date(time)
  ) %>%
  select(geography, time, measure, value)

# MMR coverage modeled by HealthMap.
healthmap_long <- vroom(
  file.path(INGEST_PATH, "mmr_healthmap/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(value), !is.na(geography)) %>%
  mutate(
    measure = "healthmap_mmr_coverage",
    time    = mdy_to_date(time)
  ) %>%
  select(geography, time, measure, value)

# Medical and non-medical MMR exemption rates.
exempt_long <- vroom(
  file.path(
    INGEST_PATH,
    "vaccine_exemptions_fattah/standard/data_county.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography)) %>%
  pivot_longer(
    cols = c(exemption_rate_mmr_med, exemption_rate_mmr_nonmed),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = recode(
      measure,
      exemption_rate_mmr_med    = "exempt_mmr_medical",
      exemption_rate_mmr_nonmed = "exempt_mmr_nonmedical"
    ),
    time = mdy_to_date(time)
  ) %>%
  select(geography, time, measure, value) %>%
  drop_alaska_defunct_duplicates()

# CMS Medicare chronic conditions and preventive screenings (under 65).
cms_long <- vroom(
  file.path(
    INGEST_PATH,
    "cms_mmd/standard/data_state_county_age.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(geography_level == "c", age == "Total", !is.na(geography)) %>%
  select(-geography_level, -age, -race_ethnicity, -sex) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(time = year_end(format(as.Date(time), "%Y")))

# NCHS drug overdose mortality.
nchs_long <- vroom(
  file.path(
    INGEST_PATH,
    "nchs_mortality/standard/data_county.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography)) %>%
  pivot_longer(
    cols      = c(n_deaths_overdose, pct_pending_invest),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = recode(
      measure,
      n_deaths_overdose  = "nchs_overdose_deaths",
      pct_pending_invest = "nchs_overdose_pct_pending"
    ),
    time = month_end(time)
  ) %>%
  select(geography, time, measure, value)

# AHRF workforce, facility, demographic, and environmental measures.
ahrf_long <- vroom(
  file.path(INGEST_PATH, "area_health_resource_file/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography)) %>%
  pivot_longer(
    cols      = starts_with("ahrf_"),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  select(geography, time, measure, value) %>%
  anti_join(ahrf_alaska_overrides, by = c("geography", "measure", "time"))

# USDA low-income/low-access food environment (direct-source companion to
# chr_limited_access_to_healthy_foods).
usda_long <- vroom(
  file.path(INGEST_PATH, "usda_food_access/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# BLS LAUS county unemployment rate (direct-source companion to
# chr_unemployment).
bls_long <- vroom(
  file.path(INGEST_PATH, "bls_laus/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# HUD CHAS severe housing problems (direct-source companion to
# chr_severe_housing_problems).
hud_long <- vroom(
  file.path(INGEST_PATH, "hud_chas/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

message("Loading environmental, syndromic, and diagnosis-based measures...")

# Epic Cosmos diabetes/obesity prevalence via diagnosis code (CCW), distinct
# from the HbA1c/BMI clinical-measurement version in epic_long above.
epic_dx_long <- vroom(
  file.path(INGEST_PATH, "epic_chronic/standard/county_year.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(age == "Total", !is.na(geography)) %>%
  pivot_longer(
    cols      = c(diabetes_dx_ccw, obesity_dx_ccw),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = recode(
      measure,
      diabetes_dx_ccw = "epic_diabetes_dx_ccw",
      obesity_dx_ccw  = "epic_obesity_dx_ccw"
    ),
    time = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# NOAA/NWS HeatRisk daily forecast score, area-weighted to county. Only
# forecast_day == 0 (observed) rows are kept -- forecast_day 1-7 are
# forward-looking predictions for future dates, not observed facts.
noaa_heat_long <- vroom(
  file.path(INGEST_PATH, "noaa_heat_risk/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(forecast_day == 0, !is.na(value), !is.na(geography)) %>%
  mutate(
    measure = "noaa_heat_risk_score",
    time    = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# JHU confirmed measles case counts. This file mixes in state-level and a
# handful of non-FIPS placeholder rows (e.g. "00024") alongside true county
# rows -- restrict to 5-digit county FIPS. It also reports Hartford (legacy
# 09003) alongside the Capitol planning region (09170) for the same weeks
# (mostly identical counts, occasionally disagreeing by a case or two) --
# drop the legacy code rather than double-report, same as census_direct_long
# above; this source only carries 2025+ data, so there's no historical
# period that would be lost.
jhu_measles_long <- vroom(
  file.path(INGEST_PATH, "measles_jhu/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(value), !is.na(geography), nchar(geography) == 5) %>%
  mutate(
    measure = "jhu_measles_cases",
    time    = as.Date(time)
  ) %>%
  select(geography, time, measure, value) %>%
  drop_ct_legacy_duplicates()

# Measles wastewater surveillance detection rate. Only the detection-rate
# column is kept as a measure; sample_count/detection_count/population_served
# are denominators, not independently reported measures elsewhere in this repo.
ww_measles_long <- vroom(
  file.path(INGEST_PATH, "wastewater_measles/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(ww_detection_rate), !is.na(geography)) %>%
  mutate(
    measure = "ww_measles_detection_rate",
    time    = mdy_to_date(time),
    value   = ww_detection_rate
  ) %>%
  select(geography, time, measure, value)

# Epic Cosmos heat-related ED visit rate (per 100,000 total ED visits).
# This file is tab-delimited, unlike the rest of the Ingest sources read here.
epic_heat_long <- vroom(
  file.path(INGEST_PATH, "epic_injury/standard/heat_year_county.csv.gz"),
  delim = "\t",
  show_col_types = FALSE
) %>%
  filter(!is.na(heat_ed_incidence), !is.na(geography)) %>%
  mutate(
    measure = "epic_heat_ed_rate",
    time    = as.Date(time),
    value   = heat_ed_incidence
  ) %>%
  select(geography, time, measure, value)

# CDC NSSP emergency-department visit percentage for RSV/COVID-19/flu.
# `fips` ships as a bare number (leading zeros stripped) and roughly a
# quarter of rows are a state's rate back-filled onto every one of its
# counties for low-volume privacy suppression (is_state_estimate == TRUE) --
# those are dropped rather than misrepresented as county-level observations.
read_nssp_county <- function(file, measure_name) {
  read_parquet(file.path(INGEST_PATH, "bundle_respiratory/dist", file)) %>%
    filter(!is_state_estimate, !is.na(fips)) %>%
    mutate(
      geography = str_pad(as.character(fips), 5, pad = "0"),
      measure   = measure_name,
      time      = as.Date(week_end)
    ) %>%
    rename(value = starts_with("percent_visits_")) %>%
    filter(!is.na(value)) %>%
    select(geography, time, measure, value)
}

nssp_long <- bind_rows(
  read_nssp_county("rsv_ed_visits_by_county.parquet", "nssp_pct_ed_visits_rsv"),
  read_nssp_county("covid_ed_visits_by_county.parquet", "nssp_pct_ed_visits_covid"),
  read_nssp_county("flu_ed_visits_by_county.parquet", "nssp_pct_ed_visits_flu")
)

# NCHS drug overdose death rate (per capita), distinct from the raw monthly
# count in nchs_long above, which comes from a different upstream file that
# has no rate column.
nchs_overdose_rate_long <- read_parquet(
  file.path(INGEST_PATH, "bundle_injury_overdose/dist", "overdose_deaths_county.parquet")
) %>%
  filter(!is.na(rate_deaths_overdose), !is.na(geography)) %>%
  mutate(
    measure = "nchs_overdose_rate",
    time    = year_end(format(as.Date(time), "%Y")),
    value   = rate_deaths_overdose
  ) %>%
  select(geography, time, measure, value)

# NHTSA FARS motor vehicle crash fatalities and fatality rate.
nhtsa_long <- vroom(
  file.path(INGEST_PATH, "nhtsa_crash/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(nchar(geography) == 5) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# NHTSA FARS fatalities by crash type (single-vehicle, rural/urban,
# pedestrian- or cyclist-involved). This file also repeats nhtsa_fatalities/
# nhtsa_fatal_crashes at the Overall/Overall row (99.99% identical to
# nhtsa_long above, matching to floating-point rounding) -- only the 5
# crash-type-specific columns are pulled here to avoid re-deriving those.
# Also carries Valdez-Cordova (02261) through 2023 alongside its successors
# Chugach/Copper River (02063/02066) starting 2023 -- drop the retired code
# like the other Alaska-defunct sources above.
nhtsa_crash_type_long <- vroom(
  file.path(INGEST_PATH, "nhtsa_crash/standard/data_crash_type.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(nchar(geography) == 5, age == "Overall", sex == "Overall") %>%
  pivot_longer(
    cols      = c(
      nhtsa_single_vehicle, nhtsa_rural, nhtsa_urban,
      nhtsa_pedestrian_involved, nhtsa_cyclist_involved
    ),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  select(geography, time, measure, value) %>%
  drop_alaska_defunct_duplicates()

# CMU Delphi COVIDcast doctor-visit percentage for COVID-related symptoms.
# This feed also mixes in state-total rows disguised as county FIPS (state
# code + "000", e.g. "56000" for Wyoming) -- no real county FIPS ends in
# "000", so exclude those rather than misrepresent them as county data.
delphi_doc_long <- vroom(
  file.path(INGEST_PATH, "delphi_doctors_claims/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(nchar(geography) == 5, !str_detect(geography, "000$")) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# CMU Delphi COVIDcast hospital-admission percentage for COVID/flu. Same
# state-total-disguised-as-county-FIPS quirk as delphi_doc_long above.
delphi_hosp_long <- vroom(
  file.path(INGEST_PATH, "delphi_hospital_claims/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(nchar(geography) == 5, !str_detect(geography, "000$")) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

combined <- bind_rows(
  census_direct_long, chr_long, census_long, epic_long,
  wapo_long, healthmap_long, exempt_long,
  cms_long, nchs_long, ahrf_long, usda_long, bls_long, hud_long,
  nhtsa_long, nhtsa_crash_type_long, delphi_doc_long, delphi_hosp_long,
  epic_dx_long, noaa_heat_long, jhu_measles_long,
  ww_measles_long, epic_heat_long, nssp_long, nchs_overdose_rate_long
) %>%
  # Guards against duplicate (geography, time, measure) rows from upstream
  # sources -- e.g. NCHS mortality repeats Bedford (51019) and Alleghany
  # (51005), VA, once per pre/post-2013 independent-city-merger FIPS mapping.
  # census_direct_long is listed first so it wins any exact match against
  # chr_long for the same (geography, time, measure) -- see above.
  distinct(geography, time, measure, .keep_all = TRUE) %>%
  arrange(geography, time, measure)

message("Combined ", nrow(combined), " rows across all sources")

# Group by county and write county_rates.csv.gz to each county folder
counties <- unique(combined$geography)
message("Processing ", length(counties), " counties...")

for (county_fips_code in counties) {
  county_data <- combined %>%
    filter(geography == county_fips_code) %>%
    select(geography, time, measure, value)

  # Find state folder name from FIPS reference
  match_row <- county_fips %>% filter(fips == county_fips_code)
  if (nrow(match_row) == 0) {
    warning("FIPS code ", county_fips_code, " not found in reference")
    next
  }

  state_full <- state_name_lookup %>%
    filter(state_abbr == match_row$state[1]) %>%
    pull(state_full)
  county_name <- match_row$geography_name[1]

  # is_territory() (state abbreviation -> territory?) comes from
  # geography_helpers.R, sourced above. Territory counties (e.g. Puerto Rico's
  # municipios) go under territories/ instead of states/.
  top_level_dir <- if (is_territory(match_row$state[1])) "territories" else "states"

  # Determine folder path (safe_name() comes from geography_helpers.R)
  county_folder <- file.path(
    REPO_ROOT, top_level_dir, safe_name(state_full), "counties",
    paste0(county_fips_code, "_", safe_name(county_name))
  )

  dir.create(county_folder, recursive = TRUE, showWarnings = FALSE)

  # Write county_rates.csv.gz
  output_file <- file.path(county_folder, "county_rates.csv.gz")
  vroom_write(county_data, output_file, delim = ",")
}

message(
  "\nComplete. County rate files written to states/*/counties/*/ and ",
  "territories/*/counties/*/ folders."
)
