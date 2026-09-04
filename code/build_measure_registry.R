# =============================================================================
# build_measure_registry.R
#
# Builds a measure-level registry from measure_info.json and the rate files
# currently in the repo: what each measure is, which geography levels it's
# expected to appear at, which levels it actually appears at, and basic
# coverage stats (observation counts, time range, states/counties with data).
#
# Writes tracker/measure_registry.csv, one row per measure_id.
#
# Usage:
#   Rscript code/build_measure_registry.R
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
    "build_measure_registry.R must be run from the us-rates repo root, e.g.:\n",
    "  Rscript code/build_measure_registry.R"
  )
}

`%||%` <- function(a, b) if (is.null(a)) b else a

message("Loading measure_info.json...")

info <- fromJSON(
  file.path(REPO_ROOT, "measure_info.json"),
  simplifyVector = FALSE
)
info[["_sources"]] <- NULL

# `[[` throughout, never `$`. R's `$` partial-matches on lists, so on an entry
# holding vintage_release but no vintage, `.x$vintage` silently returns the
# RELEASE year -- a wrong value, not a missing one. That is live in this schema:
# `vintage` is a prefix of vintage_min, vintage_max and vintage_release, and the
# 19 retired and state-suffixed chr_ measures carry a release with no data year.
# It surfaced as a type error only because map_chr refuses an integer; a numeric
# field would have taken the wrong number without a word. `[[` matches exactly.
measures <- tibble(measure_id = names(info)) %>%
  mutate(
    entry       = map(measure_id, ~ info[[.x]]),
    category    = map_chr(entry, ~ .x[["category"]]    %||% NA_character_),
    subcategory = map_chr(entry, ~ .x[["subcategory"]] %||% NA_character_),
    measure_type = map_chr(entry, ~ .x[["measure_type"]] %||% NA_character_),
    unit        = map_chr(entry, ~ .x[["unit"]]        %||% NA_character_),
    scale       = map_chr(entry, ~ .x[["scale"]]       %||% NA_character_),
    time_resolution = map_chr(entry, ~ .x[["time_resolution"]] %||% NA_character_),
    # True data years, distinct from the release year in `time`. CHR&R only so
    # far, and describes the most recent release; per-release truth lives in
    # tracker/measure_vintages.csv.
    vintage     = map_chr(entry, ~ .x[["vintage"]]     %||% NA_character_),
    vintage_min = map_int(entry, ~ as.integer(.x[["vintage_min"]]     %||% NA_integer_)),
    vintage_max = map_int(entry, ~ as.integer(.x[["vintage_max"]]     %||% NA_integer_)),
    vintage_release = map_int(entry, ~ as.integer(.x[["vintage_release"]] %||% NA_integer_)),
    vintage_lag = vintage_release - vintage_min,
    source_id   = map_chr(entry, ~ {
      s <- .x[["sources"]]
      if (is.null(s) || length(s) == 0) return(NA_character_)
      paste(map_chr(s, ~ .x[["id"]] %||% NA_character_), collapse = "; ")
    }),
    n_sources   = map_int(entry, ~ length(.x[["sources"]] %||% list())),
    compiled_via = map_chr(entry, ~ .x[["compiled_via"]] %||% NA_character_),
    # display_status, duplicate_group and duplicate_note are declared in
    # measure_info.json rather than in vectors here, because measure_info.json
    # is the file consumers actually read -- the County Explorer takes its
    # catalog from it and never opens this registry. Declaring them here made
    # both facts invisible downstream: three historical and two qa-only
    # measures rendered as live, and the 32 duplicate groups could not be
    # stacked at all, which is the whole point of having them. Validated
    # below rather than trusted, since measure_info.json is hand-maintained.
    # chartable = FALSE means: show no charts for this measure -- neither the
    # time series nor the county-comparison dots. Declared only where it
    # applies, so absent means chartable, the same convention duplicate_group
    # uses.
    chartable = map_lgl(entry, ~ isTRUE(.x[["chartable"]] %||% TRUE)),
    display_status  = map_chr(entry, ~ .x[["display_status"]]  %||% NA_character_),
    duplicate_group = map_chr(entry, ~ .x[["duplicate_group"]] %||% NA_character_),
    duplicate_note  = map_chr(entry, ~ .x[["duplicate_note"]]  %||% NA_character_)
  ) %>%
  select(-entry)

