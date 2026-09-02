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
  mutate(
    top_level_dir = if_else(is_territory(state), "territories", "states"),
    rates_filename = if_else(is_territory(state), territory_rates_filename(state), "state_rates.csv.gz")
  )

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
    dataPath  = paste0(top_level_dir, "/", safe_name(geography_name), "/", rates_filename)
  ) %>%
  arrange(geography_name) %>%
  select(fips, name, level, state, stateFips, slug, dataPath)

# -----------------------------------------------------------------------------
# Lineage. Retired and current county-equivalents both live in this manifest,
# since upstream sources migrate on their own schedules; these fields are how a
# consumer tells them apart. GEOGRAPHY_LINEAGE in geography_helpers.R is the
# source, shared with check_geography_renaming.R.
# -----------------------------------------------------------------------------

ct_fips <- all_fips %>% filter(state == "CT", nchar(geography) == 5)
ct_old <- ct_fips %>% filter(str_detect(geography_name, " County$")) %>% pull(geography)
ct_new <- ct_fips %>% filter(!str_detect(geography_name, " County$")) %>% pull(geography)

if (length(ct_old) == 0 || length(ct_new) == 0) {
  stop(
    "Expected both legacy CT counties and planning regions in all_fips.csv.gz, ",
    "found ", length(ct_old), " county code(s) and ", length(ct_new),
    " planning region code(s). Check the tidycensus version used by all_fips.R."
  )
}

lineage <- geography_lineage_rows(ct_old, ct_new)

missing_lineage <- setdiff(lineage$fips, all_fips$geography)
if (length(missing_lineage) > 0) {
  stop(
    "GEOGRAPHY_LINEAGE names FIPS code(s) absent from all_fips.csv.gz: ",
    paste(missing_lineage, collapse = ", "),
    ". Fix the lineage table or the FIPS reference before publishing a manifest."
  )
}

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
  left_join(lineage, by = "fips") %>%
  arrange(state_name, geography_name) %>%
  select(
    fips, name, level, state, stateFips, slug, dataPath,
    retired, activeFrom, activeThrough, supersededBy, supersedes
  )

manifest <- bind_rows(national_row, state_rows, county_rows) %>%
  # NA for counties with no lineage row, and for the national/state rows, which
  # carry no lineage columns at all. None of them are retired.
  mutate(retired = coalesce(retired, FALSE))

# Unwrap a list-column cell, dropping the NA left_join leaves on counties with
# no lineage. I() keeps the result a JSON array even at length 1 -- auto_unbox
# would emit a bare string for a rename and an array for a split. I() rejects
# NULL, hence the guard.
as_fips_array <- function(cell) {
  v <- if (is.list(cell)) cell[[1]] else cell
  v <- v[!is.na(v)]
  if (length(v) == 0) NULL else I(as.character(v))
}

is_blank <- function(v) is.null(v) || length(v) == 0 || all(is.na(v))

manifest_list <- lapply(seq_len(nrow(manifest)), function(i) {
  row <- as.list(manifest[i, ])
  row$supersededBy <- as_fips_array(row$supersededBy)
  row$supersedes   <- as_fips_array(row$supersedes)
  # `retired` is published on every entry, never omitted and never null -- an
  # absent boolean forces the inference the field exists to remove. The other
  # four are dropped when empty: for them absence has one meaning (no recorded
  # boundary, no successor).
  drop <- vapply(names(row), function(f) {
    f %in% c("activeFrom", "activeThrough", "supersededBy", "supersedes") &&
      is_blank(row[[f]])
  }, logical(1))
  row[!drop]
})

write_json(manifest_list, OUT_FILE, pretty = TRUE, auto_unbox = TRUE, na = "null")

n_retired <- sum(manifest$retired, na.rm = TRUE)
message(
  "Wrote ", nrow(manifest), " geographies to ", OUT_FILE,
  " (", n_retired, " marked retired, ", nrow(lineage) - n_retired,
  " successor geograph", if (nrow(lineage) - n_retired == 1) "y" else "ies", ")"
)
