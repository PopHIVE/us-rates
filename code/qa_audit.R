# =============================================================================
# qa_audit.R
#
# Scans actual observation values -- not coverage, which
# build_measure_registry.R already covers -- for data-quality problems:
#
#   1. scale_bounds_violation    values outside a measure's declared scale
#   2. ratio_inversion           "population per X" ratios stored inverted
#   3. mixed_units_within_series consecutive observations for one geography
#                                jumping by an implausible order of magnitude
#   4. scale_magnitude_mismatch  a whole series sitting at the wrong order of
#                                magnitude for its declared scale
#
# Checks 1 and 4 are deliberate counterparts: 1 catches values that escape the
# declared range, 4 catches a series that stays inside it but is plainly on the
# wrong scale. A silent upstream rescale trips neither 1 nor 3, which is what
# motivated 4 -- see its block comment below.
#
# `status` is either "auto-detected" (a machine guess, awaiting triage) or
# "flagged" (verified against the source, text hand-written in
# flagged_root_causes). Flagged findings bypass check 3's gates.
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
    # `[[`, not `$` -- see the note in build_measure_registry.R. Neither of
    # these two is a prefix of another field today, so `$` happened to be
    # correct here, but only by accident: adding a "unit_label" or "scale_type"
    # would silently redirect these to it.
    scale = map_chr(entry, ~ .x[["scale"]] %||% NA_character_),
    unit  = map_chr(entry, ~ .x[["unit"]]  %||% NA_character_)
  ) %>%
  select(-entry)

# -----------------------------------------------------------------------------
# Hand-verified diagnoses. Each replaces the machine's generic detail text and
# is reported whether or not its check still fires. Declared before the checks
# because check 3 reads the id list to decide what to exempt.
# -----------------------------------------------------------------------------