# -----------------------------------------------------------------------------
# Pipeline: which Ingest/data/<folder> a measure's rows come from. Transcribed
# from the INGEST_PATH file paths actually read in populate_national_rates.R /
# populate_state_rates.R / populate_county_rates.R (grep INGEST_PATH there to
# re-verify), not guessed -- most id prefixes map to one folder 1:1, but a
# prefix isn't always enough: nchs_overdose_rate is pulled from
# bundle_injury_overdose (every other nchs_ id comes from nchs_mortality), and
# epic_heat_ed_rate is pulled from epic_injury (every other epic_ id comes
# from epic_chronic), so both get an explicit override below. nssp_ ids read
# the "nssp" folder at all three levels.
#
# Every measure reads one Ingest folder at every geography level it appears at.
#
# Several prefixes (brfss, nis, svv, wapo) point at a "bundle_*" folder
# rather than a same-topic raw source folder, even though a raw source folder
# also exists (e.g. both brfss/ and bundle_chronic_diseases/ are real Ingest
# projects) -- this isn't an indirection to remove. Each bundle's build.R
# does the derivation that produces the exact number these measures need,
# which the raw source alone doesn't have: bundle_chronic_diseases aggregates
# raw brfss across sex and fine age groups into the "Total" prevalence row
# populate_national_rates.R filters on; bundle_childhood_immunizations
# reconciles the raw nis and schoolvaxview sources into one comparable
# format; bundle_injury_overdose computes rate_deaths_overdose from raw
# nchs_mortality counts plus population data (the rate isn't in the raw
# source at all). If a bundle here ever looks avoidable, check its build.R in
# the Ingest repo before routing around it -- it's usually where the actual
# number gets computed, not just a repackaging.
#
# Pipeline is a separate fact from provenance. `source_id` above is
# measure_info.json's `sources` array, "; "-joined in order, and that order is
# pull-point first: chr_adult_smoking is "chr; brfss" because CHR&R is who we
# pull it from and BRFSS produced the statistic underneath. sources[[1]]
# always equals compiled_via; a second entry appears only where the deeper
# origin is known. See CONTRIBUTING.md for why the order matters.
#
# `via` distinguishes a compiler pass-through from a direct ingest, reading
# compiled_via first and falling back to a prefix guess only for measures
# outside the chr_/ahrf_ families. pipeline + source_id + via together answer
# "where did this row come from".
# -----------------------------------------------------------------------------

prefix_pipeline <- c(
  chr        = "county_health_rankings",
  ahrf       = "area_health_resource_file",
  acs        = "census",
  census     = "census",
  bls        = "bls_laus",
  brfss      = "bundle_chronic_diseases",
  nchs       = "nchs_mortality",
  epic       = "epic_chronic",
  cms        = "cms_mmd",
  delphi     = NA, # split across delphi_doctors_claims / delphi_hospital_claims
  nssp       = "nssp",
  jhu        = "measles_jhu",
  healthmap  = "mmr_healthmap",
  noaa       = "noaa_heat_risk",
  ww         = "wastewater_measles",
  exempt     = "vaccine_exemptions_fattah",
  usda       = "usda_food_access",
  nis        = "bundle_childhood_immunizations",
  svv        = "bundle_childhood_immunizations",
  wapo       = "bundle_childhood_immunizations",
  hud        = "hud_chas",
  nhtsa      = "nhtsa_crash"
)

pipeline_overrides <- c(
  nchs_overdose_rate = "bundle_injury_overdose",
  epic_heat_ed_rate   = "epic_injury"
)

