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
library(vroom)
library(stringr)

# Config
REPO_ROOT <- "."
INGEST_PATH <- "../Ingest/data"

# Load FIPS reference to map FIPS codes to state/county folders
all_fips <- vroom(file.path(REPO_ROOT, "resources/all_fips.csv.gz"),
                  col_types = "cccc", show_col_types = FALSE)
county_fips <- all_fips %>%
  filter(nchar(geography) == 5) %>%
  rename(fips = geography)

message("Loading CHR and Census data...")

# Read CHR (wide format: geography, time, measure columns)
chr_wide <- vroom(
  file.path(INGEST_PATH, "county_health_rankings/standard/data_county.csv.gz"),
  show_col_types = FALSE
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

# Combine both sources
combined <- bind_rows(chr_long, census_long) %>%
  arrange(geography, time, measure)

message("Combined ", nrow(combined), " rows from CHR and Census")

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

  state_name <- match_row$state[1]
  county_name <- match_row$geography_name[1]

  # Determine folder path
  safe_name <- function(x) {
    x %>%
      str_to_lower() %>%
      str_replace_all("[^a-z0-9]+", "_") %>%
      str_remove("_county$") %>%
      str_remove("^_|_$")
  }

  county_folder <- file.path(
    REPO_ROOT, "states", safe_name(state_name), "counties",
    paste0(county_fips_code, "_", safe_name(county_name))
  )

  dir.create(county_folder, recursive = TRUE, showWarnings = FALSE)

  # Write county_rates.csv.gz
  output_file <- file.path(county_folder, "county_rates.csv.gz")
  vroom_write(county_data, output_file)
}

message("\nComplete. County rate files written to states/*/counties/*/ folders.")
