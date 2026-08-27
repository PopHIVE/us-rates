# =============================================================================
# qa_audit.R
#
# Scans actual observation values -- not coverage, which
# build_measure_registry.R already covers -- for data-quality problems:
# values outside a measure's declared scale, "population per X" ratios
# stored inverted, and mixed-unit series where consecutive observations for
# the same geography jump by an implausible order of magnitude.
#
# Writes tracker/qa_findings.csv, one row per finding.
#
# Usage:
#   Rscript code/qa_audit.R
# =============================================================================

library(dplyr)
library(tidyr)
library(purrr)
library(stringr)
library(vroom)
library(jsonlite)

REPO_ROOT <- "."

if (!file.exists(file.path(REPO_ROOT, "measure_info.json"))) {
  stop(
    "qa_audit.R must be run from the us-rates repo root, e.g.:\n",
    "  Rscript code/qa_audit.R"
  )
}

`%||%` <- function(a, b) if (is.null(a)) b else a

message("Loading measure_info.json...")

info <- fromJSON(file.path(REPO_ROOT, "measure_info.json"), simplifyVector = FALSE)
info[["_sources"]] <- NULL

measure_meta <- tibble(measure_id = names(info)) %>%
  mutate(
    entry = map(measure_id, ~ info[[.x]]),
    scale = map_chr(entry, ~ .x$scale %||% NA_character_),
    unit  = map_chr(entry, ~ .x$unit  %||% NA_character_)
  ) %>%
  select(-entry)

message("Scanning all rate files (national + state + territories + county)...")

national_file <- file.path(REPO_ROOT, "national", "national_rates.csv.gz")
state_files <- c(
  Sys.glob(file.path(REPO_ROOT, "states", "*", "state_rates.csv.gz")),
  Sys.glob(file.path(REPO_ROOT, "territories", "*", "commonwealth_rates.csv.gz")),
  Sys.glob(file.path(REPO_ROOT, "territories", "*", "territory_rates.csv.gz"))
)
county_files <- c(
  Sys.glob(file.path(REPO_ROOT, "states", "*", "counties", "*", "county_rates.csv.gz")),
  Sys.glob(file.path(REPO_ROOT, "territories", "*", "counties", "*", "county_rates.csv.gz"))
)

read_rates <- function(f) {
  vroom(f, show_col_types = FALSE, col_types = "cccd") %>% filter(!is.na(value))
}

all_rates <- bind_rows(
  read_rates(national_file),
  map_dfr(state_files, read_rates),
  map_dfr(county_files, read_rates)
)

message("Loaded ", nrow(all_rates), " total observations")

# -----------------------------------------------------------------------------
# Check 1: scale-bounds violations. A measure declared "0-1" or "0-100"
# should never show a value outside that range -- when it does, either the
# scale field is wrong or some rows are carrying a different unit than the
# rest of the series.
# -----------------------------------------------------------------------------

message("Checking scale bounds...")

scale_bounds <- tibble(scale = c("0-1", "0-100"), lo = c(0, 0), hi = c(1, 100))

bounds_findings <- all_rates %>%
  inner_join(measure_meta, by = c("measure" = "measure_id")) %>%
  inner_join(scale_bounds, by = "scale") %>%
  filter(value < lo | value > hi) %>%
  group_by(measure, scale) %>%
  summarise(
    n_violations = n(),
    min_value = min(value),
    max_value = max(value),
    example_geography = first(geography),
    example_time = first(as.character(time)),
    .groups = "drop"
  ) %>%
  transmute(
    measure_id = measure,
    finding_type = "scale_bounds_violation",
    severity = "high",
    detail = paste0(
      n_violations, " observation(s) outside declared scale (", scale, "): ",
      "range seen ", round(min_value, 4), " to ", round(max_value, 4),
      " -- e.g. ", example_geography, " ", example_time
    )
  )

