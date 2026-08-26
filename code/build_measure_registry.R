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

measures <- tibble(measure_id = names(info)) %>%
  mutate(
    entry       = map(measure_id, ~ info[[.x]]),
    category    = map_chr(entry, ~ .x$category    %||% NA_character_),
    subcategory = map_chr(entry, ~ .x$subcategory  %||% NA_character_),
    measure_type = map_chr(entry, ~ .x$measure_type %||% NA_character_),
    unit        = map_chr(entry, ~ .x$unit          %||% NA_character_),
    scale       = map_chr(entry, ~ .x$scale         %||% NA_character_),
    time_resolution = map_chr(entry, ~ .x$time_resolution %||% NA_character_),
    # True data years, distinct from the release year carried in `time`. Only
    # CHR&R measures have this so far: it comes from years_used in CHR&R's own
    # t_measure_years.csv and describes each measure's most recent release
    # (vintage_release), which is what the latest-only explorer displays. Other
    # pipelines need their own vintage source before they can be filled in.
    vintage     = map_chr(entry, ~ .x$vintage         %||% NA_character_),
    vintage_min = map_int(entry, ~ as.integer(.x$vintage_min     %||% NA_integer_)),
    vintage_max = map_int(entry, ~ as.integer(.x$vintage_max     %||% NA_integer_)),
    vintage_release = map_int(entry, ~ as.integer(.x$vintage_release %||% NA_integer_)),
    vintage_lag = vintage_release - vintage_min,
    source_id   = map_chr(entry, ~ {
      s <- .x$sources
      if (is.null(s) || length(s) == 0) return(NA_character_)
      paste(map_chr(s, ~ .x$id %||% NA_character_), collapse = "; ")
    }),
    n_sources   = map_int(entry, ~ length(.x$sources %||% list())),
    compiled_via = map_chr(entry, ~ .x$compiled_via %||% NA_character_)
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
# from epic_chronic), so both get an explicit override below. nssp_ ids are
# pulled from the "nssp" folder at national/state but from a county-only cut
# in bundle_respiratory -- same underlying CDC feed, so no override is
# needed, but the file differs by geography level for this prefix.
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
# source at all); bundle_respiratory merges the raw nssp county feed with
# Epic, wastewater, Delphi, and Google Trends data and nssp_ county rows are
# extracted from that merge. If a bundle here ever looks avoidable, check its
# build.R in the Ingest repo before routing around it -- it's usually where
# the actual number gets computed, not just a repackaging.
#
# Pipeline is a separate fact from "true origin": measure_info.json's own
# per-measure `sources` field (captured above as source_id) already records
# who actually produced the statistic -- e.g. chr_adult_smoking's source_id
# is "brfss", not "chr", even though its pipeline here is
# county_health_rankings. `via` distinguishes a CHR&R/AHRF pass-through from
# a directly-ingested source; pipeline + source_id + via together answer
# "where did this row come from" without needing anything further.
#
# Every chr_ and ahrf_ measure now carries an authoritative `compiled_via`
# field directly in measure_info.json ("chr" or "ahrf") -- added as soon as
# a measure was confirmed to be pipelined through that compiler, whether or
# not a deeper origin beyond the compiler itself is also known (most chr_
# measures cite a further origin like brfss/census_pep/nchs in `sources`;
# a handful, and every current ahrf_ measure, cite only the compiler
# itself -- compiled_via still applies either way, since it records "went
# through this pipeline," not "we know what's further upstream"). `via`
# below reads that field first and only falls back to a prefix guess for
# measures that don't have it yet (anything outside these two families).
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

# nchs_pct_complete and nchs_overdose_pct_pending are data-completeness
# diagnostics (percent of death records still pending investigation /
# finalized), not health outcomes -- keep them out of the public measure
# list rather than deleting them, since the underlying pipeline data is
# still useful for judging how provisional a given month's counts are.
qa_only_ids <- c("nchs_pct_complete", "nchs_overdose_pct_pending")

# duplicate_group: which measures represent the same underlying concept, so
# several pipelines reporting the same statistic can be recognized and
# displayed together instead of looking like unrelated rows. Defaults to a
# measure's own id (no group) until a cluster is manually confirmed -- don't
# auto-group by name/prefix similarity, since measures that look alike from
# their names are often methodologically distinct. Every member below has
# been checked against actual values (not just descriptions) for at least
# one geography/year before being added here; the note records what that
# check found, since two members citing the same source can still differ
# for very different reasons (final vs. provisional vintage, direct count
# vs. statistical model, or just a lagged release).
duplicate_groups <- list(
  drug_overdose_mortality = c(
    nchs_overdose_deaths = "raw provisional monthly count (VSRR)",
    nchs_overdose_rate = "provisional annual crude rate (VSRR)",
    nchs_rate_drug_overdose = "provisional quarterly age-adjusted rate (VSRR)",
    chr_drug_overdose_deaths = "direct-count rate from NCHS Multiple Cause of Death files (final, not VSRR)",
    chr_drug_overdose_deaths_modeled = "SMALL-AREA MODELED estimate, not a direct rate -- CHR&R's own smoothed/regression estimate for counties too small to compute a stable direct rate; spans ~11 to ~33 per 100,000 nationally vs. the other four depending on year"
  ),
  population_total = c(
    chr_population = "Census PEP annual estimate, via CHR&R",
    ahrf_population = "Census PEP annual estimate, via AHRF -- bit-identical to chr_population from 2023 on (checked CT 2023-2025); diverged 2011-2022, when AHRF was carrying a less-frequently-refreshed vintage",
    acs_POP = "ACS 5-year survey-based estimate -- methodologically distinct from the PEP-based pair above (rolling 5-year survey vs. an annual administrative estimate), consistently close but never bit-identical to them (checked CT 2023-2024)"
  ),
  unemployment_rate = c(
    chr_unemployment = "BLS LAUS annual county unemployment rate, via CHR&R",
    bls_pct_unemployment = "the same BLS LAUS series pulled directly -- close but not bit-identical to chr_unemployment (checked CT 2025: 0.0376 vs. 0.04), most likely a different LAUS release vintage"
  ),
  severe_housing_problems = c(
    chr_severe_housing_problems = "HUD CHAS severe-housing-problems rate, via CHR&R",
    hud_pct_severe_housing_problems = "the same HUD CHAS definition pulled directly -- close but not bit-identical to chr_severe_housing_problems (checked CT 2022: 0.1744 vs. 0.1774), most likely a different CHAS release vintage"
  ),
  diabetes_prevalence = c(
    chr_diabetes_prevalence = "CDC PLACES small-area MODEL estimate (multilevel regression + poststratification), not a direct survey tabulation",
    brfss_diabetes = "direct BRFSS self-report survey tabulation -- consistently ~1-2 percentage points HIGHER than the PLACES model estimate every year checked (CT 2018-2022), a systematic gap, not noise"
  )
)

flatten_groups <- function(groups) {
  bind_rows(lapply(names(groups), function(g) {
    tibble(
      measure_id = names(groups[[g]]),
      duplicate_group = g,
      duplicate_note = unname(groups[[g]])
    )
  }))
}

group_lookup <- flatten_groups(duplicate_groups)

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
      TRUE ~ "Y"
    ),
    expected_county = case_when(
      measure_id %in% state_only_ids ~ "N-A",
      measure_id %in% conditional_county_ids ~ "conditional",
      TRUE ~ "Y"
    ),
    display_status = case_when(
      measure_id %in% qa_only_ids ~ "qa-only",
      TRUE ~ "primary"
    ),
    parity_flag = case_when(
      expected_national == "Y" & !actual_national ~ "expected_national_absent",
      expected_state == "Y" & !actual_state ~ "expected_state_absent",
      expected_county == "Y" & !actual_county ~ "expected_county_absent",
      TRUE ~ NA_character_
    )
  ) %>%
  left_join(group_lookup, by = "measure_id") %>%
  mutate(duplicate_group = coalesce(duplicate_group, measure_id))