id_prefix <- function(x) str_extract(x, "^[a-z]+(?=_)")

measures <- measures %>%
  mutate(
    prefix   = id_prefix(measure_id),
    pipeline = coalesce(pipeline_overrides[measure_id], prefix_pipeline[prefix]),
    via      = coalesce(
      compiled_via,
      if_else(prefix == "chr", "chr",
      if_else(prefix == "ahrf", "ahrf",
              "direct"))
    )
  )

# -----------------------------------------------------------------------------
# Actual coverage: scan every rate file in the repo for which measures have
# at least one row (rows with NA value are never written, so presence in the
# file is sufficient), plus observation counts and time range.
# -----------------------------------------------------------------------------

message("Scanning national rates...")

national_file <- file.path(REPO_ROOT, "national", "national_rates.csv.gz")
national <- vroom(national_file, show_col_types = FALSE, col_types = "cccd") %>%
  filter(!is.na(value))

message("Scanning state-level rates (states + territories)...")

state_files <- c(
  Sys.glob(file.path(REPO_ROOT, "states", "*", "state_rates.csv.gz")),
  Sys.glob(file.path(REPO_ROOT, "territories", "*", "commonwealth_rates.csv.gz")),
  Sys.glob(file.path(REPO_ROOT, "territories", "*", "territory_rates.csv.gz"))
)

state_level <- map_dfr(state_files, function(f) {
  vroom(f, show_col_types = FALSE, col_types = "cccd") %>%
    filter(!is.na(value)) %>%
    mutate(state_fips = str_sub(geography, 1, 2))
})

message("Scanning county-level rates...")

county_files <- c(
  Sys.glob(file.path(REPO_ROOT, "states", "*", "counties", "*", "county_rates.csv.gz")),
  Sys.glob(file.path(REPO_ROOT, "territories", "*", "counties", "*", "county_rates.csv.gz"))
)

message("Found ", length(county_files), " county rate files")

county_level <- map_dfr(county_files, function(f) {
  vroom(f, show_col_types = FALSE, col_types = "cccd") %>%
    filter(!is.na(value)) %>%
    mutate(state_fips = str_sub(geography, 1, 2))
})

message("Aggregating coverage per measure...")

national_summary <- national %>%
  group_by(measure) %>%
  summarise(
    actual_national  = TRUE,
    n_obs_national   = n(),
    time_min_national = min(time),
    time_max_national = max(time),
    .groups = "drop"
  )

state_summary <- state_level %>%
  group_by(measure) %>%
  summarise(
    actual_state       = TRUE,
    n_obs_state        = n(),
    n_states_with_data = n_distinct(state_fips),
    coverage_states     = paste(sort(unique(state_fips)), collapse = ";"),
    time_min_state     = min(time),
    time_max_state     = max(time),
    .groups = "drop"
  )

county_summary <- county_level %>%
  group_by(measure) %>%
  summarise(
    actual_county        = TRUE,
    n_obs_county         = n(),
    n_counties_with_data = n_distinct(geography),
    n_states_with_county_data = n_distinct(state_fips),
    time_min_county      = min(time),
    time_max_county      = max(time),
    .groups = "drop"
  )

registry <- measures %>%
  left_join(national_summary, by = c("measure_id" = "measure")) %>%
  left_join(state_summary,    by = c("measure_id" = "measure")) %>%
  left_join(county_summary,   by = c("measure_id" = "measure")) %>%
  mutate(
    actual_national = coalesce(actual_national, FALSE),
    actual_state    = coalesce(actual_state, FALSE),
    actual_county   = coalesce(actual_county, FALSE),
    n_observations  = coalesce(n_obs_national, 0) + coalesce(n_obs_state, 0) + coalesce(n_obs_county, 0),
    time_min = pmin(time_min_national, time_min_state, time_min_county, na.rm = TRUE),
    time_max = pmax(time_max_national, time_max_state, time_max_county, na.rm = TRUE)
  )