flagged_root_causes <- tribble(
  ~measure_id, ~finding_type, ~flagged_detail,

  "ahrf_hospitals", "bracketed_zero_run", paste0(
    "NOT a parsing defect and NOT a coverage gap -- the pipeline reads the correct bytes, and the ",
    "zeros are in the source. AHRF retroactively REASSIGNS a county's facilities between editions, ",
    "and because the series is assembled one point per edition, a reassignment upstream lands as an ",
    "impossible cliff. Verified on Henrico County VA (51087) against raw HRSA bytes from two ",
    "editions: for the SAME data year, 1996, the 1999 edition reads 016 for Henrico and 000 for ",
    "Richmond City (51760), while the 2005 edition reads 000 for Henrico and 016 for Richmond City. ",
    "The 16 Richmond-area hospitals moved from the county to the independent city. That is why the ",
    "us-rates series reads 16, 17, then zero for 2001-2009, then 2. The 1990-vintage variable was ",
    "left alone by the revision and still reads 019 for Henrico in both editions, which is the ",
    "control that proves the reassignment rather than a layout shift. ",
    "SEPARATELY, the wider ahrf_hospitals zero rate is NOT a defect at all: 685 of 3,143 counties ",
    "(21.8%) report zero, against a published 691 of 3,142 (22.0%), the county values sum exactly ",
    "to the national total every year, and critical-access never exceeds total in 81,750 rows. ",
    "Those zeros are real rural counties. Do not 'fix' them. ",
    "The remaining work is upstream and is a design change, not a patch: AHRF must be assembled by ",
    "DATA year taking the newest edition that covers each year, rather than one point per edition. ",
    "Note the newest CSV editions carry only two years each, so the deep history exists only in the ",
    "older fixed-width editions -- the series cannot simply be rebuilt from the latest one."
  ),

  "ahrf_md_all", "mixed_units_within_series", paste0(
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
  ),

  "chr_mental_health_providers", "mixed_units_within_series", paste0(
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
  ),

  "chr_drinking_water_violations", "mixed_units_within_series", paste0(
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
    "a county moving off a near-zero proportion clears 50x on a tiny base. ",
    "This finding is exempt from check 3's magnitude gate: the pre-2016 era is a genuine near-zero ",
    "proportion, so its jumps' low end sits at ~0.005x the measure's median positive value, well ",
    "under the 0.05 floor. It is reported because it was verified, not because it passes."
  ),

  "chr_high_school_graduation", "scale_bounds_violation", paste0(
    "NOT a pipeline defect -- an upstream artifact in CHR&R's 2010 release, so the values stand as ",
    "published. Exactly 2 observations exceed the declared scale, both in the 2010 release and ",
    "both in Pennsylvania: Huntingdon County (42061) at 100.75047 and Beaver County (42007) at ",
    "100.74137 (1.0075047 and 1.0074137 before the 2026-09 move to the 0-100 standard). ",
    "Verified against the raw CHR&R ingest ",
    "(Ingest/data/county_health_rankings/standard/data_county.csv.gz), which holds those two values ",
    "to the digit -- us-rates stores what CHR&R published and introduces no rounding or rescaling. ",
    "Every other release year is capped: the maximum is exactly 100 for 2011-2020 and exactly ",
    "99.50 from 2021 on, so the overshoot is confined to the one edition. A cohort graduation rate ",
    "can exceed 100% when the graduate count includes students outside the modeled cohort ",
    "denominator (transfers in, or a denominator estimated rather than counted), which is the ",
    "general mechanism for an over-100% rate; the specific method behind the 2010 edition has not ",
    "been confirmed. Two observations out of 3,120 in that year. Do not clamp the values and do not ",
    "widen the declared scale to accommodate them -- 0-100 is the correct declaration for the measure, ",
    "and the standing rule is to label the break rather than repair the data."
  )
)

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
# chr_primary_care_physicians, whose scale is None. Within a single geography's
# own time series, a consecutive-observation jump of 50x or more CAN mean two
# different units got mixed into one measure_id.
#
# A bare ratio test does not work: it blows up on a near-zero denominator, so
# any measure reaching toward zero -- a hazard index, a sparse case count, a
# segregation index in a county with almost no minority population -- throws
# jumps of thousands of x that mean nothing. Run bare, all 15 findings were
# that. So a jump must clear two gates, and neither works alone:
#
#   Gate A (magnitude): the jumps' median low end, measured against the
#     measure's own median POSITIVE value, is >= LOW_END_FLOOR. The two verified
#     breaks sit at 0.30 (chr_mental_health_providers) and 0.087 (ahrf_md_all);
#     eleven noise findings sit at or below 0.031.
#   Gate B (breadth): >= MIN_GEOGRAPHIES distinct geographies. Unit mixing is
#     systemic; one county jumping once is an incident. This drops the
#     singletons Gate A admits because their low end IS an ordinary value
#     (jhu_measles_cases, chr_violent_crime).
#
# The gates suppress ratio noise; they do not prove a series is clean.
#
# Signed measures are excluded outright, since a ratio is undefined across zero.
# chr_school_funding_adequacy has 6,295 negative observations, and the old
# `value > 0` filter both hid every break in that half and manufactured 26
# findings from counties whose funding gap merely crossed zero.
# -----------------------------------------------------------------------------

message("Checking for mixed-unit series (this is the slow step)...")

JUMP_THRESHOLD  <- 50    # ratio between consecutive observations
LOW_END_FLOOR   <- 0.05  # Gate A: median low end / median positive value
MIN_GEOGRAPHIES <- 3     # Gate B: distinct geographies showing the jump

none_scale_ids <- measure_meta %>% filter(is.na(scale)) %>% pull(measure_id)

# Signed measures: a ratio test cannot be applied to them at all.
signed_ids <- all_rates %>%
  filter(measure %in% none_scale_ids, value < 0) %>%
  distinct(measure) %>%
  pull(measure)

if (length(signed_ids) > 0) {
  message(
    "  excluding ", length(signed_ids), " signed measure(s) -- a ratio is ",
    "undefined across zero: ", paste(signed_ids, collapse = ", ")
  )
}

