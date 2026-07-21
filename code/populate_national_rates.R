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

year_end <- function(y) as.Date(paste0(as.integer(y), "-12-31"))

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

combined <- bind_rows(
  chr_long, brfss_long, imm_long, healthmap_long, nchs_causes_long
) %>%
  arrange(geography, time, measure)

message("Combined ", nrow(combined), " national rows across all sources")

national_dir <- file.path(REPO_ROOT, "national")
dir.create(national_dir, recursive = TRUE, showWarnings = FALSE)

vroom_write(combined, file.path(national_dir, "national_rates.csv.gz"), delim = ",")

message("\nComplete. Written to national/national_rates.csv.gz")