# -----------------------------------------------------------------------------
# Expected coverage: which geography levels each measure should have data at,
# so actual-vs-expected can be checked automatically instead of by hand.
# Encoded as explicit id lists/patterns rather than left blank, so the check
# below has something to run against; revise these lists as measures are
# individually confirmed to be intentionally scoped, retired, or fixed.
# -----------------------------------------------------------------------------

state_only_ids <- c(
  # nis_* and svv_* (childhood immunization coverage) and the NCHS VSRR
  # rate series are surveyed/published at the state level only.
  registry$measure_id[str_starts(registry$measure_id, "nis_")],
  registry$measure_id[str_starts(registry$measure_id, "svv_")],
  registry$measure_id[str_starts(registry$measure_id, "nchs_rate_")],
  "jhu_measles_cases", "healthmap_mmr_coverage", "noaa_heat_risk_score"
)

state_suffixed_ids <- c(
  registry$measure_id[str_ends(registry$measure_id, "_fl")],
  registry$measure_id[str_ends(registry$measure_id, "_ny")],
  registry$measure_id[str_ends(registry$measure_id, "_wi")]
)

conditional_county_ids <- c(
  state_suffixed_ids,
  registry$measure_id[str_starts(registry$measure_id, "wapo_")]
)

# -----------------------------------------------------------------------------
# Validate what measure_info.json declares. These three fields used to be
# vectors in this file; they moved because consumers read measure_info.json and
# not this registry, so anything declared only here never reached the display.
# The file is hand-maintained, so the build checks it rather than trusting it.
#
# display_status: "primary" unless a measure must not be presented as live.
#   "qa-only" is a pipeline diagnostic rather than a health outcome
#   (nchs_pct_complete, nchs_overdose_pct_pending). "historical" is a series
#   whose upstream is gone, so it will never gain another year -- kept because
#   the observations are real, labelled because nothing in a value from 2015
#   says it is the last one. Each measure's own long_description carries why.
#
# duplicate_group: which measures represent the same concept, so several
#   pipelines reporting one statistic can be displayed together instead of
#   looking like unrelated rows. Present only where a cluster was confirmed
#   against measured values; absent means ungrouped, and defaults to the
#   measure's own id below. Grouping is not merging -- members stay separate
#   series. The screening method, its two failure modes, and the pairs
#   deliberately NOT grouped are in CONTRIBUTING.md under "Adding a
#   duplicate_group". Read that before adding one.
# -----------------------------------------------------------------------------

VALID_DISPLAY_STATUS <- c("primary", "qa-only", "historical")

# value_kind answers "is arithmetic on this number meaningful?", which is a
# different question from display_status ("should this be shown at all") and
# from coverage ("what is there to compare against"). A measure can be a live,
# primary measure with data at every level and still be uncomparable: rurality
# is a 1-9 classification, so a state "average rurality" is not a quantity.
#
#   magnitude    a rate, count, percentage, index -- compare and aggregate
#   ordinal      ordered categories as numbers (RUCC 1-9, HeatRisk 0-4);
#                rank is meaningful, the mean of two categories is not
#   categorical  unordered codes (HPSA designation 0/1/2)
#   binary       a 0/1 indicator
#
# Consumer rule: anything other than "magnitude" must not be placed on a
# cross-geography comparison chart, and must never be averaged into a state or
# national figure.
# `chartable` is declared per measure in measure_info.json, one measure at a
# time, and is NOT derived. A derived rule was tried and was wrong: "county-only
# means do not chart" caught census_ur_pct_urban_pop (3,221 counties across 52
# states) and epic_heat_ed_rate (3,110 across 50), which chart perfectly well
# and merely lack a state roll-up.

bad_status <- registry$measure_id[
  is.na(registry$display_status) |
    !registry$display_status %in% VALID_DISPLAY_STATUS
]
if (length(bad_status) > 0) {
  stop(
    "measure_info.json: ", length(bad_status),
    " measure(s) missing or with an invalid display_status (expected one of ",
    paste(VALID_DISPLAY_STATUS, collapse = ", "), "): ",
    paste(head(bad_status, 10), collapse = ", ")
  )
}

