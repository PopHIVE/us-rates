# =============================================================================
# build_measure_vintages.R
#
# Writes tracker/measure_vintages.csv: one row per (measure, release), giving
# the data years, units and compiler behind each CHR&R release.
#
# Join on BOTH keys -- the measure-level fields in measure_info.json describe
# only the newest release, which is the wrong answer wherever a geography has
# fallen back to an older one:
#   rates |> left_join(vintages, by = c("measure" = "measure_id",
#                                       "time"    = "release_time"))
#
# Source: t_measure_years.csv in PopHIVE/county_health_rankings.
# See README (Top-Level measure_info.json) for the full contract.
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

# years_used is free text: single years, ranges, and disjoint sets ("2020 &
# 2016") all occur. Kept verbatim -- collapsing a set to a range would assert a
# continuity that isn't there -- with min/max derived from the years present.
#
# Every release gets a row, including those where years_used is blank; they
# carry NA vintage but real format_type, description and credit. Dropping them
# strips attribution from 19 measures and leaves gaps in the join.
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
    # A change across consecutive releases means values either side are not
    # comparable -- years_used can stay identical through a redefinition.
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

# A denominator change can be stated ONLY in the description prose, with
# format_type and years_used both unchanged. Diffing that prose is the one
# signal that catches it; most changes are cosmetic, so a human judges which.
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

