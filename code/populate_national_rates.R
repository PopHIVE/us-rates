# =============================================================================
# populate_national_rates.R
#
# Reads national-level data from Ingest sources and writes long-format
# national/national_rates.csv.gz.
#
# Usage:
#   Rscript code/populate_national_rates.R
# =============================================================================

library(dplyr)
library(tidyr)
library(vroom)
library(stringr)
library(arrow)

REPO_ROOT   <- "."
INGEST_PATH <- "../Ingest/data"

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

age_to_months <- function(a) {
  n <- vapply(
    str_extract_all(a, "[0-9]+"),
    function(v) if (length(v)) max(as.numeric(v)) else NA_real_,
    numeric(1)
  )
  unit <- case_when(
    str_detect(a, "[Dd]ay")  ~ 1 / 30,
    str_detect(a, "[Yy]ear") ~ 12,
    TRUE                     ~ 1
  )
  n * unit
}

message("Loading national data...")

chr_long <- vroom(
  file.path(
    INGEST_PATH,
    "county_health_rankings/standard/data_state.csv.gz"
  ),
  show_col_types = FALSE,
  guess_max = Inf
) %>%
  filter(geography == "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
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

# BLS LAUS national unemployment rate (direct-source companion to
# chr_unemployment). Shares data_state.csv.gz with the state-level pull in
# populate_state_rates.R -- national is the single "00" row (BLS's
# standard CPS-based rate, series LNU04000000, since LAUS itself has no
# national series). No HUD CHAS block here -- HUD publishes no national
# CHAS table (see hud-chas repo's ingest.R), so hud_pct_severe_housing_problems
# has no national-level counterpart.
# Direct-from-source Census pulls (PEP, SAIPE, SAHIE, OQM), kept under their own
# source prefixes rather than mapped onto chr_ ids -- see populate_county_rates.R.
# OQM publishes no state row, so it contributes only at national.
census_direct_long <- bind_rows(
  vroom(file.path(INGEST_PATH, "census/standard/data_pep.csv.gz"), show_col_types = FALSE),
  vroom(file.path(INGEST_PATH, "census/standard/data_saipe.csv.gz"), show_col_types = FALSE),
  vroom(file.path(INGEST_PATH, "census/standard/data_sahie.csv.gz"), show_col_types = FALSE),
  vroom(file.path(INGEST_PATH, "census/standard/data_oqm.csv.gz"), show_col_types = FALSE)
) %>%
  filter(geography == "00") %>%
  pivot_longer(cols = -c(geography, time), names_to = "measure", values_to = "value") %>%
  filter(!is.na(value))

bls_long <- vroom(
  file.path(INGEST_PATH, "bls_laus/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(geography == "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# ACS5 (Metopio) national totals. Shares data_state.csv.gz with the
# state-level pull in populate_state_rates.R -- national is the single
# "00" row (Census ACS5 "us" geography level).
census_long <- vroom(
  file.path(INGEST_PATH, "census/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(geography == "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# BRFSS diabetes and obesity prevalence.
brfss_long <- read_parquet(
  file.path(
    INGEST_PATH,
    "bundle_chronic_diseases/dist",
    "brfss_prevalence_by_geography.parquet"
  )
) %>%
  filter(age == "Total", !is.na(value), geography == "United States") %>%
  mutate(
    measure   = paste0("brfss_", str_to_lower(outcome_name)),
    time      = year_end(year),
    geography = "00"
  ) %>%
  select(geography, time, measure, value)

# Childhood vaccination coverage from NIS (nis_) and SchoolVaxView (svv_).
imm_long <- read_parquet(
  file.path(
    INGEST_PATH,
    "bundle_childhood_immunizations/dist",
    "overall_rates_by_source.parquet"
  )
) %>%
  filter(!is.na(value), geography == "United States") %>%
  group_by(year, vaccine, source) %>%
  slice_max(age_to_months(age), n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  mutate(
    prefix    = if_else(source == "CDC NIS", "nis", "svv"),
    measure   = paste0(prefix, "_", slugify(vaccine)),
    time      = year_end(year),
    geography = "00"
  ) %>%
  select(geography, time, measure, value)

# SchoolVaxView kindergarten exemption rates. Read directly from the raw
# schoolvaxview source rather than bundle_childhood_immunizations's copy --
# the bundle's schoolvaxview_exemptions.parquet is an unmodified copy of this
# same file (see that bundle's build.R), so there's no derivation to lose.
svv_exempt_long <- vroom(
  file.path(INGEST_PATH, "schoolvaxview/standard/data_exemptions.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(value), geography == "00") %>%
  mutate(
    measure = paste0("svv_exempt_", str_remove(vax, "_exempt$")),
    time    = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# MMR coverage modeled by HealthMap.
healthmap_long <- vroom(
  file.path(INGEST_PATH, "mmr_healthmap/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(value), geography == "00") %>%
  mutate(
    measure = "healthmap_mmr_coverage",
    time    = mdy_to_date(time)
  ) %>%
  select(geography, time, measure, value)

# NCHS drug overdose mortality.
nchs_long <- vroom(
  file.path(INGEST_PATH, "nchs_mortality/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), geography == "00") %>%
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

# CMS Medicare chronic conditions and preventive screenings (under 65).
cms_long <- vroom(
  file.path(
    INGEST_PATH,
    "cms_mmd/standard/data_state_county_age.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(geography_level == "n", age == "Total", !is.na(geography)) %>%
  select(-geography_level, -age, -race_ethnicity, -sex) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(time = year_end(format(as.Date(time), "%Y")))

# NCHS age-adjusted mortality rates by cause of death.
nchs_causes_long <- vroom(
  file.path(
    INGEST_PATH,
    "nchs_mortality/standard/data_state_21_causes.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(geography == "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = paste0("nchs_", measure),
    time    = as.Date(time)
  )

# Epic Cosmos diabetes/obesity prevalence via diagnosis code (CCW). Sibling
# file of the county-level epic_chronic/standard/county_year.csv.gz.
epic_dx_long <- vroom(
  file.path(INGEST_PATH, "epic_chronic/standard/state_year.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(age == "Total", !is.na(geography), geography == "00") %>%
  pivot_longer(
    cols      = c(
      diabetes_dx_ccw, obesity_dx_ccw, diabetes_a1c_6_5, obesity_bmi
    ),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = recode(
      measure,
      diabetes_dx_ccw  = "epic_diabetes_dx_ccw",
      obesity_dx_ccw   = "epic_obesity_dx_ccw",
      diabetes_a1c_6_5 = "epic_diabetes_hba1c",
      obesity_bmi      = "epic_obesity_bmi"
    ),
    time = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# NCHS drug overdose death rate (per capita), national row.
nchs_overdose_rate_long <- read_parquet(
  file.path(
    INGEST_PATH, "bundle_injury_overdose/dist", "overdose_deaths_state.parquet"
  )
) %>%
  filter(
    !is.na(rate_deaths_overdose), !is.na(geography),
    geography == "United States"
  ) %>%
  mutate(
    measure   = "nchs_overdose_rate",
    time      = year_end(format(as.Date(time), "%Y")),
    value     = rate_deaths_overdose,
    geography = "00"
  ) %>%
  select(geography, time, measure, value)

# Medical and non-medical MMR exemption rates (national row of the same
# file used for state-level exempt_mmr_* measures).
exempt_long <- vroom(
  file.path(
    INGEST_PATH,
    "vaccine_exemptions_fattah/standard/data_state.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), geography == "00") %>%
  pivot_longer(
    cols      = c(exemption_rate_mmr_med, exemption_rate_mmr_nonmed),
    names_to  = "measure",
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
  select(geography, time, measure, value)

# JHU confirmed measles case counts (national row of the same file used
# for state-level jhu_measles_cases).
jhu_measles_long <- vroom(
  file.path(INGEST_PATH, "measles_jhu/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(value), !is.na(geography), geography == "00") %>%
  mutate(
    measure = "jhu_measles_cases",
    time    = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# Measles wastewater surveillance detection rate. Only the detection-rate
# column is kept as a measure; sample_count/detection_count/population_served
# are denominators, not independently reported measures elsewhere in this repo.
ww_measles_long <- vroom(
  file.path(INGEST_PATH, "wastewater_measles/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(ww_detection_rate), !is.na(geography), geography == "00") %>%
  mutate(
    measure = "ww_measles_detection_rate",
    time    = mdy_to_date(time),
    value   = ww_detection_rate
  ) %>%
  select(geography, time, measure, value)

# NOAA/NWS HeatRisk daily forecast score, area-weighted nationally. Only
# forecast_day == 0 (observed) rows are kept -- forecast_day 1-7 are
# forward-looking predictions for future dates, not observed facts.
noaa_heat_long <- vroom(
  file.path(INGEST_PATH, "noaa_heat_risk/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(
    forecast_day == 0, !is.na(value), !is.na(geography), geography == "00"
  ) %>%
  mutate(
    measure = "noaa_heat_risk_score",
    time    = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# CDC NSSP emergency-department visit percentage for RSV/COVID-19/flu, from
# the standalone nssp/standard/data.csv.gz feed -- distinct from the
# bundle_respiratory county-only cut used at the county level, this file
# is the raw CDC resource and already carries a national row.
nssp_long <- vroom(
  file.path(INGEST_PATH, "nssp/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), geography == "00") %>%
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

# CMU Delphi COVIDcast doctor-visit percentage for COVID-related symptoms.
delphi_doc_long <- vroom(
  file.path(INGEST_PATH, "delphi_doctors_claims/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(geography == "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# CMU Delphi COVIDcast hospital-admission percentage for COVID/flu.
delphi_hosp_long <- vroom(
  file.path(INGEST_PATH, "delphi_hospital_claims/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(geography == "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# AHRF workforce, facility, demographic, and environmental measures. Natively
# county-only; state and national rows are aggregated upstream in the
# area-health-resource-files repo (sum for counts, population-weighted mean
# for rates that lack a separate numerator/denominator here -- see that
# repo's ingest.R for exactly which measures get which treatment and why
# population density is excluded rather than approximated).
ahrf_long <- vroom(
  file.path(INGEST_PATH, "area_health_resource_file/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), geography == "00") %>%
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

combined <- bind_rows(
  census_direct_long, chr_long, brfss_long, imm_long, svv_exempt_long, cms_long, epic_dx_long,
  nchs_overdose_rate_long, healthmap_long, nssp_long,
  delphi_doc_long, delphi_hosp_long, ahrf_long,
  nchs_causes_long, nchs_long, exempt_long, jhu_measles_long,
  ww_measles_long, noaa_heat_long, bls_long, census_long
) %>%
  arrange(geography, time, measure)

message("Combined ", nrow(combined), " national rows across all sources")

national_dir <- file.path(REPO_ROOT, "national")
dir.create(national_dir, recursive = TRUE, showWarnings = FALSE)

vroom_write(combined, file.path(national_dir, "national_rates.csv.gz"), delim = ",")

message("\nComplete. Written to national/national_rates.csv.gz")