# A group of one is a declaration error, not a group -- it means a member was
# renamed or removed without its partner being revisited.
lone_groups <- registry %>%
  filter(!is.na(duplicate_group)) %>%
  count(duplicate_group) %>%
  filter(n < 2)
if (nrow(lone_groups) > 0) {
  stop(
    "measure_info.json: duplicate_group with only one member: ",
    paste(lone_groups$duplicate_group, collapse = ", ")
  )
}

# A group name that collides with a measure id would be indistinguishable from
# the ungrouped default assigned below.
collisions <- intersect(
  unique(na.omit(registry$duplicate_group)), registry$measure_id
)
if (length(collisions) > 0) {
  stop(
    "measure_info.json: duplicate_group name collides with a measure id: ",
    paste(collisions, collapse = ", ")
  )
}

# Attribution: a CHR&R measure must carry the edition it came from, in the file
# consumers read. CHR&R is CC BY 4.0 with attribution required and its requested
# citation names the edition, so a consumer composes it from
# _sources.chr.restrictions plus this measure's vintage_release. Without it the
# only year in measure_info.json is _sources.chr.date_accessed -- currently 2025
# -- and falling back on that cites the 2025 edition for measures CHR&R last
# published in 2010 or 2011. The compiler_* columns below carry the same fact,
# but they exist only on this registry, which no consumer reads.
# %in%, not ==: compiled_via is NA for every directly-ingested measure, and
# `NA == "chr"` is NA, which subsets to NA rows rather than dropping them.
missing_release <- registry$measure_id[
  registry$compiled_via %in% "chr" & is.na(registry$vintage_release)
]
if (length(missing_release) > 0) {
  stop(
    "measure_info.json: ", length(missing_release),
    " chr_ measure(s) with no vintage_release, so no edition can be cited: ",
    paste(head(missing_release, 10), collapse = ", "),
    ". The release year is in tracker/measure_vintages.csv."
  )
}

# The note records what the value check found. A group without one cannot be
# reviewed later, which is how name-based grouping creeps back in.
missing_note <- registry$measure_id[
  !is.na(registry$duplicate_group) &
    (is.na(registry$duplicate_note) | registry$duplicate_note == "")
]
if (length(missing_note) > 0) {
  stop(
    "measure_info.json: grouped measure(s) with no duplicate_note: ",
    paste(head(missing_note, 10), collapse = ", ")
  )
}


registry <- registry %>%
  mutate(
    expected_national = case_when(
      # FL/NY/WI-suffixed CHR&R "additional measures" duplicate an existing
      # unsuffixed chr_ measure that already covers every state nationally
      # (e.g. chr_adult_smoking has all 51 states; chr_adult_smoking_fl is
      # CHR&R's FL-specific supplemental cut of the same concept) -- no
      # separate national aggregate is meaningful.
      measure_id %in% state_suffixed_ids ~ "N-A",
      TRUE ~ "Y"
    ),
    expected_state = case_when(
      measure_id %in% state_suffixed_ids ~ "N-A",
      # Census OQM publishes county and national rows only -- no state table.
      measure_id == "oqm_self_response_rate" ~ "N-A",
      TRUE ~ "Y"
    ),
    expected_county = case_when(
      measure_id %in% state_only_ids ~ "N-A",
      measure_id %in% conditional_county_ids ~ "conditional",
      TRUE ~ "Y"
    ),
    parity_flag = case_when(
      expected_national == "Y" & !actual_national ~ "expected_national_absent",
      expected_state == "Y" & !actual_state ~ "expected_state_absent",
      expected_county == "Y" & !actual_county ~ "expected_county_absent",
      TRUE ~ NA_character_
    )
  ) %>%
  # An ungrouped measure is its own concept, so n_concepts below counts it once.
  # The registry therefore always carries a duplicate_group; measure_info.json
  # omits it, where absent means ungrouped.
  mutate(duplicate_group = coalesce(duplicate_group, measure_id))

