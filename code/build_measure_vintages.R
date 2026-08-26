# =============================================================================
# build_measure_vintages.R
#
# Writes tracker/measure_vintages.csv: one row per (measure, release), giving
# the true data years behind each CHR&R release of each measure.
#
# Why this exists separately from the vintage fields in measure_info.json:
# those describe only each measure's most recent release, but the rate files
# (and especially the *_latest.csv.gz files the explorer reads) carry whatever
# release a given geography most recently has data for. Small counties are
# suppressed in recent releases and fall back to older ones, so for ~3% of
# county observations -- and 34-49% of them for chr_infant_mortality,
# chr_homicides, and chr_disconnected_youth -- the newest release's vintage is
# the wrong answer. Joining this table on BOTH measure and time gives the
# vintage of the release each value actually came from.
#
# Join contract:
#   rate file (geography, time, measure, value)
#     |> left_join(measure_vintages, by = c("measure" = "measure_id",
#                                           "time"    = "release_time"))
#
# Source: years_used in CHR&R's own t_measure_years.csv, which ships in the
# PopHIVE/county_health_rankings repo alongside the Zenodo release archive.
#
# Usage:
#   Rscript code/build_measure_vintages.R
# =============================================================================

library(dplyr)
library(vroom)
library(stringr)
library(jsonlite)

REPO_ROOT <- "."

`%||%` <- function(x, y) if (is.null(x)) y else x

if (!file.exists(file.path(REPO_ROOT, "measure_info.json"))) {
  stop(
    "build_measure_vintages.R must be run from the us-rates repo root, e.g.:\n",
    "  Rscript code/build_measure_vintages.R"
  )
}

info <- fromJSON(
  file.path(REPO_ROOT, "measure_info.json"),
  simplifyVector = FALSE
)
info <- info[names(info) != "_sources"]

# Prefer a local checkout of the CHR&R source repo (the usual dev layout, and
# it keeps the build offline); fall back to the canonical raw URL so this also
# works on a fresh machine or in CI.
local_meta <- "../county_health_rankings/raw/t_measure_years.csv"
remote_meta <- paste0(
  "https://raw.githubusercontent.com/PopHIVE/county_health_rankings/main",
  "/raw/t_measure_years.csv"
)

meta_path <- if (file.exists(local_meta)) local_meta else remote_meta
message("Reading measure metadata from: ", meta_path)

# Measure 157 is an internal CHR&R test measure, excluded upstream too.
meta <- vroom(meta_path, show_col_types = FALSE) %>%
  filter(measure_id != 157)