jump_scope <- all_rates %>%
  filter(measure %in% none_scale_ids, !measure %in% signed_ids, value > 0)

# Reference magnitude for Gate A: the measure's own median positive value.
# Medians over all values are useless here -- several of these series are mostly
# zeros (noaa_heat_risk_score is zero in 1.26M of 2.39M observations), which
# would put the reference at 0 and admit everything.
positive_median <- jump_scope %>%
  group_by(measure) %>%
  summarise(pos_median = median(value), .groups = "drop")

jump_detail <- jump_scope %>%
  arrange(measure, geography, time) %>%
  group_by(measure, geography) %>%
  mutate(
    prev_value = lag(value),
    ratio   = pmax(value, prev_value) / pmin(value, prev_value),
    low_end = pmin(value, prev_value)
  ) %>%
  ungroup() %>%
  filter(!is.na(ratio), ratio >= JUMP_THRESHOLD) %>%
  left_join(positive_median, by = "measure") %>%
  mutate(low_end_rel = low_end / pos_median)

jump_candidates <- jump_detail %>%
  group_by(measure) %>%
  summarise(
    n_jumps = n(),
    n_geographies = n_distinct(geography),
    max_ratio = max(ratio),
    median_low_end_rel = median(low_end_rel),
    example_geography = first(geography),
    .groups = "drop"
  ) %>%
  mutate(
    passes_magnitude = median_low_end_rel >= LOW_END_FLOOR,
    passes_breadth   = n_geographies >= MIN_GEOGRAPHIES
  )

jump_flagged_ids <- flagged_root_causes %>%
  filter(finding_type == "mixed_units_within_series") %>%
  pull(measure_id)

suppressed <- jump_candidates %>%
  filter(!(passes_magnitude & passes_breadth),
         !measure %in% jump_flagged_ids)

if (nrow(suppressed) > 0) {
  message(
    "  ", nrow(suppressed), " measure(s) had >=", JUMP_THRESHOLD,
    "x jumps that did not clear the gates (ratio noise, not unit mixing): ",
    paste(suppressed$measure, collapse = ", ")
  )
}

jump_findings <- jump_candidates %>%
  filter(passes_magnitude, passes_breadth) %>%
  transmute(
    measure_id = measure,
    finding_type = "mixed_units_within_series",
    severity = "high",
    detail = paste0(
      n_jumps, " within-geography jump(s) of ", round(max_ratio, 0),
      "x or more (threshold ", JUMP_THRESHOLD, "x), across ", n_geographies,
      " geographies -- e.g. geography ", example_geography, ". These clear both ",
      "gates: the jumps' median low end is ", signif(median_low_end_rel, 3),
      "x the measure's median positive value (floor ", LOW_END_FLOOR,
      "), so they are movements out of ordinary readings rather than ratio ",
      "noise off a near-zero base, and they affect ", n_geographies,
      " geographies rather than one (floor ", MIN_GEOGRAPHIES,
      "), so they look systemic. Check whether two different units share this ",
      "measure_id, or whether the publisher redefined the measure mid-series."
    )
  )

# -----------------------------------------------------------------------------
# Check 4: scale-magnitude mismatch. The counterpart to check 1, which only
# looks OUTSIDE the declared range. A whole series that gets silently rescaled
# stays comfortably inside it and so slips past every other check here:
#
#   * check 1 (bounds) passes, because 0.03 is a legal value for a "0-100"
#     percent -- being far too small for the concept isn't a bounds violation.
#   * check 3 (mixed units) passes, because it compares consecutive
#     observations within a geography. A clean rescale moves EVERY year by the
#     same factor, so there is no year-over-year jump to catch. It only fires
#     when two units coexist in one series, never when the whole series moves.
#
# That is not hypothetical: the six ACS income-share measures (acs_INL..acs_INQ)
# were rescaled 100x upstream, from 0-100 to 0-1, and both checks above stayed
# silent while measure_info.json still declared "0-100".
#
# A percentage declared on the 0-100 scale that never once exceeds 1 across the
# entire catalog is almost certainly being stored as a 0-1 proportion. The
# converse (a "0-1" measure holding 0-100 values) needs no check here -- those
# values exceed 1 and check 1 already catches them.
#
# Threshold note: the smallest observed maximum among genuinely 0-100 measures
# is svv_exempt_medical at 1.70, so a cutoff of 1.0 clears every real measure
# today. It is deliberately tight rather than generous -- a true percentage
# whose maximum drifts below 1 across every geography and year in the repo is
# worth a look regardless of which way it turns out.
# -----------------------------------------------------------------------------

