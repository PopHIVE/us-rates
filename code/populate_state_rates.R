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
  show_col_types = FALSE
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
  pivot_longer(
    cols = -c(geography, time),
    names_to = "measure",
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
  filter(!is.na(value)) %>%
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
  filter(!is.na(geography)) %>%
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
    time    = month_end(time)
  )

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

combined <- bind_rows(
  chr_long, census_long, brfss_long,
  imm_long, svv_exempt_long, exempt_long, healthmap_long,
  nchs_long, nchs_causes_long
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

  state_folder <- file.path(
    REPO_ROOT, "states",
    safe_name(match_row$geography_name[1])
  )

  dir.create(state_folder, recursive = TRUE, showWarnings = FALSE)
  vroom_write(
    state_data,
    file.path(state_folder, "state_rates.csv.gz"),
    delim = ","
  )
}

message("\nComplete. State rate files written to states/*/state_rates.csv.gz")