# -----------------------------------------------------------------------------
# Check 2: "Population per X" ratios stored inverted. A true population-per-
# provider count is virtually always > 1 (hundreds to low thousands); a
# median under 1 means the pipeline is almost certainly storing
# providers-per-population instead of population-per-provider.
# -----------------------------------------------------------------------------

message("Checking population-per-X ratio direction...")

ratio_measure_ids <- measure_meta %>%
  filter(str_detect(unit, "^Population per")) %>%
  pull(measure_id)

inversion_findings <- all_rates %>%
  filter(measure %in% ratio_measure_ids) %>%
  group_by(measure) %>%
  summarise(median_value = median(value), n = n(), .groups = "drop") %>%
  filter(median_value < 1) %>%
  inner_join(measure_meta, by = c("measure" = "measure_id")) %>%
  transmute(
    measure_id = measure,
    finding_type = "ratio_likely_inverted",
    severity = "high",
    detail = paste0(
      "unit says \"", unit, "\" but median value is ", round(median_value, 6),
      " across ", n, " observations -- a true population-per-provider count ",
      "is essentially always > 1; this reads as providers-per-population instead"
    )
  )

# -----------------------------------------------------------------------------
# Check 3: mixed units within one series. Scoped to scale = None measures --
# the plan's own scoping, since the pattern was first found in
# chr_primary_care_physicians, whose scale is None. Within a single
# geography's own time series, a consecutive-observation jump of 50x or
# more almost never reflects a real year-over-year change; it means two
# different units got mixed into one measure_id.
# -----------------------------------------------------------------------------

message("Checking for mixed-unit series (this is the slow step)...")

JUMP_THRESHOLD <- 50

none_scale_ids <- measure_meta %>% filter(is.na(scale)) %>% pull(measure_id)

jump_findings <- all_rates %>%
  filter(measure %in% none_scale_ids, value > 0) %>%
  arrange(measure, geography, time) %>%
  group_by(measure, geography) %>%
  mutate(
    prev_value = lag(value),
    ratio = pmax(value, prev_value) / pmin(value, prev_value)
  ) %>%
  ungroup() %>%
  filter(!is.na(ratio), ratio >= JUMP_THRESHOLD) %>%
  group_by(measure) %>%
  summarise(
    n_jumps = n(),
    max_ratio = max(ratio),
    example_geography = first(geography),
    .groups = "drop"
  ) %>%
  transmute(
    measure_id = measure,
    finding_type = "mixed_units_within_series",
    severity = "high",
    detail = paste0(
      n_jumps, " within-geography year-over-year jump(s) of ", round(max_ratio, 0),
      "x or more (threshold ", JUMP_THRESHOLD, "x) -- e.g. geography ", example_geography,
      "; almost certainly two different units sharing one measure_id, not a real change"
    )
  )

findings <- bind_rows(bounds_findings, inversion_findings, jump_findings) %>%
  mutate(status = "auto-detected")

# -----------------------------------------------------------------------------
# Findings investigated by hand, replacing the generic "two different units"
# guess with what was actually verified. Each detail string below is written to
# tracker/qa_findings.csv as the finding's diagnosis.
# -----------------------------------------------------------------------------