message("Checking scale magnitude against declared scale...")

MAGNITUDE_CEILING <- 1
MIN_MAGNITUDE_OBS <- 100

magnitude_findings <- all_rates %>%
  inner_join(measure_meta, by = c("measure" = "measure_id")) %>%
  filter(scale == "0-100", !is.na(value)) %>%
  group_by(measure) %>%
  summarise(
    n_obs = n(),
    max_value = max(value),
    median_value = median(value),
    .groups = "drop"
  ) %>%
  # Two gates beyond the ceiling, both about whether the series can answer the
  # question at all. A measure whose every value is 0 carries no information
  # about its scale -- 0 is 0 on both conventions -- and a handful of
  # observations cannot establish a maximum. Without these, the check reports
  # dead and near-empty series (chr_population_growth, chr_lead_poisoned_children,
  # chr_municipal_water_wi at 4 observations) as scale defects forever, which is
  # how a check trains its reader to skip it. The case this check exists for,
  # the ACS income shares, clears both easily: thousands of observations with a
  # maximum of 0.0888.
  filter(max_value > 0, n_obs >= MIN_MAGNITUDE_OBS) %>%
  filter(max_value <= MAGNITUDE_CEILING) %>%
  transmute(
    measure_id = measure,
    finding_type = "scale_magnitude_mismatch",
    severity = "high",
    detail = paste0(
      "declared scale is 0-100 but the maximum value across all ", n_obs,
      " observation(s) is ", signif(max_value, 4), " (median ",
      signif(median_value, 4), ") -- never exceeding ", MAGNITUDE_CEILING,
      ". The values look like 0-1 proportions stored against a 0-100 ",
      "declaration. Confirm which is right against the upstream source, then ",
      "correct whichever is wrong -- measure_info.json's scale, or the ",
      "pipeline block that writes the value. Do NOT assume the data is at ",
      "fault: an upstream source that rescales its own series is the more ",
      "common cause, in which case the declaration is what needs updating."
    )
  )

# -----------------------------------------------------------------------------
# Check 5: zero-runs bracketed by positive values in a stock count.
#
# A closure leaves a TRAILING run of zeros -- the county had a hospital, lost
# it, and reports zero from then on. A zero run with positive values on BOTH
# sides is a different animal: a county cannot lose every hospital and then
# regain them years later. That shape is a defect by construction, and needs no
# external reference data to judge, which is what makes it checkable here.
#
# Found by the ahrf_hospitals audit: 63 counties carry such a run, 51 of them
# three years or longer, clustered on runs beginning in 2000-2002. Henrico
# County VA (51087) is the clearest -- 16, 17, then zero for 2001-2009, then 2.
# The cause is NOT a parsing error. AHRF retroactively reassigned the Richmond
# hospitals from Henrico County to Richmond City between editions: for data
# year 1996 the 1999 edition reads 016 for Henrico and the 2005 edition reads
# 000 for Henrico and 016 for Richmond City. Since the pipeline contributes one
# point per edition, a retroactive reassignment upstream lands as an impossible
# cliff in the assembled series. See CONTRIBUTING.md.
#
# SCOPE -- stock counts only, and the list is explicit because the distinction
# is semantic and cannot be derived from any field we hold. A bracketed zero
# run is perfectly ordinary in an INCIDENCE count: a county records measles
# cases, then none for six years, then cases again. Running this check over
# jhu_measles_cases or the nhtsa_ death counts would report real epidemiology
# as a defect. It is only impossible for a persistent stock -- facilities,
# providers, population -- which is why those are named one by one.
# -----------------------------------------------------------------------------

