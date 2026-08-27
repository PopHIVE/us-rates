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

CHR_PROVIDER_RATIO_MEASURES <- c(
  "chr_primary_care_physicians",
  "chr_dentists",
  "chr_mental_health_providers",
  "chr_other_primary_care_providers"
)

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
  filter(!is.na(value)) %>%
  # CHR&R publishes the provider-availability measures as population per
  # provider, but stores raw_value as providers per resident
  # (numerator/denominator in the Zenodo files -- New Haven 2022 dentists =
  # 669 / 851,948 = 0.000785). Invert to match the declared unit. A zero
  # provider count leaves the ratio undefined rather than infinite, and the
  # 2010 release published primary care as a rate per 100,000 population
  # ("Primary care provider rate") before adopting the ratio format in
  # 2011, so that one vintage inverts through 100,000 instead. No 2011+
  # value reaches 1, so this is a no-op if CHR&R ever publishes true ratios.
  mutate(value = case_when(
    !measure %in% CHR_PROVIDER_RATIO_MEASURES ~ value,
    value == 0                                ~ NA_real_,
    substr(as.character(time), 1, 4) == "2010" ~ 100000 / value,
    value < 1                                 ~ 1 / value,
    TRUE                                      ~ value
  )) %>%
  filter(!is.na(value)) %>%
  # CHR&R changed the denominator on chr_preventable_hospital_stays between the
  # 2018 and 2019 releases -- "per 1,000 Medicare enrollees" through 2018, "per
  # 100,000 Medicare enrollees" from 2019 -- and measure_info.json declares the
  # per-100,000 form, so the earlier releases are stored 100x too small against
  # their own unit. The change is stated ONLY in CHR&R's description text:
  # format_type stays 0 and years_used advances normally, so neither signal in
  # tracker/measure_vintages.csv catches it. Scoped by release year rather than
  # magnitude because the two eras overlap (per-1,000 runs 12-342, per-100,000
  # runs 133-33,333), so no value threshold can separate them.
  mutate(value = if_else(
    measure == "chr_preventable_hospital_stays" &
      as.integer(substr(as.character(time), 1, 4)) <= 2018,
    value * 100,
    value
  ))

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

# Direct-from-source Census pulls, kept under their own source prefixes
# (pep_, saipe_, sahie_, oqm_) rather than mapped onto chr_ ids. The direct
# source is the authority; CHR&R's redistribution of the same concepts stays a
# separate, separately-labelled series. Mapping them onto chr_ ids previously
# spliced one current-vintage year into CHR&R's consistently-lagged series,
# producing a false spike in up to 63% of counties.
census_direct_long <- bind_rows(
  vroom(file.path(INGEST_PATH, "census/standard/data_pep.csv.gz"), show_col_types = FALSE),
  vroom(file.path(INGEST_PATH, "census/standard/data_saipe.csv.gz"), show_col_types = FALSE),
  vroom(file.path(INGEST_PATH, "census/standard/data_sahie.csv.gz"), show_col_types = FALSE),
  vroom(file.path(INGEST_PATH, "census/standard/data_oqm.csv.gz"), show_col_types = FALSE)
) %>%
  filter(nchar(geography) == 5) %>%
  pivot_longer(cols = -c(geography, time), names_to = "measure", values_to = "value") %>%
  filter(!is.na(value)) %>%
  drop_alaska_defunct_duplicates() %>%
  drop_ct_legacy_duplicates()

# The direct-Census pulls above now carry their own pep_/saipe_/sahie_/oqm_
# ids, so they no longer collide with chr_ ids under a different geography
# generation. CHR&R's legacy-code rows are kept as published;
# check_geography_renaming.R verifies nothing is double-reported across a
# renamed, split, or merged geography.

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