# Canonical column name = slug of each measure's MOST RECENT name. This mirrors
# county_health_rankings/ingest.R exactly -- if that rule ever changes, this
# must change with it or the join keys silently stop matching.
col_names <- meta %>%
  select(year, measure_id, measure_name) %>%
  group_by(measure_id) %>%
  slice_max(year, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  mutate(
    col_name = paste0(
      "chr_",
      gsub("^_|_$", "", gsub("[^a-z0-9]+", "_", tolower(measure_name)))
    )
  ) %>%
  select(measure_id, col_name)

# years_used is free text and not always a range: single years ("2022"),
# ranges ("2016-2022"), and disjoint sets ("2020 & 2016") all occur. Keep the
# string verbatim -- collapsing "2020 & 2016" to a range would assert a
# continuity that isn't there -- and derive min/max from the years present.
# Every release gets a row, including the ~28 where CHR&R left years_used blank
# (measures retired after 2010/2011, the state-specific _fl/_ny families, % Rural
# in 2016, and non-health admin measures). Those rows carry NA vintage but real
# format_type, description and credit -- dropping them would leave those measures
# with no provenance at all and would silently strip their CHR&R attribution.
vintages <- meta %>%
  mutate(years_used = str_trim(as.character(years_used))) %>%
  left_join(col_names, by = "measure_id") %>%
  rowwise() %>%
  mutate(
    yrs = list(
      if (is.na(years_used) || years_used %in% c("", "NA")) {
        integer(0)
      } else {
        as.integer(unlist(str_extract_all(years_used, "(?:19|20)\\d{2}")))
      }
    )
  ) %>%
  ungroup() %>%
  transmute(
    measure_id   = col_name,
    release_year = as.integer(year),
    # Matches the `time` column in every rate file, so this joins directly.
    release_time = paste0(year, "-12-31"),
    vintage      = if_else(lengths(yrs) > 0, years_used, NA_character_),
    vintage_min  = vapply(yrs, function(v) if (length(v)) min(v) else NA_integer_, integer(1)),
    vintage_max  = vapply(yrs, function(v) if (length(v)) max(v) else NA_integer_, integer(1)),
    vintage_lag  = release_year - vintage_min,
    # CHR&R's display format code, carried through because it is the only
    # reliable signal that a measure changed UNITS between releases.
    # years_used cannot be trusted for this: chr_drinking_water_violations
    # went from a percentage (format_type 1, "Percentage of population
    # potentially exposed") to a yes/no indicator (format_type 5, "presence
    # of a violation") between the 2015 and 2016 releases while its
    # years_used string stayed identical, so the redefinition is invisible in
    # the vintage alone. A change in this column across consecutive releases
    # means values on either side are not comparable, whatever the vintage says.
    format_type  = as.integer(format_type)
  ) %>%
  # Two CHR&R measure_ids can slug to one measure_id here when CHR&R retires an
  # id and reissues the same concept (see the collision note in
  # county_health_rankings/ingest.R). Where both land in one release they
  # produce identical rows -- chr_access_to_healthy_foods in 2012 is the only
  # current case -- so collapsing them is lossless.
  distinct() %>%
  arrange(measure_id, release_year) %>%
  mutate(compiled_via = "chr")

# -----------------------------------------------------------------------------
# County-level Census overrides.
#
# 17 measures keep a chr_ id while a single vintage of each is replaced by a
# direct Census pull (see the census_direct_long block in
# populate_county_rates.R). The id is deliberate: census_direct_long is bound
# first and distinct(geography, time, measure) keeps the first row, so matching
# ids are what makes the Census value win. Renaming would break the override and
# mislabel the other ~93% of each series, which is still CHR&R -- including
# every state and national row, since the PEP/SAIPE/SAHIE files are county-only.
#
# What the id cannot express is that ONE year of each series has a different
# origin, so it is recorded here instead, per (measure, release_time).
#
# These are interior patches, not the newest point: CHR&R runs to 2025 while the
# Census files sit at 2020-2024. chr_census_participation is the inverse case --
# its Census year is the OLDEST in the series -- so never assume the direct year
# is the latest one.
# -----------------------------------------------------------------------------
census_override <- bind_rows(
  tibble(
    measure_id = c(
      "chr_population", "chr_65_and_older", "chr_below_18_years_of_age",
      "chr_female", "chr_american_indian_or_alaska_native", "chr_asian",
      "chr_native_hawaiian_or_other_pacific_islander", "chr_non_hispanic_black",
      "chr_non_hispanic_white", "chr_hispanic"
    ),
    release_time = "2023-12-31", via_county = "census_pep"
  ),
  tibble(
    measure_id = c("chr_children_in_poverty", "chr_median_household_income"),
    release_time = "2024-12-31", via_county = "census_saipe"
  ),
  tibble(
    measure_id = c("chr_uninsured", "chr_uninsured_adults", "chr_uninsured_children"),
    release_time = "2024-12-31", via_county = "census_sahie"
  ),
  tibble(
    measure_id = "chr_census_participation",
    release_time = "2020-12-31", via_county = "census_oqm"
  ),
  # Derived, not passed through: 1 - census_ur_pct_urban_pop. The underlying
  # value is a static 2020 decennial figure carried on the latest ACS vintage
  # year, so this release_time is not a data year.
  tibble(
    measure_id = "chr_rural",
    release_time = "2024-12-31", via_county = "census_decennial"
  )
)

vintages <- vintages %>%
  left_join(census_override, by = c("measure_id", "release_time")) %>%
  mutate(
    # compiled_via_county differs from compiled_via only where a direct Census
    # pull replaces CHR&R at county level; state and national rows for that same
    # (measure, time) stay CHR&R, which is why this is a separate column rather
    # than an edit to compiled_via.
    compiled_via_county = coalesce(via_county, compiled_via),
    county_override = !is.na(via_county)
  ) %>%
  select(-via_county)

# Most overrides replace a CHR&R release that already exists, so the join above
# is enough. But an override year can have no CHR&R release behind it at all:
# chr_census_participation exists in us-rates for 2020 ONLY because of the OQM
# pull -- CHR&R first published the measure in its 2023 release. Those rows have
# to be added, or the (measure, time) pairs they cover never resolve.
census_only <- census_override %>%
  anti_join(vintages, by = c("measure_id", "release_time")) %>%
  mutate(
    release_year = as.integer(substr(release_time, 1, 4)),
    # For a Census-sourced year the release IS the data year -- no CHR&R
    # publication lag sits between them.
    vintage = as.character(release_year),
    vintage_min = release_year,
    vintage_max = release_year,
    vintage_lag = 0L,
    format_type = NA_integer_,
    compiled_via = via_county,
    compiled_via_county = via_county,
    county_override = TRUE
  ) %>%
  select(-via_county)

vintages <- bind_rows(vintages, census_only) %>%
  arrange(measure_id, release_year)

n_override <- sum(vintages$county_override)
if (n_override != 17) {
  stop(
    "Expected all 17 county Census overrides to be represented, got ",
    n_override, ". A patch year has moved in populate_county_rates.R -- ",
    "reconcile census_override before trusting compiled_via_county."
  )
}

# (measure_id, release_time) is the join key. A duplicate would silently fan out
# rows on every left_join against it -- duplicating observations rather than
# erroring -- so fail loudly here instead. This trips only if a future reissue
# lands in a shared release carrying DIFFERENT years_used, which distinct()
# above cannot collapse; resolve it by picking the surviving measure_id.
dupe_keys <- vintages %>%
  count(measure_id, release_time) %>%
  filter(n > 1)

if (nrow(dupe_keys) > 0) {
  stop(
    "measure_vintages.csv join key is not unique -- ", nrow(dupe_keys),
    " (measure_id, release_time) pair(s) carry conflicting vintages:\n  ",
    paste0(dupe_keys$measure_id, " ", dupe_keys$release_time, collapse = "\n  ")
  )
}

# -----------------------------------------------------------------------------
# Definition-change report.
#
# Neither vintage nor format_type is sufficient to spot a measure whose UNITS
# changed. chr_preventable_hospital_stays switched denominator from "per 1,000
# Medicare enrollees" to "per 100,000" between the 2018 and 2019 releases with
# format_type fixed at 0 and years_used advancing normally -- the change is
# stated only in the description prose. Diffing that prose across consecutive
# releases is the one signal that catches this class, so surface every change
# and let a human judge which are cosmetic and which are real redefinitions.
# -----------------------------------------------------------------------------
descriptions <- meta %>%
  left_join(col_names, by = "measure_id") %>%
  transmute(
    measure_id  = col_name,
    release_year = as.integer(year),
    description = str_squish(as.character(description))
  ) %>%
  filter(!is.na(description), description != "", description != "NA") %>%
  distinct() %>%
  arrange(measure_id, release_year) %>%
  group_by(measure_id) %>%
  mutate(description_changed = !is.na(lag(description)) & lag(description) != description) %>%
  ungroup()

vintages <- vintages %>%
  left_join(descriptions, by = c("measure_id", "release_year")) %>%
  mutate(description_changed = coalesce(description_changed, FALSE))



out_path <- file.path(REPO_ROOT, "tracker", "measure_vintages.csv")
vroom_write(vintages, out_path, delim = ",")

message(
  "\nWrote ", nrow(vintages), " (measure, release) rows covering ",
  n_distinct(vintages$measure_id), " measures across releases ",
  min(vintages$release_year), "-", max(vintages$release_year), "."
)
message("  median release-vs-vintage lag: ", median(vintages$vintage_lag, na.rm = TRUE), " years")
message("  max lag: ", max(vintages$vintage_lag, na.rm = TRUE), " years")
message(
  "  releases where CHR&R reworded the description: ",
  sum(vintages$description_changed), " across ",
  n_distinct(vintages$measure_id[vintages$description_changed]), " measures"
)
message("    Screen these for unit/denominator changes -- they are invisible in")
message("    both vintage and format_type. See chr_preventable_hospital_stays 2019.")
message("\nWritten to ", out_path)

