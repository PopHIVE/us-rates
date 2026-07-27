# =============================================================================
# geography_helpers.R
#
# Shared name -> folder/slug helpers for the geography pipeline. Sourced by
# scaffold_structure.R, populate_state_rates.R, populate_county_rates.R, and
# generate_geography_manifest.R so the folder-naming rule lives in exactly one
# place instead of four independently-maintained copies.
#
# Requires: stringr (already a dependency of every script that sources this).
# =============================================================================

# "Autauga County" -> "autauga"; "New York County" -> "new_york";
# "St. Clair County" -> "st_clair"; "Baltimore city" -> "baltimore_city"
# (only a trailing "_county" is stripped -- other suffixes like "city" or
# "municipio" are kept, matching what's already on disk).
safe_name <- function(x) {
  x <- stringr::str_to_lower(x)
  x <- stringr::str_replace_all(x, "[^a-z0-9]+", "_")
  x <- stringr::str_remove(x, "_county$")
  x <- stringr::str_remove(x, "^_|_$")
  x
}

# "St. Clair County" -> "st-clair" (safe_name() with hyphens, for URL slugs).
slug_name <- function(x) stringr::str_replace_all(safe_name(x), "_", "-")

# The 6 non-state, non-DC U.S. territories with a 2-digit FIPS code in
# tidycensus::fips_codes: American Samoa, Guam, Northern Mariana Islands,
# Puerto Rico, U.S. Minor Outlying Islands, and the U.S. Virgin Islands.
#
# These get their own top-level `territories/` folder instead of `states/`
# (see populate_state_rates.R / populate_county_rates.R / scaffold_structure.R
# / generate_geography_manifest.R) -- they aren't states, and lumping them in
# with the 50 states + DC was misleading. DC itself is a state-equivalent for
# this repo's purposes and stays under `states/`.
US_TERRITORY_ABBRS <- c("AS", "GU", "MP", "PR", "UM", "VI")

is_territory <- function(state_abbr) state_abbr %in% US_TERRITORY_ABBRS

TERRITORY_COMMONWEALTH_ABBRS <- c("PR", "MP")

territory_rates_filename <- function(state_abbr) {
  if_else(
    state_abbr %in% TERRITORY_COMMONWEALTH_ABBRS,
    "commonwealth_rates.csv.gz",
    "territory_rates.csv.gz"
  )
}