# -----------------------------------------------------------------------------
# Compiler credit. Generic rather than per-compiler columns, since compiled_via
# already names which one. Both publishers require their citation verbatim.
#
# CHR&R spans come from tracker/measure_vintages.csv -- run
# code/build_measure_vintages.R FIRST or every citation is empty. AHRF has no
# release table, so its span is the measure's own data-year range.
# -----------------------------------------------------------------------------
vintages_path <- file.path(REPO_ROOT, "tracker", "measure_vintages.csv")

if (file.exists(vintages_path)) {
  chr_span <- vroom(vintages_path, show_col_types = FALSE, guess_max = Inf) %>%
    group_by(measure_id) %>%
    summarise(
      span_first = min(release_year),
      span_last  = max(release_year),
      .groups = "drop"
    )
} else {
  warning(
    "tracker/measure_vintages.csv not found -- CHR&R credit will be empty. ",
    "Run code/build_measure_vintages.R first."
  )
  chr_span <- tibble(
    measure_id = character(), span_first = integer(), span_last = integer()
  )
}

registry <- registry %>%
  left_join(chr_span, by = "measure_id") %>%
  mutate(
    compiler_first_year = case_when(
      compiled_via == "chr"  ~ span_first,
      compiled_via == "ahrf" ~ as.integer(substr(time_min, 1, 4)),
      TRUE                   ~ NA_integer_
    ),
    compiler_last_year = case_when(
      compiled_via == "chr"  ~ span_last,
      compiled_via == "ahrf" ~ as.integer(substr(time_max, 1, 4)),
      TRUE                   ~ NA_integer_
    ),
    # paste0() renders NA as "NA", which would publish "...Roadmaps NA." --
    # malformed but non-empty. Guard so an incomplete citation is empty.
    compiler_citation = case_when(
      compiled_via == "chr" & !is.na(compiler_last_year) ~ paste0(
        "University of Wisconsin Population Health Institute. ",
        "County Health Rankings & Roadmaps ", compiler_last_year, ". ",
        "www.countyhealthrankings.org."
      ),
      compiled_via == "ahrf" &
        !is.na(compiler_first_year) & !is.na(compiler_last_year) ~ paste0(
        "Area Health Resources Files (AHRF) ", compiler_first_year, "-",
        compiler_last_year, ". US Department of Health and Human Services, ",
        "Health Resources and Services Administration, Bureau of Health ",
        "Workforce, Rockville, MD."
      ),
      TRUE ~ NA_character_
    )
  ) %>%
  select(-span_first, -span_last)

# One field for consumers: FALSE if the value is not a quantity, or if there is
# no state/national value to compare a county against. comparable_reason says
# which, so the explorer can word the omission rather than silently drop a chart.
registry <- registry %>%
  select(
    measure_id, source_id, n_sources, pipeline, via,
    category, subcategory, measure_type, unit, scale, time_resolution,
    vintage, vintage_min, vintage_max, vintage_release, vintage_lag,
    compiler_first_year, compiler_last_year, compiler_citation,
    expected_national, expected_state, expected_county,
    actual_national, actual_state, actual_county,
    parity_flag, display_status, chartable, duplicate_group, duplicate_note,
    coverage_states,
    n_states_with_data, n_counties_with_data, n_states_with_county_data,
    n_observations, time_min, time_max
  ) %>%
  arrange(measure_id)

# n_concepts counts distinct duplicate_group values, not rows -- e.g. the five
# drug_overdose_mortality measures count as one concept. Most measures don't
# have a confirmed group yet, so this undercounts the true duplication in the
# catalog; it will keep dropping as more clusters are confirmed and declared in
# measure_info.json. A drop is never measures being lost.
n_concepts <- n_distinct(registry$duplicate_group)
n_origins  <- n_distinct(registry$pipeline, na.rm = TRUE)