# MMR kindergarten coverage and herd-immunity threshold status (Washington
# Post / state health departments). Read directly from the raw
# schoolvax_washpost source rather than bundle_childhood_immunizations's
# copy -- the bundle's wapo_vax_counties.parquet is an unmodified copy of
# this same file (see that bundle's build.R), so there's no derivation to
# lose.
wapo_long <- vroom(
  file.path(INGEST_PATH, "schoolvax_washpost/standard/data_counties.csv.gz"),
  show_col_types = FALSE
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

# NCHS drug overdose mortality. This county file suppresses small monthly
# counts for privacy via its own "suppressed" flag (set for 106,285 of
# 226,368 rows, ~47%, as of this check) -- a suppression placeholder isn't
# a real observation, so null out n_deaths_overdose wherever it's flagged
# before it can reach the pivot below, the same way the state-level
# suppressed_* flags are handled in populate_state_rates.R.
nchs_long <- vroom(
  file.path(
    INGEST_PATH,
    "nchs_mortality/standard/data_county.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography)) %>%
  mutate(n_deaths_overdose = if_else(suppressed == 1, NA_real_, n_deaths_overdose)) %>%
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

# AHRF workforce, facility, demographic, and environmental measures. The
# source file now also carries state (nchar 2) and national ("00") rows
# aggregated upstream in the area-health-resource-files repo -- restrict to
# county here. The Alaska duplicate/disagreement resolution that used to
# live here (ahrf_alaska_overrides) has moved upstream to that same repo,
# so every consumer gets clean data without needing its own copy of the fix.
ahrf_long <- vroom(
  file.path(INGEST_PATH, "area_health_resource_file/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), nchar(geography) == 5) %>%
  pivot_longer(
    cols      = starts_with("ahrf_"),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  # ahrf_rural_urban_code is documented as a 1-9 Rural-Urban Continuum
  # Code; 0 and 99 are AHRF's own not-classified/missing sentinels (932
  # and 864 rows respectively in the raw file), not real codes -- drop
  # them rather than let a sentinel masquerade as a real classification.
  filter(!(measure == "ahrf_rural_urban_code" & value %in% c(0, 99))) %>%
  select(geography, time, measure, value)

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

# CDC NSSP emergency-department visit percentage for RSV/COVID-19/flu,
# county level. Read directly from the raw nssp source rather than
# bundle_respiratory's copy -- the bundle's *_ed_visits_by_county.parquet
# files are this same raw file filtered to county rows and renamed (see
# that bundle's build.R), so there's no derivation to lose. Roughly a
# quarter of rows are a state's rate back-filled onto every one of its
# counties for low-volume privacy suppression (is_state_estimate == TRUE) --
# those are dropped rather than misrepresented as county-level observations.
nssp_long <- vroom(
  file.path(INGEST_PATH, "nssp/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(str_length(geography) == 5, !is_state_estimate) %>%
  select(geography, time, starts_with("percent_visits_")) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = recode(
      measure,
      percent_visits_rsv   = "nssp_pct_ed_visits_rsv",
      percent_visits_covid = "nssp_pct_ed_visits_covid",
      percent_visits_flu   = "nssp_pct_ed_visits_flu"
    ),
    time = as.Date(time)
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
  chr_long, census_direct_long, census_long, epic_long,
  wapo_long, healthmap_long, exempt_long,
  cms_long, nchs_long, ahrf_long, usda_long, bls_long, hud_long,
  nhtsa_long, nhtsa_crash_type_long, delphi_doc_long, delphi_hosp_long,
  epic_dx_long, noaa_heat_long, jhu_measles_long,
  ww_measles_long, epic_heat_long, nssp_long, nchs_overdose_rate_long
) %>%
  # Guards against duplicate (geography, time, measure) rows from upstream
  # sources -- e.g. NCHS mortality repeats Bedford (51019) and Alleghany
  # (51005), VA, once per pre/post-2013 independent-city-merger FIPS mapping.
  # chr_long is listed BEFORE census_direct_long so CHR&R wins any exact match
  # for the same (geography, time, measure). The direct-Census pull is a single
  # current-vintage year; splicing it into CHR&R's consistently-lagged series
  # produced a false spike in up to 63% of counties (2024 median household
  # income jumping ~19% then falling back). Bound second, it only FILLS GAPS --
  # which is where it is indispensable: CHR&R still reports legacy CT county and
  # defunct Alaska codes, so Census is the sole source for the 9 CT planning
  # regions and for Chugach/Copper River, and the only source of chr_rural for
  # Puerto Rico's municipios.
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