# -----------------------------------------------------------------------------
# Compiler credit.
#
# Credit, not provenance. compiled_via records who compiles a measure NOW and
# can change; these columns record that a compiler supplied it, which does not
# stop being true if the measure is later converted to a direct source.
#
# Deliberately generic rather than one set of columns per compiler: compiled_via
# already names which one, so chr_/ahrf_-specific columns would be the same
# three facts written twice. Both publishers require their citation verbatim.
#
# CHR&R spans come from tracker/measure_vintages.csv, which is per release (run
# code/build_measure_vintages.R first). AHRF has no equivalent release table, so
# its span is the measure's own data-year range -- for AHRF, time IS the data
# year.
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
    # paste0() renders NA as the literal string "NA", so a missing year would
    # otherwise publish "...Roadmaps NA." -- a malformed citation that still
    # reads as populated. Guard on the years being present so an incomplete
    # citation is empty rather than wrong.
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

registry <- registry %>%
  select(
    measure_id, source_id, n_sources, pipeline, via,
    category, subcategory, measure_type, unit, scale, time_resolution,
    vintage, vintage_min, vintage_max, vintage_release, vintage_lag,
    compiler_first_year, compiler_last_year, compiler_citation,
    expected_national, expected_state, expected_county,
    actual_national, actual_state, actual_county,
    parity_flag, display_status, duplicate_group, duplicate_note,
    coverage_states,
    n_states_with_data, n_counties_with_data, n_states_with_county_data,
    n_observations, time_min, time_max
  ) %>%
  arrange(measure_id)

# n_concepts counts distinct duplicate_group values, not rows -- e.g. the
# five drug_overdose_mortality measures above count as one concept. Most
# measures don't have a confirmed group yet, so this undercounts the true
# duplication in the catalog; it will keep dropping as more clusters like
# that one are identified and added to duplicate_groups.
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
  hud_pct_severe_housing_problems = "roll-up needed; also see duplicate_groups -- its chr_ counterpart has 10x the history, don't drop that one in favor of this",
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
