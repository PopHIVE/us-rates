# =============================================================================
# geography_helpers.R
#
# Shared name -> folder/slug helpers for the geography pipeline. Sourced by
# scaffold_structure.R, populate_state_rates.R, populate_county_rates.R, and
# generate_geography_manifest.R so the folder-naming rule lives in exactly one
# place instead of four independently-maintained copies. Also holds
# ahrf_alaska_overrides, needed by populate_national_rates.R and
# populate_state_rates.R (for state/national AHRF aggregation) as well as
# populate_county_rates.R.
#
# Requires: stringr, dplyr (both already a dependency of every script that
# sources this).
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

# =============================================================================
# Geography lineage: county-equivalents renamed, split, or dissolved.
#
# Single source for check_geography_renaming.R (which fails the build on any
# (measure, time) reported under two generations) and
# generate_geography_manifest.R (which publishes it as activeFrom /
# activeThrough / supersededBy / supersedes). Keep it that way -- two lists
# would drift.
#
# `generations` is oldest-first. Codes within one generation are siblings from a
# split and may share a (measure, time); codes in different generations may not.
#
# Effective dates are the Census Bureau's, from its county-changes technical
# documentation. Unknown dates are NA, never guessed.
#
# Two limits on `supersededBy`:
#   1. Connecticut's counties and planning regions do not nest -- regions were
#      built from towns and several counties split across regions -- so each
#      retired county points at all nine. It is "see these instead", not a
#      containment map.
#   2. Alaska's 2008 Prince of Wales-Outer Ketchikan dissolution also moved land
#      into Ketchikan Gateway (02130) and Wrangell (02275), both still active.
#      Only the direct successor (02198) is recorded, matching the generation
#      model, so it does not cover the whole of the old area.
# =============================================================================

GEOGRAPHY_LINEAGE <- list(
  list(
    state = "CT",
    label = "legacy counties -> planning regions (2022)",
    # ct_old / ct_new are resolved from all_fips.csv.gz by the caller, since
    # tidycensus names legacy counties "X County" and regions by COG name.
    generations = list("CT_LEGACY_COUNTIES", "CT_PLANNING_REGIONS"),
    # Federal Register notice of June 6, 2022 adopting the nine Councils of
    # Governments as county equivalents; Census applied it from the 2022 vintage.
    effective = "2022-06-06"
  ),
  list(
    state = "AK",
    label = "Skagway-Yakutat-Angoon -> Skagway-Hoonah-Angoon -> Skagway, Hoonah-Angoon",
    generations = list("02231", "02232", c("02230", "02105")),
    # 02231 -> 02232 predates the Census change logs; only the 2007 split date
    # is documented, so the earlier boundary stays NA rather than invented.
    effective = c(NA, "2007-06-20")
  ),
  list(
    state = "AK",
    label = "Prince of Wales-Outer Ketchikan -> Prince of Wales-Hyder (2008)",
    generations = list("02201", "02198"),
    effective = "2008-05-19"
  ),
  list(
    state = "AK",
    label = "Wrangell-Petersburg -> Wrangell, Petersburg (2008)",
    generations = list("02280", c("02195", "02275")),
    effective = "2008-06-01"
  ),
  list(
    state = "AK",
    label = "Wade Hampton -> Kusilvak (renamed 2015)",
    generations = list("02270", "02158"),
    effective = "2015-07-01"
  ),
  list(
    state = "AK",
    label = "Valdez-Cordova -> Chugach, Copper River (2019)",
    generations = list("02261", c("02063", "02066")),
    effective = "2019-01-02"
  )
)

# Expand GEOGRAPHY_LINEAGE into one row per FIPS code, with the lineage fields
# the manifest publishes. `ct_old` / `ct_new` resolve the two Connecticut
# placeholders; pass them from all_fips.csv.gz so the naming rule stays in one
# place. Returns a tibble: fips, retired, activeFrom, activeThrough,
# supersededBy, supersedes (the last two list-columns, since a split has
# several successors).
#
# `retired` is a separate boolean rather than being inferred from
# `activeThrough`, because a missing date is genuinely ambiguous otherwise:
# 02231 (Skagway-Yakutat-Angoon) is long dissolved but its boundary date
# predates the Census change logs, so its activeThrough is NA. Inferring
# "NA means current" would have published it as a live geography. `retired`
# is the field to trust; the dates are supporting detail.
geography_lineage_rows <- function(ct_old, ct_new) {
  resolve <- function(codes) {
    unlist(lapply(codes, function(c) {
      if (identical(c, "CT_LEGACY_COUNTIES")) ct_old
      else if (identical(c, "CT_PLANNING_REGIONS")) ct_new
      else c
    }), use.names = FALSE)
  }

  dplyr::bind_rows(lapply(GEOGRAPHY_LINEAGE, function(event) {
    gens <- lapply(event$generations, resolve)
    n <- length(gens)
    # One boundary between each pair of consecutive generations.
    eff <- rep(as.character(event$effective), length.out = n - 1)

    dplyr::bind_rows(lapply(seq_len(n), function(i) {
      tibble::tibble(
        fips = gens[[i]],
        # Any generation but the last has been superseded.
        retired = i < n,
        # Created at the boundary that ended the previous generation.
        activeFrom = if (i == 1) NA_character_ else eff[i - 1],
        # Retired at the boundary that started the next generation.
        activeThrough = if (i == n) NA_character_ else eff[i],
        supersededBy = if (i == n) list(character(0)) else list(gens[[i + 1]]),
        supersedes = if (i == 1) list(character(0)) else list(gens[[i - 1]])
      )
    }))
  }))
}
