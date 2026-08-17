# =============================================================================
# populate_latest_rates.R
#
# Derives "latest value per geography x measure" cuts from the state and
# county rate files already written by populate_state_rates.R and
# populate_county_rates.R, for charts that need one row per place instead of
# a full time series.
#
# Writes:
#   states/states_latest.csv.gz                  - one row per state/territory
#                                                   x measure, using each
#                                                   geography's own latest
#                                                   time for that measure (no
#                                                   national row)
#   states|territories/{place}/counties_latest.csv.gz
#                                                 - one row per county (or
#                                                   territory subdivision) in
#                                                   that place x measure, same
#                                                   latest-per-geography rule
#
# Usage:
#   Rscript code/populate_latest_rates.R
# =============================================================================

library(dplyr)
library(vroom)
library(stringr)

REPO_ROOT <- "."

source(file.path(REPO_ROOT, "code", "geography_helpers.R"))

# For each (geography, measure), keep only the row from that geography's own
# most recent time -- different geographies/measures may have different
# latest times, since sources update on their own schedules.
latest_by_geography_measure <- function(df) {
  df %>%
    group_by(geography, measure) %>%
    slice_max(time, n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    select(geography, time, measure, value) %>%
    arrange(geography, measure)
}

read_rates <- function(path) {
  vroom(path, col_types = "cDcd", show_col_types = FALSE)
}

all_fips <- vroom(
  file.path(REPO_ROOT, "resources/all_fips.csv.gz"),
  col_types = "ccc", show_col_types = FALSE
)

state_fips <- all_fips %>%
  filter(nchar(geography) == 2, geography != "00")

# ---------------------------------------------------------------------------
# 1. states/states_latest.csv.gz - all states, DC, and territories
# ---------------------------------------------------------------------------

message("Loading state and territory rate files...")

state_rate_files <- state_fips %>%
  mutate(
    is_terr        = is_territory(state),
    top_level_dir  = if_else(is_terr, "territories", "states"),
    rates_filename = if_else(is_terr, territory_rates_filename(state), "state_rates.csv.gz"),
    path           = file.path(REPO_ROOT, top_level_dir, safe_name(geography_name), rates_filename)
  ) %>%
  filter(file.exists(path))

state_long <- bind_rows(lapply(state_rate_files$path, read_rates))

states_latest <- latest_by_geography_measure(state_long)

message("Writing states/states_latest.csv.gz (", nrow(states_latest), " rows)...")
vroom_write(
  states_latest,
  file.path(REPO_ROOT, "states", "states_latest.csv.gz"),
  delim = ","
)

# ---------------------------------------------------------------------------
# 2. {states|territories}/{place}/counties_latest.csv.gz - one per place
# ---------------------------------------------------------------------------

place_dirs <- state_fips %>%
  mutate(
    top_level_dir = if_else(is_territory(state), "territories", "states"),
    folder        = safe_name(geography_name)
  )

message("Writing counties_latest.csv.gz for ", nrow(place_dirs), " states/territories...")

for (i in seq_len(nrow(place_dirs))) {
  place_folder <- file.path(REPO_ROOT, place_dirs$top_level_dir[i], place_dirs$folder[i])
  county_files <- Sys.glob(file.path(place_folder, "counties", "*", "county_rates.csv.gz"))

  if (length(county_files) == 0) next

  county_long <- bind_rows(lapply(county_files, read_rates))
  counties_latest <- latest_by_geography_measure(county_long)

  vroom_write(
    counties_latest,
    file.path(place_folder, "counties_latest.csv.gz"),
    delim = ","
  )
}

message(
  "\nComplete. Latest-value files written to states/states_latest.csv.gz ",
  "and states|territories/*/counties_latest.csv.gz"
)
