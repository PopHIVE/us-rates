# =============================================================================
# generate_geography_manifest.R
#
# Builds us-rates-geographies.json: a flat manifest of every geography
# (national / state / territory / county) with its display name, slug, and
# the relative path to its rate file, for front-end/site consumption.
#
# dataPath is built with the exact same folder-naming rule scaffold_structure.R,
# populate_state_rates.R, and populate_county_rates.R use (derived from
# resources/all_fips.csv.gz -- geography_name comes straight from
# tidycensus::fips_codes$state_name there, so it's populated for every state,
# DC, and territory alike), so it always matches whatever is actually on disk.
#
# Usage:
#   Rscript code/generate_geography_manifest.R
# =============================================================================

library(dplyr)
library(stringr)
library(vroom)
library(jsonlite)

REPO_ROOT <- "."
FIPS_FILE <- file.path(REPO_ROOT, "resources/all_fips.csv.gz")
OUT_FILE  <- file.path(REPO_ROOT, "us-rates-geographies.json")

source(file.path(REPO_ROOT, "code", "geography_helpers.R"))

all_fips <- vroom(FIPS_FILE, col_types = "ccc", show_col_types = FALSE)

# safe_name()/slug_name() (place name -> folder name / URL slug) and
# is_territory() (state abbreviation -> territory?) come from
# geography_helpers.R, sourced above -- the same rules scaffold_structure.R
# and populate_*_rates.R use, so dataPath stays consistent with what's
# actually on disk.

state_fips <- all_fips %>%
  filter(geography != "00", nchar(geography) == 2) %>%
  mutate(top_level_dir = if_else(is_territory(state), "territories", "states"))

county_fips <- all_fips %>%
  filter(nchar(geography) == 5) %>%
  left_join(
    state_fips %>% select(state, state_name = geography_name, top_level_dir),
    by = "state"
  )

national_row <- tibble(
  fips      = "00",
  name      = "United States",
  level     = "national",
  state     = NA_character_,
  stateFips = NA_character_,
  slug      = "us",
  dataPath  = "national/national_rates.csv.gz"
)

state_rows <- state_fips %>%
  mutate(
    fips      = geography,
    name      = geography_name,
    level     = if_else(is_territory(state), "territory", "state"),
    stateFips = geography,
    slug      = slug_name(geography_name),
    dataPath  = paste0(top_level_dir, "/", safe_name(geography_name), "/state_rates.csv.gz")
  ) %>%
  arrange(geography_name) %>%
  select(fips, name, level, state, stateFips, slug, dataPath)

county_rows <- county_fips %>%
  mutate(
    fips      = geography,
    name      = geography_name,
    level     = "county",
    stateFips = str_sub(geography, 1, 2),
    slug      = paste0(geography, "-", slug_name(geography_name)),
    dataPath  = paste0(
      top_level_dir, "/", safe_name(state_name), "/counties/",
      geography, "_", safe_name(geography_name), "/county_rates.csv.gz"
    )
  ) %>%
  arrange(state_name, geography_name) %>%
  select(fips, name, level, state, stateFips, slug, dataPath)

manifest <- bind_rows(national_row, state_rows, county_rows)

write_json(manifest, OUT_FILE, pretty = TRUE, auto_unbox = TRUE, na = "null")

message("Wrote ", nrow(manifest), " geographies to ", OUT_FILE)
