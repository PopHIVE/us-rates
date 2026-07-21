# =============================================================================
# generate_geography_manifest.R
#
# Builds us-rates-geographies.json: a flat manifest of every geography
# (national / state / county) with its display name, slug, and the relative
# path to its rate file, for front-end/site consumption.
#
# dataPath is built with the exact same folder-naming rule scaffold_structure.R,
# populate_state_rates.R, and populate_county_rates.R use (derived from
# resources/all_fips.csv.gz), so it always matches whatever is actually on
# disk today -- including Puerto Rico's state_rates.csv.gz living under
# states/NA/. PR isn't one of base R's 50 states, so all_fips.R leaves its
# geography_name as NA; that's an existing, intentional convention for
# non-state geographies and is left untouched here.
#
# name/slug use a separate display-name lookup (tidycensus::fips_codes$state_name,
# which does cover territories) so non-state geographies still get a readable
# name ("Puerto Rico") even though their files live under the NA folder.
#
# Usage:
#   Rscript code/generate_geography_manifest.R
# =============================================================================

library(dplyr)
library(stringr)
library(vroom)
library(jsonlite)
library(tidycensus)

REPO_ROOT <- "."
FIPS_FILE <- file.path(REPO_ROOT, "resources/all_fips.csv.gz")
OUT_FILE  <- file.path(REPO_ROOT, "us-rates-geographies.json")

all_fips <- vroom(FIPS_FILE, col_types = "ccc", show_col_types = FALSE)

# states/NA/ is currently shared by every non-state geography (PR, AS, GU, MP,
# UM, VI) -- populate_state_rates.R writes each one's state_rates.csv.gz to
# that same path, so only one territory's state-level data actually survives
# there. Until that's addressed, restrict this manifest to the geographies
# known to be reliably represented on disk: the 50 states, DC, and PR.
included_territories <- c(state.abb, "DC", "PR")

all_fips <- all_fips %>%
  filter(geography == "00" | state %in% included_territories)

# Same folder-naming rule used elsewhere in the pipeline. NA in -> "NA" out
# (matches file.path()'s NA-to-"NA" coercion), so dataPath stays consistent
# with what scaffold_structure.R / populate_*_rates.R actually create on disk.
safe_name <- function(x) {
  x %>%
    str_to_lower() %>%
    str_replace_all("[^a-z0-9]+", "_") %>%
    str_remove("_county$") %>%
    str_remove("^_|_$")
}

slug_name <- function(x) str_replace_all(safe_name(x), "_", "-")

# Display-name fallback for state-level rows where geography_name is NA --
# only affects the human-facing name/slug fields below.
territory_names <- tidycensus::fips_codes %>%
  distinct(state, state_name)

state_fips <- all_fips %>%
  filter(geography != "00", nchar(geography) == 2)

state_display <- state_fips %>%
  left_join(territory_names, by = "state") %>%
  mutate(display_name = coalesce(geography_name, state_name)) %>%
  select(geography, state, raw_name = geography_name, display_name)

county_fips <- all_fips %>%
  filter(nchar(geography) == 5)

national_row <- tibble(
  fips      = "00",
  name      = "United States",
  level     = "national",
  state     = NA_character_,
  stateFips = NA_character_,
  slug      = "us",
  dataPath  = "national/national_rates.csv.gz"
)

state_rows <- state_display %>%
  mutate(
    fips      = geography,
    name      = display_name,
    level     = "state",
    stateFips = geography,
    slug      = slug_name(display_name),
    dataPath  = paste0("states/", safe_name(raw_name), "/state_rates.csv.gz")
  ) %>%
  arrange(display_name) %>%
  select(fips, name, level, state, stateFips, slug, dataPath)

county_rows <- county_fips %>%
  left_join(
    state_display %>% select(state, state_raw_name = raw_name, state_display_name = display_name),
    by = "state"
  ) %>%
  mutate(
    fips      = geography,
    name      = geography_name,
    level     = "county",
    stateFips = str_sub(geography, 1, 2),
    slug      = paste0(geography, "-", slug_name(geography_name)),
    dataPath  = paste0(
      "states/", safe_name(state_raw_name), "/counties/",
      geography, "_", safe_name(geography_name), "/county_rates.csv.gz"
    )
  ) %>%
  arrange(state_display_name, geography_name) %>%
  select(fips, name, level, state, stateFips, slug, dataPath)

manifest <- bind_rows(national_row, state_rows, county_rows)

write_json(manifest, OUT_FILE, pretty = TRUE, auto_unbox = TRUE, na = "null")

message("Wrote ", nrow(manifest), " geographies to ", OUT_FILE)
