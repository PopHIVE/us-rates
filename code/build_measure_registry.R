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
    # True data years, distinct from the release year in `time`. CHR&R only so
    # far, and describes the most recent release; per-release truth lives in
    # tracker/measure_vintages.csv.
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

# nchs_pct_complete and nchs_overdose_pct_pending are data-completeness
# diagnostics (percent of death records still pending investigation /
# finalized), not health outcomes -- keep them out of the public measure
# list rather than deleting them, since the underlying pipeline data is
# still useful for judging how provisional a given month's counts are.
qa_only_ids <- c("nchs_pct_complete", "nchs_overdose_pct_pending")

# Measures whose upstream source is gone, so the series is closed and will
# never gain another year. They are kept -- the observations are real and
# historically useful -- but must not be presented next to live measures as
# though they were current, which is a correctness problem rather than a
# staleness one: nothing in a value from 2015 says it is the last one.
#
# The three Dartmouth Atlas measures below reach us through CHR&R, so two
# separate things ended and both are load-bearing. CHR&R stopped publishing
# them after its 2018 release (2010 for chr_hospice_use, which appeared once),
# and the Dartmouth Atlas itself has since been discontinued: "we will no
# longer update Dartmouth Atlas tools or calculate new annual rates", with
# historical rates ending at 2019 (dartmouthatlas.org). So there is no upstream
# to migrate to and no prospect of a refresh -- the right treatment is a label,
# not a deletion, and not a ticket to re-source them.
historical_ids <- c(
  "chr_diabetes_monitoring",
  "chr_health_care_costs",
  "chr_hospice_use"
)

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
#
# The screening method, and the two traps in it, are in CONTRIBUTING.md under
# "Adding a duplicate_group". Read that before extending this list.
#
# Pairs deliberately NOT grouped, so the next person does not re-litigate them:
#   * chr_dentists / ahrf_dentists and chr_primary_care_physicians / ahrf_pcp --
#     r = -0.18 and -0.16. One is a population-per-provider ratio, the other a
#     provider count. Inverses of each other, not the same measure.
#   * chr_unemployment / acs_UMP -- r = 0.638. A rolling 5-year survey estimate
#     against a point-in-time administrative rate; too weak to call one concept.
#   * chr_income_inequality / acs_GNI -- ratio 0.100. A percentile ratio against
#     a Gini index: different statistics. acs_OWS is the right counterpart.
#   * acs_PCT_P / pep_pct_aian (ratio 3.9) and acs_PCT_P1 / pep_pct_nhpi (ratio
#     1.4) -- the ACS shares are non-Hispanic-alone and the PEP shares are not,
#     so for these two groups the ACS member counts a different population. The
#     other four race groups match at ratio 1.0-1.1 and are grouped.
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
    acs_POP = "ACS 5-year survey-based estimate -- methodologically distinct from the PEP-based pair above (rolling 5-year survey vs. an annual administrative estimate), consistently close but never bit-identical to them (checked CT 2023-2024)",
    pep_population = "the same Census PEP estimate pulled directly rather than through a compiler -- r = 0.9998 and ratio 1.002 against acs_POP, chr_population and ahrf_population across ~3,100 counties in 2023. This is the member with honest coverage for Connecticut's 9 planning regions, Alaska's Chugach and Copper River, and Puerto Rico's municipios, which CHR&R does not report"
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
  ),

  # --- Air quality -----------------------------------------------------------
  particulate_matter = c(
    chr_air_pollution_particulate_matter = "CDC EPHT modeled PM2.5 surface, via CHR&R",
    ahrf_pm25 = "the SAME CDC EPHT surface via AHRF, and the only bit-identical pair in this whole list: r = 1.0000 and every one of 3,115 county values matches exactly in 2023. Two compilers republishing one upstream product, so these carry no independent information about each other"
  ),

  # --- Demographic composition -----------------------------------------------
  # Three pipelines report the same shares. chr_ and pep_ both rest on Census
  # PEP, acs_ on the 5-year survey, so the ACS member is the methodologically
  # distinct one in each group even where the values agree closely.
  share_hispanic = c(
    chr_hispanic = "Census PEP share, via CHR&R",
    acs_PCT_H = "ACS 5-year survey share -- r = 0.997, ratio 1.003 against chr_hispanic (3,142 counties, 2019)",
    pep_pct_hispanic = "the same PEP share pulled directly -- r = 0.996, ratio 1.07 against chr_hispanic (3,133 counties, 2023)"
  ),
  share_non_hispanic_black = c(
    chr_non_hispanic_black = "Census PEP share, via CHR&R",
    acs_PCT_B = "ACS 5-year survey share -- r = 0.998, ratio 1.014 against chr_non_hispanic_black (3,142 counties, 2019)",
    pep_pct_nh_black = "the same PEP share pulled directly -- r = 0.999, ratio 1.018 against chr_non_hispanic_black (3,133 counties, 2023)"
  ),
  share_non_hispanic_white = c(
    chr_non_hispanic_white = "Census PEP share, via CHR&R",
    acs_PCT_W = "ACS 5-year survey share -- r = 0.998, ratio 1.001 against chr_non_hispanic_white (3,142 counties, 2019)",
    pep_pct_nh_white = "the same PEP share pulled directly -- r = 0.998, ratio 0.993 against chr_non_hispanic_white (3,133 counties, 2023)"
  ),
  share_asian = c(
    chr_asian = "Census PEP share, via CHR&R",
    acs_PCT_A = "ACS 5-year survey share -- r = 0.976, ratio 1.10 against chr_asian (3,142 counties, 2019); the loosest fit of the four race groups grouped here",
    pep_pct_asian = "the same PEP share pulled directly -- r = 0.998, ratio 1.05 against chr_asian (3,133 counties, 2023)"
  ),
  # No ACS member: see the header note -- acs_PCT_P is non-Hispanic-alone and
  # runs ~4x smaller, which is a different population rather than a vintage gap.
  share_american_indian_alaska_native = c(
    chr_american_indian_or_alaska_native = "Census PEP share, via CHR&R",
    pep_pct_aian = "the same PEP share pulled directly -- r = 0.999, ratio 1.038 (3,133 counties, 2023)"
  ),
  share_native_hawaiian_pacific_islander = c(
    chr_native_hawaiian_or_other_pacific_islander = "Census PEP share, via CHR&R",
    pep_pct_nhpi = "the same PEP share pulled directly -- r = 0.990, ratio 1.043 (3,133 counties, 2023)"
  ),
  share_age_65_and_older = c(
    chr_65_and_older = "Census PEP share, via CHR&R",
    acs_PCT_S = "ACS 5-year survey share -- r = 0.978, ratio 1.000 against chr_65_and_older (3,142 counties, 2019)",
    pep_pct_65_older = "the same PEP share pulled directly -- r = 0.987, ratio 1.043 against chr_65_and_older (3,133 counties, 2023)"
  ),
  # No ACS member by construction: ACS splits this age range into acs_PCT_I
  # (0-4) and acs_PCT_J (5-17), so neither alone is comparable.
  share_under_18 = c(
    chr_below_18_years_of_age = "Census PEP share, via CHR&R",
    pep_pct_under_18 = "the same PEP share pulled directly -- r = 0.981, ratio 0.988 (3,133 counties, 2023)"
  ),
  # Grouped on ratio, not correlation: female share is ~50% in every county, so
  # there is almost no variance for a correlation to detect (r = 0.90-0.95).
  # The ratio is 1.000 between all three, which is the decisive evidence here.
  share_female = c(
    chr_female = "Census PEP share, via CHR&R",
    acs_PCT_F = "ACS 5-year survey share -- ratio 1.000 against chr_female (3,142 counties, 2019)",
    pep_pct_female = "the same PEP share pulled directly -- ratio 1.000 against chr_female (3,133 counties, 2023)"
  ),

  # --- Economic --------------------------------------------------------------
  median_household_income = c(
    chr_median_household_income = "Census SAIPE estimate, via CHR&R",
    saipe_median_household_income = "the same SAIPE estimate pulled directly -- r = 0.955, ratio 1.022 against chr_median_household_income (3,142 counties, 2024)",
    acs_INC = "ACS 5-year survey median -- r = 0.972, ratio 0.956 against chr_median_household_income (3,141 counties, 2019); a survey median rather than SAIPE's model-based estimate"
  ),
  children_in_poverty = c(
    chr_children_in_poverty = "Census SAIPE child poverty rate, via CHR&R",
    saipe_pct_children_poverty = "the same SAIPE rate pulled directly -- r = 0.936, ratio 0.940 (3,134 counties, 2024); the gap is release vintage, since CHR&R lags SAIPE by ~2 years"
  ),
  income_inequality = c(
    chr_income_inequality = "ratio of household income at the 80th percentile to the 20th, via CHR&R",
    acs_OWS = "ACS income QUINTILE SHARE ratio (S80/S20) -- r = 0.972 but ratio 3.18 (52 states, 2019). NOT interchangeable: a ratio of two percentile incomes and a ratio of two quintile income shares are different statistics that happen to move together. Grouped so they are not read as independent findings; see also acs_GNI, a Gini index, which is deliberately NOT in this group"
  ),
  severe_housing_cost_burden = c(
    chr_severe_housing_cost_burden = "ACS-derived rate of households spending 50%+ of income on housing, via CHR&R",
    acs_HBS = "the same ACS concept pulled directly -- r = 0.899, ratio 0.907 (3,141 counties, 2019)"
  ),
  homeownership = c(
    chr_homeownership = "ACS-derived owner-occupied housing rate, via CHR&R",
    acs_HUO = "the same ACS concept pulled directly -- r = 0.964, ratio 0.997 (3,142 counties, 2019)"
  ),

  # --- Insurance coverage ----------------------------------------------------
  # Three separate groups, not one: all-ages, adults and children are distinct
  # populations, and chr_uninsured vs chr_uninsured_adults differ by ratio 1.17.
  uninsured_all_ages = c(
    chr_uninsured = "Census SAHIE under-65 uninsured rate, via CHR&R",
    sahie_pct_uninsured = "the same SAHIE rate pulled directly -- r = 0.932, ratio 0.947 (3,134 counties, 2024)"
  ),
  uninsured_adults = c(
    chr_uninsured_adults = "Census SAHIE adult uninsured rate, via CHR&R",
    sahie_pct_uninsured_adults = "the same SAHIE rate pulled directly -- r = 0.938, ratio 0.922 (3,134 counties, 2024)"
  ),
  uninsured_children = c(
    chr_uninsured_children = "Census SAHIE child uninsured rate, via CHR&R",
    sahie_pct_uninsured_children = "the same SAHIE rate pulled directly -- r = 0.863, ratio 1.074 (3,134 counties, 2024); the weakest of the three, as expected on the smallest denominator"
  ),

  # --- Education and connectivity --------------------------------------------
  high_school_completion = c(
    chr_high_school_completion = "ACS-derived share of adults 25+ with at least a high school diploma, via CHR&R",
    acs_EDB = "the same ACS concept pulled directly -- r = 0.963, ratio 0.990 (3,141 counties, 2021)"
  ),
  broadband_access = c(
    chr_broadband_access = "ACS-derived household broadband subscription rate, via CHR&R",
    acs_BDB = "the same ACS concept pulled directly -- r = 0.936, ratio 1.063 (3,141 counties, 2021)"
  ),

  # --- Mortality: CHR&R county series vs. NCHS state series -------------------
  # These pairs have NO county overlap -- the nchs_ members are state-level
  # only -- so all four were verified across 204 state/territory rows for 2023
  # rather than across counties.
  homicide_mortality = c(
    chr_homicides = "CHR&R county homicide rate, multi-year smoothed",
    nchs_rate_homicide = "NCHS age-adjusted state homicide rate -- r = 0.929, ratio 1.224 (204 state rows, 2023); age adjustment plus CHR&R's smoothing accounts for the level gap"
  ),
  suicide_mortality = c(
    chr_suicides = "CHR&R county suicide rate, multi-year smoothed",
    nchs_rate_suicide = "NCHS age-adjusted state suicide rate -- r = 0.919, ratio 1.019 (204 state rows, 2023)"
  ),
  firearm_mortality = c(
    chr_firearm_fatalities = "CHR&R county firearm fatality rate, multi-year smoothed",
    nchs_rate_firearm_related_injury = "NCHS age-adjusted state firearm injury death rate -- r = 0.944, ratio 1.102 (204 state rows, 2023)"
  ),
  unintentional_injury_mortality = c(
    chr_injury_deaths = "CHR&R county injury death rate, multi-year smoothed",
    nchs_rate_unintentional_injuries = "NCHS age-adjusted state unintentional injury death rate -- r = 0.817, ratio 0.800 (204 state rows, 2023); the loosest pair here, since CHR&R's injury deaths include intentional causes that the NCHS unintentional series excludes"
  ),
  motor_vehicle_crash_mortality = c(
    chr_motor_vehicle_crash_deaths = "CHR&R county motor vehicle crash death rate, multi-year smoothed",
    nhtsa_fatality_rate = "NHTSA FARS annual fatality rate per 100,000 -- r = 0.916, ratio 0.663 at STATE level (51 states, 2010). At county level the same pair reaches only r = 0.212, because CHR&R's multi-year smoothing and FARS's single-year counts diverge sharply on small county denominators; judge this pair at state level"
  ),

  # --- Other -----------------------------------------------------------------
  adult_obesity = c(
    chr_adult_obesity = "CDC PLACES small-area model estimate, via CHR&R, stored 0-1",
    brfss_obesity = "direct BRFSS survey tabulation, stored 0-100 -- r = 0.926 (52 states, 2018), ratio 107.8, which is the 100x scale difference plus the same systematic model-vs-survey gap seen in diabetes_prevalence. The scale mismatch between these two members is a live example of the percent-standard problem"
  ),
  urban_rural_composition = c(
    chr_rural = "CHR&R share of population living in a rural area, from the decennial Census",
    census_ur_pct_urban_pop = "Census urban share of population pulled directly -- r = -1.000 EXACTLY against chr_rural across 3,135 counties (2024), because the two are algebraic complements of one another. They carry the same information stated in opposite directions and must never be read as two independent findings. census_ur_pct_urban_hu is the housing-unit analogue and is deliberately left out, since its denominator is housing units rather than people"
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
      # Census OQM publishes county and national rows only -- no state table.
      measure_id == "oqm_self_response_rate" ~ "N-A",
      TRUE ~ "Y"
    ),
    expected_county = case_when(
      measure_id %in% state_only_ids ~ "N-A",
      measure_id %in% conditional_county_ids ~ "conditional",
      TRUE ~ "Y"
    ),
    display_status = case_when(
      measure_id %in% qa_only_ids ~ "qa-only",
      measure_id %in% historical_ids ~ "historical",
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
