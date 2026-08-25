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

REPO_ROOT <- "."

if (!file.exists(file.path(REPO_ROOT, "measure_info.json"))) {
  stop(
    "build_measure_vintages.R must be run from the us-rates repo root, e.g.:\n",
    "  Rscript code/build_measure_vintages.R"
  )
}

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
vintages <- meta %>%
  mutate(years_used = str_trim(as.character(years_used))) %>%
  filter(!is.na(years_used), years_used != "", years_used != "NA") %>%
  left_join(col_names, by = "measure_id") %>%
  rowwise() %>%
  mutate(
    yrs = list(as.integer(unlist(str_extract_all(years_used, "(?:19|20)\\d{2}"))))
  ) %>%
  ungroup() %>%
  filter(lengths(yrs) > 0) %>%
  transmute(
    measure_id   = col_name,
    release_year = as.integer(year),
    # Matches the `time` column in every rate file, so this joins directly.
    release_time = paste0(year, "-12-31"),
    vintage      = years_used,
    vintage_min  = vapply(yrs, min, integer(1)),
    vintage_max  = vapply(yrs, max, integer(1)),
    vintage_lag  = release_year - vintage_min
  ) %>%
  # Two CHR&R measure_ids can slug to one measure_id here when CHR&R retires an
  # id and reissues the same concept (see the collision note in
  # county_health_rankings/ingest.R). Where both land in one release they
  # produce identical rows -- chr_access_to_healthy_foods in 2012 is the only
  # current case -- so collapsing them is lossless.
  distinct() %>%
  arrange(measure_id, release_year)

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

out_path <- file.path(REPO_ROOT, "tracker", "measure_vintages.csv")
vroom_write(vintages, out_path, delim = ",")

message(
  "\nWrote ", nrow(vintages), " (measure, release) rows covering ",
  n_distinct(vintages$measure_id), " measures across releases ",
  min(vintages$release_year), "-", max(vintages$release_year), "."
)
message("  median release-vs-vintage lag: ", median(vintages$vintage_lag), " years")
message("  max lag: ", max(vintages$vintage_lag), " years")
message("\nWritten to ", out_path)