message(
  "\nRegistry built: ", nrow(registry), " measures ",
  "(n_concepts = ", n_concepts, ", n_origins = ", n_origins, ")"
)
message(
  "Parity flags: ",
  sum(!is.na(registry$parity_flag)), " measures flagged -- see parity_flag column"
)

tracker_dir <- file.path(REPO_ROOT, "tracker")
dir.create(tracker_dir, recursive = TRUE, showWarnings = FALSE)

vroom_write(registry, file.path(tracker_dir, "measure_registry.csv"), delim = ",")

message("\nWritten to tracker/measure_registry.csv")

# -----------------------------------------------------------------------------
# Build-time parity assertion. Without this, a parity_flag is just a column
# nobody has to look at -- a newly introduced gap would sit quietly in the
# CSV next to the ones we already know about. known_gaps is every gap
# currently accepted, with a one-line reason; anything flagged that ISN'T
# in this list fails the build. When a gap gets fixed (a roll-up lands, a
# raw-file check resolves it, a measure gets reclassified to N-A), remove
# its entry -- leaving stale entries in this list would let that exact gap
# silently reappear later without ever failing again.
# -----------------------------------------------------------------------------

known_gaps <- c(
  # County-only measures awaiting a county-to-national roll-up (plan step
  # 6). The AHRF/nhtsa ones aren't a "just write the aggregation" fix --
  # several are categorical codes or need recomputing rather than summing
  # or averaging county values.
  ahrf_hpsa_dental = "roll-up needed; categorical designation code (0/1/2), not summable",
  ahrf_hpsa_mental_health = "roll-up needed; categorical designation code (0/1/2), not summable",
  ahrf_hpsa_prim_care = "roll-up needed; categorical designation code (0/1/2), not summable",
  ahrf_rural_urban_code = "roll-up needed; categorical code (1-9), not summable",
  # These are percentages, not counts -- don't assume population is the
  # right weight without checking. census_ur_pct_urban_hu's denominator is
  # housing units, not people; census_ur_pct_urban_land's is land area.
  # Only census_ur_pct_urban_pop is population-denominated, and even then
  # the roll-up should recompute from national urban/total population
  # counts, not average the county percentages.
  census_ur_pct_urban_hu = "roll-up needed; aggregation method not yet determined (denominator is housing units, not population)",
  census_ur_pct_urban_land = "roll-up needed; aggregation method not yet determined (denominator is land area, not population)",
  census_ur_pct_urban_pop = "roll-up needed; needs recomputing from national urban/total population counts, not averaging county percentages",
  nhtsa_cyclist_involved = "roll-up needed; national aggregate not yet built",
  nhtsa_fatal_crashes = "roll-up needed; national aggregate not yet built",
  nhtsa_fatalities = "roll-up needed; national aggregate not yet built",
  nhtsa_fatality_rate = "roll-up needed; a rate -- needs recomputing from national totals, not averaging county rates",
  nhtsa_pedestrian_involved = "roll-up needed; national aggregate not yet built",
  nhtsa_rural = "roll-up needed; national aggregate not yet built",
  nhtsa_single_vehicle = "roll-up needed; national aggregate not yet built",
  nhtsa_urban = "roll-up needed; national aggregate not yet built",
  epic_heat_ed_rate = "roll-up needed; national aggregate not yet built",
  hud_pct_severe_housing_problems = "roll-up needed; also see duplicate_group -- its chr_ counterpart has 10x the history, don't drop that one in favor of this",
  usda_pct_limited_access_low_income = "roll-up needed; national aggregate not yet built",
  nchs_deaths_all_cause = "roll-up needed; national aggregate not yet built",
  nchs_deaths_any_opioid = "roll-up needed; national aggregate not yet built",
  nchs_deaths_cocaine = "roll-up needed; national aggregate not yet built",
  nchs_deaths_heroin = "roll-up needed; national aggregate not yet built",
  nchs_deaths_methadone = "roll-up needed; national aggregate not yet built",

  # chr_ measures whose roll-up should wait for the vintage fix (plan step
  # 5) -- no point aggregating county data to national before we know
  # which year `time` actually means for these.
  chr_adverse_climate_events = "roll-up blocked on the chr_ vintage fix (time holds release year, not data year)",
  chr_illiteracy = "roll-up blocked on the chr_ vintage fix (time holds release year, not data year)",
  chr_living_wage = "roll-up blocked on the chr_ vintage fix (time holds release year, not data year)",
  chr_population_growth = "roll-up blocked on the chr_ vintage fix (time holds release year, not data year)",

  # Group C: extremely sparse CHR&R measures (2-60 counties) with no
  # traceable primary source beyond CHR&R itself. Diagnosing whether that's
  # by design or a mapping break needs the raw CHR&R Zenodo file, which
  # isn't downloaded locally (plan step 7).
  chr_alcohol_related_hospitalizations = "Group C sparse measure; needs the raw CHR&R file check",
  chr_child_abuse = "Group C sparse measure; needs the raw CHR&R file check",
  chr_did_not_get_needed_health_care = "Group C sparse measure; needs the raw CHR&R file check",
  chr_drug_arrests = "Group C sparse measure; needs the raw CHR&R file check",
  chr_hate_crimes = "Group C sparse measure; needs the raw CHR&R file check",
  chr_lead_poisoned_children = "Group C sparse measure; needs the raw CHR&R file check",
  chr_local_health_department_staffing = "Group C sparse measure; needs the raw CHR&R file check",
  chr_w_2_enrollment = "Group C sparse measure; needs the raw CHR&R file check",

  # QA-completeness field. Only populate_state_rates.R currently extracts
  # pct_complete at all -- not yet confirmed whether that's a pipeline gap
  # or NCHS just doesn't publish it below the state level.
  nchs_pct_complete = "not yet investigated -- may be a pipeline gap, may be state-only by design",

  # Direct household survey, not modeled to county level the way
  # chr_diabetes_prevalence's PLACES estimate is. Plausibly a real N-A
  # rather than a gap, but not reclassified without confirming BRFSS
  # publishes no county-level product at all.
  brfss_diabetes = "likely a real N-A (direct survey, no county product) -- not yet reclassified",
  brfss_obesity = "likely a real N-A (direct survey, no county product) -- not yet reclassified",

  # County-only by the source's own design (Washington Post's own county
  # compilation) -- whether a state/national aggregate is even meaningful
  # is an open question, not a known "yes, build it" roll-up.
  wapo_met_herd_immunity_postpandemic = "county-only by source design; national aggregate not yet decided",
  wapo_met_herd_immunity_prepandemic = "county-only by source design; national aggregate not yet decided",
  wapo_mmr_coverage = "county-only by source design; national aggregate not yet decided",

  # Has national + county data but skips state -- cause not yet diagnosed.
  ww_measles_detection_rate = "missing at state only; cause not yet diagnosed"
)

flagged_ids <- registry$measure_id[!is.na(registry$parity_flag)]
unexpected_gaps <- setdiff(flagged_ids, names(known_gaps))
resolved_gaps <- setdiff(names(known_gaps), flagged_ids)

if (length(resolved_gaps) > 0) {
  message(
    "\nNOTE: ", length(resolved_gaps), " measure(s) in known_gaps no longer have a ",
    "parity_flag -- remove from known_gaps in this script:\n  ",
    paste(resolved_gaps, collapse = "\n  ")
  )
}

if (length(unexpected_gaps) > 0) {
  stop(
    "Parity check failed: ", length(unexpected_gaps), " measure(s) have a coverage gap ",
    "not in known_gaps. If this is a real, accepted gap, add it to known_gaps in ",
    "build_measure_registry.R with a reason; otherwise this is a regression to fix:\n  ",
    paste(unexpected_gaps, collapse = "\n  ")
  )
}

message("\nParity check passed: every flagged measure is a known, tracked gap.")
message("Complete.")
