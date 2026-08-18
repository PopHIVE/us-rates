# =============================================================================
# populate_state_rates.R
#
# Reads state-level data from Ingest sources and writes long-format
# state_rates.csv.gz to each states/{state}/ folder.
#
# Usage:
#   Rscript code/populate_state_rates.R
# =============================================================================

library(dplyr)
library(tidyr)
library(vroom)
library(stringr)
library(arrow)

REPO_ROOT   <- "."
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

all_fips <- vroom(
  file.path(REPO_ROOT, "resources/all_fips.csv.gz"),
  col_types = "ccc", show_col_types = FALSE
)

state_fips <- all_fips %>%
  filter(nchar(geography) == 2, geography != "00") %>%
  rename(state_fips = geography)

name_to_fips <- state_fips %>%
  select(state_fips, geography_name)

# safe_name() (place name -> folder name) comes from geography_helpers.R,
# sourced above.

message("Loading CHR and Census data...")

chr_long <- vroom(
  file.path(
    INGEST_PATH,
    "county_health_rankings/standard/data_state.csv.gz"
  ),
  show_col_types = FALSE,
  guess_max = Inf
) %>%
  filter(geography != "00") %>%
  pivot_longer(
    cols = -c(geography, time),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

census_long <- vroom(
  file.path(INGEST_PATH, "census/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(geography != "00") %>%
  pivot_longer(
    cols = -c(geography, time),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# BLS LAUS state unemployment rate (direct-source companion to
# chr_unemployment). Same file also carries the national row under
# geography "00", split out in populate_national_rates.R.
bls_long <- vroom(
  file.path(INGEST_PATH, "bls_laus/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(geography != "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# HUD CHAS severe housing problems (direct-source companion to
# chr_severe_housing_problems). State-only -- HUD publishes no national
# CHAS table (see hud-chas repo's ingest.R), so there's no national
# counterpart in populate_national_rates.R.
hud_long <- vroom(
  file.path(INGEST_PATH, "hud_chas/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

message("Loading chronic disease and immunization data...")

# BRFSS diabetes and obesity prevalence.
brfss_long <- read_parquet(
  file.path(
    INGEST_PATH,
    "bundle_chronic_diseases/dist",
    "brfss_prevalence_by_geography.parquet"
  )
) %>%
  filter(age == "Total", !is.na(value)) %>%
  left_join(name_to_fips, by = c("geography" = "geography_name")) %>%
  filter(!is.na(state_fips)) %>%
  mutate(
    measure   = paste0("brfss_", str_to_lower(outcome_name)),
    time      = year_end(year),
    geography = state_fips
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
  filter(!is.na(value)) %>%
  left_join(name_to_fips, by = c("geography" = "geography_name")) %>%
  filter(!is.na(state_fips)) %>%
  group_by(state_fips, year, vaccine, source) %>%
  slice_max(age_to_months(age), n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  mutate(
    prefix    = if_else(source == "CDC NIS", "nis", "svv"),
    measure   = paste0(prefix, "_", slugify(vaccine)),
    time      = year_end(year),
    geography = state_fips
  ) %>%
  select(geography, time, measure, value)

# SchoolVaxView kindergarten exemption rates.
svv_exempt_long <- read_parquet(
  file.path(
    INGEST_PATH,
    "bundle_childhood_immunizations/dist",
    "schoolvaxview_exemptions.parquet"
  )
) %>%
  filter(!is.na(value), geography != "00") %>%
  mutate(
    measure = paste0("svv_exempt_", str_remove(vax, "_exempt$")),
    time    = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# Medical and non-medical MMR exemption rates.
exempt_long <- vroom(
  file.path(
    INGEST_PATH,
    "vaccine_exemptions_fattah/standard/data_state.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), geography != "00") %>%
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

# CMS Medicare chronic conditions and preventive screenings (under 65). The
# same file used for county-level cms_* measures also carries state-level
# rows (geography_level == "s"), just filtered out there.
cms_long <- vroom(
  file.path(
    INGEST_PATH,
    "cms_mmd/standard/data_state_county_age.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(geography_level == "s", age == "Total", !is.na(geography)) %>%
  select(-geography_level, -age, -race_ethnicity, -sex) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(time = year_end(format(as.Date(time), "%Y")))

# MMR coverage modeled by HealthMap.
healthmap_long <- vroom(
  file.path(INGEST_PATH, "mmr_healthmap/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(value), geography != "00") %>%
  mutate(
    measure = "healthmap_mmr_coverage",
    time    = mdy_to_date(time)
  ) %>%
  select(geography, time, measure, value)

# Epic Cosmos diagnosis-code (CCW), HbA1c, and BMI-based diabetes/obesity
# prevalence. Sibling file of the county-level
# epic_chronic/standard/county_year.csv.gz.
epic_dx_long <- vroom(
  file.path(INGEST_PATH, "epic_chronic/standard/state_year.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(age == "Total", !is.na(geography), geography != "00") %>%
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

# NCHS drug overdose death rate (per capita). State names are joined to
# FIPS via name_to_fips; the national "United States" row is dropped here
# and picked up separately by populate_national_rates.R.
nchs_overdose_rate_long <- read_parquet(
  file.path(
    INGEST_PATH, "bundle_injury_overdose/dist", "overdose_deaths_state.parquet"
  )
) %>%
  filter(
    !is.na(rate_deaths_overdose), !is.na(geography),
    geography != "United States"
  ) %>%
  left_join(name_to_fips, by = c("geography" = "geography_name")) %>%
  filter(!is.na(state_fips)) %>%
  mutate(
    measure   = "nchs_overdose_rate",
    time      = year_end(format(as.Date(time), "%Y")),
    value     = rate_deaths_overdose,
    geography = state_fips
  ) %>%
  select(geography, time, measure, value)

# NCHS drug overdose mortality.
nchs_long <- vroom(
  file.path(INGEST_PATH, "nchs_mortality/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), nchar(geography) == 2, geography != "00") %>%
  select(geography, time, starts_with("n_deaths_"),
         pct_complete, pct_pending_invest) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = paste0("nchs_", str_remove(measure, "^n_")),
    # Align names with populate_county_rates.R's nchs_overdose_deaths /
    # nchs_overdose_pct_pending for the two measures counties also report.
    measure = recode(measure,
      nchs_deaths_overdose    = "nchs_overdose_deaths",
      nchs_pct_pending_invest = "nchs_overdose_pct_pending"
    ),
    time    = month_end(time)
  )

# NOAA/NWS HeatRisk daily forecast score, area-weighted to state. Only
# forecast_day == 0 (observed) rows are kept -- forecast_day 1-7 are
# forward-looking predictions for future dates, not observed facts.
noaa_heat_long <- vroom(
  file.path(INGEST_PATH, "noaa_heat_risk/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(
    forecast_day == 0, !is.na(value), !is.na(geography), geography != "00"
  ) %>%
  mutate(
    measure = "noaa_heat_risk_score",
    time    = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# JHU confirmed measles case counts.
jhu_measles_long <- vroom(
  file.path(INGEST_PATH, "measles_jhu/standard/data_state.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(value), !is.na(geography), geography != "00") %>%
  mutate(
    measure = "jhu_measles_cases",
    time    = as.Date(time)
  ) %>%
  select(geography, time, measure, value)

# NCHS age-adjusted mortality rates by cause of death.
nchs_causes_long <- vroom(
  file.path(
    INGEST_PATH,
    "nchs_mortality/standard/data_state_21_causes.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), geography != "00") %>%
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

# CDC NSSP emergency-department visit percentage for RSV/COVID-19/flu, from
# the standalone nssp/standard/data.csv.gz feed -- distinct from the
# bundle_respiratory county-only cut used at the county level, this file
# is the raw CDC resource and already carries national and state rows.
nssp_long <- vroom(
  file.path(INGEST_PATH, "nssp/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), nchar(geography) == 2, geography != "00") %>%
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

# NHTSA FARS motor vehicle crash fatalities and fatality rate.
nhtsa_long <- vroom(
  file.path(INGEST_PATH, "nhtsa_crash/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(nchar(geography) == 2) %>%
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
nhtsa_crash_type_long <- vroom(
  file.path(INGEST_PATH, "nhtsa_crash/standard/data_crash_type.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(nchar(geography) == 2, age == "Overall", sex == "Overall") %>%
  pivot_longer(
    cols      = c(
      nhtsa_single_vehicle, nhtsa_rural, nhtsa_urban,
      nhtsa_pedestrian_involved, nhtsa_cyclist_involved
    ),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  select(geography, time, measure, value)

# CMU Delphi COVIDcast doctor-visit percentage for COVID-related symptoms.
# DC/PR/VI ship as lowercase postal abbreviations ("dc"/"pr"/"vi") rather
# than FIPS codes in this feed; recode them before the geography-level filter.
delphi_doc_long <- vroom(
  file.path(INGEST_PATH, "delphi_doctors_claims/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  mutate(geography = recode(geography, dc = "11", pr = "72", vi = "78")) %>%
  filter(nchar(geography) == 2, geography != "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# CMU Delphi COVIDcast hospital-admission percentage for COVID/flu. Same
# lowercase postal-abbreviation quirk as delphi_doc_long above.
delphi_hosp_long <- vroom(
  file.path(INGEST_PATH, "delphi_hospital_claims/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  mutate(geography = recode(geography, dc = "11", pr = "72", vi = "78")) %>%
  filter(nchar(geography) == 2, geography != "00") %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# AHRF workforce, facility, demographic, and environmental measures. Natively
# county-only; state rows (including territories, which AHRF covers) are
# aggregated upstream in the area-health-resource-files repo -- see that
# repo's ingest.R for the sum/weighted-mean/excluded treatment per measure.
ahrf_long <- vroom(
  file.path(INGEST_PATH, "area_health_resource_file/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography), nchar(geography) == 2, geography != "00") %>%
  pivot_longer(
    cols      = starts_with("ahrf_"),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  select(geography, time, measure, value)

combined <- bind_rows(
  chr_long, census_long, brfss_long,
  imm_long, svv_exempt_long, exempt_long, cms_long, epic_dx_long,
  nchs_overdose_rate_long, healthmap_long, nssp_long,
  nhtsa_long, nhtsa_crash_type_long, delphi_doc_long, delphi_hosp_long, ahrf_long,
  nchs_long, nchs_causes_long, noaa_heat_long, jhu_measles_long, bls_long, hud_long
) %>%
  arrange(geography, time, measure)

message("Combined ", nrow(combined), " rows across all sources")

states <- unique(combined$geography)
message("Writing state_rates.csv.gz for ", length(states), " states...")

for (fips in states) {
  state_data <- combined %>% filter(geography == fips)

  match_row <- state_fips %>% filter(state_fips == fips)
  if (nrow(match_row) == 0) {
    warning("FIPS ", fips, " not found in reference")
    next
  }

  # is_territory() (state abbreviation -> territory?) and
  # territory_rates_filename() come from geography_helpers.R, sourced above.
  # Territories get their own top-level territories/ folder instead of
  # states/ -- see scaffold_structure.R -- and a filename matching their
  # actual political status rather than reusing state_rates.csv.gz.
  is_terr        <- is_territory(match_row$state[1])
  top_level_dir  <- if (is_terr) "territories" else "states"
  rates_filename <- if (is_terr) territory_rates_filename(match_row$state[1]) else "state_rates.csv.gz"

  state_folder <- file.path(
    REPO_ROOT, top_level_dir,
    safe_name(match_row$geography_name[1])
  )

  dir.create(state_folder, recursive = TRUE, showWarnings = FALSE)
  vroom_write(
    state_data,
    file.path(state_folder, rates_filename),
    delim = ","
  )
}

message(
  "\nComplete. State rate files written to states/*/state_rates.csv.gz ",
  "and territories/*/{commonwealth,territory}_rates.csv.gz"
)