message("Checking for bracketed zero-runs in stock counts...")

MIN_ZERO_RUN <- 3   # a 1-2 period gap is a plausible reporting lapse
MIN_RUN_GEOGRAPHIES <- 3   # one county is an incident; many is a mechanism

# Third gate, and the one that makes the finding an impossibility rather than
# merely an oddity: the geography must have held at least this many units on
# one side of the gap. A county with a single rural hospital that closes and is
# replaced years later moves 1 -> 0 -> 1 legitimately, and that is what most of
# the shape actually is -- 44 of 51 ahrf_hospitals runs are bracketed by 1.
# Losing TWO or more and later recovering is the shape that does not happen on
# its own. Measured across the AHRF counts, this gate keeps 109 runs of 608.
#
# Deliberate blind spot: it also drops the 1 -> 0 -> 1 reassignment cases, such
# as Berkeley County SC, whose hospital is credited to neighbouring Dorchester.
# Those are real, but indistinguishable here from a genuine single-facility
# lapse, so they need a source-level check rather than a shape-level one.
MIN_BRACKET_VALUE <- 2

stock_count_ids <- c(
  # AHRF facility and provider inventories
  "ahrf_hospitals", "ahrf_critical_access_hosp", "ahrf_md_all", "ahrf_pcp",
  "ahrf_psych", "ahrf_dentists",
  # Total-population stocks. These should never fire -- a county's population
  # is never zero -- which is exactly why they are worth watching.
  "ahrf_population", "chr_population", "pep_population", "acs_POP"
)
# NOT the acs_POP_* race and age subgroup counts. Those are 5-year survey
# ESTIMATES of small subpopulations, so a rural county estimating zero Native
# Hawaiian residents in one vintage and four in the next is ordinary sampling
# behaviour, not a defect. Including them produced 105 findings across six
# measures, every one of that kind.

zero_runs <- all_rates %>%
  filter(measure %in% stock_count_ids, !is.na(value)) %>%
  arrange(measure, geography, time) %>%
  group_by(measure, geography) %>%
  # Runs alternate zero / positive, so numbering the changes gives each run an
  # id. A zero run that is neither the first nor the last run in a geography is
  # therefore bracketed by positive runs on both sides.
  mutate(
    is_zero = value == 0,
    run_id  = cumsum(is_zero != lag(is_zero, default = first(is_zero)))
  ) %>%
  group_by(measure, geography, run_id) %>%
  summarise(
    is_zero    = first(is_zero),
    n_periods  = n(),
    max_value  = max(value),
    first_time = min(time),
    last_time  = max(time),
    .groups    = "drop"
  ) %>%
  group_by(measure, geography) %>%
  mutate(
    run_index = row_number(),
    n_runs    = n(),
    # Runs alternate, so for a zero run these are the positive runs on either
    # side of the gap.
    bracket   = pmax(lag(max_value), lead(max_value), na.rm = TRUE)
  ) %>%
  ungroup() %>%
  filter(
    is_zero, run_index > 1, run_index < n_runs,
    n_periods >= MIN_ZERO_RUN,
    bracket >= MIN_BRACKET_VALUE
  )

