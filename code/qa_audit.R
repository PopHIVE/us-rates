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
  arrange(desc(severity), measure_id)

message("\nFound ", nrow(findings), " finding(s):")
if (nrow(findings) > 0) {
  findings %>% count(finding_type) %>% print(n = Inf)
}

tracker_dir <- file.path(REPO_ROOT, "tracker")
dir.create(tracker_dir, recursive = TRUE, showWarnings = FALSE)
vroom_write(findings, file.path(tracker_dir, "qa_findings.csv"), delim = ",")

message("\nComplete. Written to tracker/qa_findings.csv")
