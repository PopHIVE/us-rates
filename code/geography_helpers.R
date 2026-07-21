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