zero_run_findings <- zero_runs %>%
  group_by(measure) %>%
  arrange(desc(n_periods), .by_group = TRUE) %>%
  summarise(
    n_geographies = n_distinct(geography),
    n_runs        = n(),
    longest       = max(n_periods),
    example_geo   = first(geography),
    example_span  = paste0(first(first_time), " to ", first(last_time)),
    example_held  = first(bracket),
    .groups       = "drop"
  ) %>%
  filter(n_geographies >= MIN_RUN_GEOGRAPHIES) %>%
  transmute(
    measure_id = measure,
    finding_type = "bracketed_zero_run",
    severity = "high",
    detail = paste0(
      n_runs, " zero-run(s) of ", MIN_ZERO_RUN, "+ periods across ",
      n_geographies, " geograph", if_else(n_geographies == 1, "y", "ies"),
      " sit between positive values on both sides, in geographies that held ",
      MIN_BRACKET_VALUE, "+ units -- longest is ", longest,
      " periods (e.g. ", example_geo, ", ", example_span, ", which held ",
      example_held, "). A stock count ",
      "cannot fall to zero and recover, so this is not a closure. The usual ",
      "cause is upstream: a source that reassigns a value between geographies ",
      "in a later edition, while the series is assembled one point per ",
      "edition. Compare the SAME data year as published by two different ",
      "editions before concluding the pipeline is at fault."
    )
  )

findings <- bind_rows(
  bounds_findings, inversion_findings, jump_findings, magnitude_findings,
  zero_run_findings
) %>%
  mutate(status = "auto-detected")

# A hand-verified diagnosis replaces the machine's guess, and is reported even
# when its check no longer fires -- full_join, not left_join, so a flagged
# finding gated out of check 3 still reaches the output. severity is coalesced
# because a bypassed row has no auto-detected half to carry it.
findings <- findings %>%
  full_join(flagged_root_causes, by = c("measure_id", "finding_type")) %>%
  mutate(
    status   = if_else(!is.na(flagged_detail), "flagged", status),
    severity = coalesce(severity, "high"),
    detail   = coalesce(flagged_detail, detail)
  ) %>%
  select(-flagged_detail) %>%
  arrange(desc(severity), measure_id)

message("\nFound ", nrow(findings), " finding(s):")
if (nrow(findings) > 0) {
  findings %>% count(finding_type, status) %>% print(n = Inf)
}

tracker_dir <- file.path(REPO_ROOT, "tracker")
dir.create(tracker_dir, recursive = TRUE, showWarnings = FALSE)
vroom_write(findings, file.path(tracker_dir, "qa_findings.csv"), delim = ",")

message("\nComplete. Written to tracker/qa_findings.csv")

# -----------------------------------------------------------------------------
# Fail the build on an untriaged scale-magnitude mismatch.
#
# Findings are normally advisory -- this script exits 0 with them, because most
# want human triage and several are permanent, source-side facts. Check 4 is the
# exception, and deliberately so: a whole measure sitting an order of magnitude
# below its declared scale is not a judgement call, it is a declaration and a
# dataset that disagree, and it is exactly what a half-applied scale conversion
# looks like. Values 100x wrong that stay inside their declared range are the
# one error class no consumer can see and no other check catches.
#
# Concretely: if a us-rates refresh ever reads Ingest data that is still on 0-1
# while measure_info.json declares 0-100 -- the window between conforming the
# two repos, or an Ingest project that silently reverts -- this stops it instead
# of writing a quietly wrong dataset.
#
# Only "auto-detected" is fatal. A flagged finding has been looked at and judged,
# which is the whole point of flagging, so it must not block the pipeline. Bounds
# violations stay advisory: wapo_mmr_coverage genuinely exceeds 100 upstream, and
# that is a source defect to carry, not a reason to refuse to build.
# -----------------------------------------------------------------------------
fatal <- findings %>%
  filter(finding_type == "scale_magnitude_mismatch", status == "auto-detected")

if (nrow(fatal) > 0) {
  stop(
    "SCALE MISMATCH -- refusing to complete. ", nrow(fatal),
    " measure(s) declare a scale their values contradict: ",
    paste(head(fatal$measure_id, 10), collapse = ", "),
    if (nrow(fatal) > 10) paste0(" (and ", nrow(fatal) - 10, " more)") else "",
    ".\nThis is what a half-applied percent conversion looks like. Check that ",
    "the Ingest project feeding these measures is on the same scale ",
    "measure_info.json declares, then re-run. If the declaration is the wrong ",
    "half, fix it there. See tracker/qa_findings.csv for the detail, and ",
    "CONTRIBUTING.md for the 0-100 standard."
  )
}