flagged_root_causes <- tibble(
  measure_id = c("ahrf_md_all", "chr_mental_health_providers",
                 "chr_drinking_water_violations"),
  finding_type = "mixed_units_within_series",
  flagged_detail = c(paste0(
    "The century-pivot bug that originally caused this is fixed and reflected in the data ",
    "(Lincoln County SD 46083, the original example, now climbs smoothly: 91 in 2003 ... 395 in 2022). ",
    "Three residual >=50x jumps remain, from two causes unrelated to that fix. ",
    "(1) Roanoke County VA (51161): 790 in 2000 -> 12 in 2001. The pre-2001 AHRF editions appear to ",
    "consolidate Virginia's independent cities into their surrounding county -- Roanoke city is a ",
    "separate FIPS (51770) from 2001 on. The same pattern shows in ahrf_population for Henrico (51087), ",
    "which reads ~437,000 for 1999-2000 against a true 2000 Census count of ~262,300, though that one ",
    "falls under the 50x threshold and so is not separately flagged here. ",
    "(2) Carson City NV (32510): an isolated single-year dropout, 107 in 2001 -> 2 in 2002 -> 125 in 2003. ",
    "Both are pre-2001/single-year data-quality issues in the upstream AHRF editions, not unit mixing. ",
    "Separately, ahrf_hospitals reads 0 for Henrico 2001-2009 even in the corrected variable -- ",
    "confirmed against raw HRSA bytes as a genuine data gap, root cause still unknown."
  ), paste0(
    "NOT a unit bug -- a real CHR&R definitional change, so the values are correct as stored and ",
    "no correction is warranted. Through the 2013 release CHR&R counted psychiatrists only; from ",
    "2014 it broadened 'mental health providers' to include psychologists, clinical social workers, ",
    "counselors, marriage and family therapists, and advanced practice psychiatric nurses. Verified ",
    "in the raw Zenodo numerators: Macon County AL (01087) goes from 1 provider in the 2013 release ",
    "to 55 in 2014 against a near-flat ~22,000 population, and the national median falls from ",
    "~17,000 population per provider (2011-2012) to ~1,200 (2015+). The jump check cannot ",
    "distinguish this from unit mixing because it compares consecutive observations within a ",
    "geography, and a definitional break looks identical to a scale break at that resolution. ",
    "Consumers comparing pre-2014 to post-2014 values are comparing two different concepts -- this ",
    "is a vintage/definition labeling problem (see the completion plan's vintage field), not a ",
    "pipeline defect."
  ), paste0(
    "NOT a unit bug in the pipeline -- the stored values match the raw CHR&R archive exactly ",
    "(2016: 51.8% ones in both; 2018: 43.1% in both). CHR&R redefined the measure between the ",
    "2015 and 2016 releases: format_type goes 1 -> 5 and the description changes from ",
    "'Percentage of population potentially exposed to water exceeding a violation limit' to ",
    "'Indicator of the presence of health-related drinking water violations'. So 2013-2015 hold a ",
    "continuous proportion and 2016-2025 hold a binary 0/1 flag, which is a genuine mixed-unit ",
    "series and correctly flagged -- but the fix is labeling the break, not correcting values. ",
    "448 of the 510 jumps sit exactly on the 2015->2016 transition. Note the trap: years_used is ",
    "IDENTICAL either side of that break, so the redefinition is invisible in the vintage alone -- ",
    "format_type in tracker/measure_vintages.csv is the signal that catches it. A second trap: the ",
    "median flips from 1.0 (2016-17) to 0.0 (2018+) only because the share of counties reading 1 ",
    "crosses 50% (51.8% -> 43.1%); that is an artifact of a binary variable near the midpoint, not ",
    "a change in the data. The remaining 62 jumps are 2013->2015, within the percentage era, where ",
    "a county moving off a near-zero proportion clears 50x on a tiny base."
  ))
)

findings <- findings %>%
  left_join(flagged_root_causes, by = c("measure_id", "finding_type")) %>%
  mutate(
    status = if_else(!is.na(flagged_detail), "flagged", status),
    detail  = coalesce(flagged_detail, detail)
  ) %>%
  select(-flagged_detail) %>%
  arrange(desc(severity), measure_id)

message("\nFound ", nrow(findings), " finding(s):")
if (nrow(findings) > 0) {
  findings %>% count(finding_type) %>% print(n = Inf)
}

tracker_dir <- file.path(REPO_ROOT, "tracker")
dir.create(tracker_dir, recursive = TRUE, showWarnings = FALSE)
vroom_write(findings, file.path(tracker_dir, "qa_findings.csv"), delim = ",")

message("\nComplete. Written to tracker/qa_findings.csv")
