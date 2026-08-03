# =============================================================================
# populate_county_rates.R
#
# Transforms wide-format data from Ingest sources (CHR, Census) into long-format
# county_rates.csv.gz files in the us-rates folder structure.
#
# Usage:
#   Rscript code/populate_county_rates.R
# =============================================================================

library(dplyr)
library(tidyr)
library(tibble)
library(vroom)
library(stringr)
library(arrow)

# Config
REPO_ROOT <- "."
INGEST_PATH <- "../Ingest/data"

source(file.path(REPO_ROOT, "code", "geography_helpers.R"))

year_end <- function(y) as.Date(paste0(as.integer(y), "-12-31"))

month_end <- function(d) {
  lt <- as.POSIXlt(as.Date(d))
  lt$mon <- lt$mon + 1L
  lt$mday <- 1L
  as.Date(lt) - 1L
}

mdy_to_date <- function(x) as.Date(x, format = "%m-%d-%Y")

slugify <- function(x) {
  x %>%
    str_to_lower() %>%
    str_replace_all("[^a-z0-9]+", "_") %>%
    str_remove("^_|_$")
}

# Load FIPS reference to map FIPS codes to state/county folders
all_fips <- vroom(file.path(REPO_ROOT, "resources/all_fips.csv.gz"),
                  col_types = "cccc", show_col_types = FALSE)
county_fips <- all_fips %>%
  filter(nchar(geography) == 5) %>%
  rename(fips = geography)

state_name_lookup <- all_fips %>%
  filter(nchar(geography) == 2, geography != "00") %>%
  select(state_abbr = state, state_full = geography_name)

message("Loading CHR and Census data...")

# Read CHR (wide format: geography, time, measure columns)
# guess_max = Inf: several measure columns (e.g. WI-only supplemental
# measures) are sparse enough that vroom's default row sample can guess
# them as logical instead of numeric, silently corrupting real values.
chr_wide <- vroom(
  file.path(INGEST_PATH, "county_health_rankings/standard/data_county.csv.gz"),
  show_col_types = FALSE,
  guess_max = Inf
)

# Read Census (wide format)
census_wide <- vroom(
  file.path(INGEST_PATH, "census/standard/data_county.csv.gz"),
  show_col_types = FALSE
)

# Convert wide → long format for both sources
chr_long <- chr_wide %>%
  pivot_longer(
    cols = -c(geography, time),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

census_long <- census_wide %>%
  pivot_longer(
    cols = -c(geography, time),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value))

# Retired Alaska borough/census-area FIPS codes still written to by some
# sources alongside their current successor(s) (see check_geography_renaming.R).
ALASKA_DEFUNCT_CODES <- c("02201", "02231", "02232", "02261", "02270", "02280")

# vaccine_exemptions_fattah always duplicates its value onto the retired code.
drop_alaska_defunct_duplicates <- function(df) {
  df %>% filter(!(geography %in% ALASKA_DEFUNCT_CODES))
}

# area_health_resource_file sometimes duplicates and sometimes disagrees; see
# git history for how each row below was resolved.
ahrf_alaska_overrides <- tribble(
  ~geography, ~measure,                    ~time,
  "02063",    "ahrf_critical_access_hosp", "2023-12-31",
  "02063",    "ahrf_hospitals",            "2023-12-31",
  "02063",    "ahrf_hpsa_dental",          "2025-12-31",
  "02063",    "ahrf_hpsa_mental_health",   "2025-12-31",
  "02063",    "ahrf_hpsa_prim_care",       "2025-12-31",
  "02066",    "ahrf_critical_access_hosp", "2023-12-31",
  "02066",    "ahrf_hospitals",            "2023-12-31",
  "02066",    "ahrf_hpsa_dental",          "2025-12-31",
  "02066",    "ahrf_hpsa_mental_health",   "2025-12-31",
  "02066",    "ahrf_hpsa_prim_care",       "2025-12-31",
  "02105",    "ahrf_population",           "2011-12-31",
  "02105",    "ahrf_population",           "2012-12-31",
  "02195",    "ahrf_md_all",               "2011-12-31",
  "02195",    "ahrf_md_all",               "2012-12-31",
  "02195",    "ahrf_population",           "2011-12-31",
  "02195",    "ahrf_population",           "2012-12-31",
  "02198",    "ahrf_md_all",               "2011-12-31",
  "02198",    "ahrf_md_all",               "2012-12-31",
  "02198",    "ahrf_population",           "2011-12-31",
  "02198",    "ahrf_population",           "2012-12-31",
  "02201",    "ahrf_critical_access_hosp", "2011-12-31",
  "02201",    "ahrf_critical_access_hosp", "2012-12-31",
  "02201",    "ahrf_dentists",             "2011-12-31",
  "02201",    "ahrf_dentists",             "2012-12-31",
  "02201",    "ahrf_good_air_pct",         "2012-12-31",
  "02201",    "ahrf_hospitals",            "2011-12-31",
  "02201",    "ahrf_hospitals",            "2012-12-31",
  "02201",    "ahrf_pcp",                  "2011-12-31",
  "02201",    "ahrf_pcp",                  "2012-12-31",
  "02201",    "ahrf_pm25",                 "2012-12-31",
  "02201",    "ahrf_pop_density",          "2011-12-31",
  "02201",    "ahrf_pop_density",          "2012-12-31",
  "02201",    "ahrf_psych",                "2011-12-31",
  "02201",    "ahrf_psych",                "2012-12-31",
  "02201",    "ahrf_rural_urban_code",     "2011-12-31",
  "02201",    "ahrf_rural_urban_code",     "2012-12-31",
  "02230",    "ahrf_population",           "2011-12-31",
  "02230",    "ahrf_population",           "2012-12-31",
  "02232",    "ahrf_critical_access_hosp", "2011-12-31",
  "02232",    "ahrf_critical_access_hosp", "2012-12-31",
  "02232",    "ahrf_dentists",             "2011-12-31",
  "02232",    "ahrf_dentists",             "2012-12-31",
  "02232",    "ahrf_good_air_pct",         "2012-12-31",
  "02232",    "ahrf_hospitals",            "2011-12-31",
  "02232",    "ahrf_hospitals",            "2012-12-31",
  "02232",    "ahrf_md_all",               "2011-12-31",
  "02232",    "ahrf_md_all",               "2012-12-31",
  "02232",    "ahrf_medicare_per_capita",  "2014-12-31",
  "02232",    "ahrf_pcp",                  "2011-12-31",
  "02232",    "ahrf_pcp",                  "2012-12-31",
  "02232",    "ahrf_pm25",                 "2012-12-31",
  "02232",    "ahrf_pop_density",          "2011-12-31",
  "02232",    "ahrf_pop_density",          "2012-12-31",
  "02232",    "ahrf_psych",                "2011-12-31",
  "02232",    "ahrf_psych",                "2012-12-31",
  "02232",    "ahrf_rural_urban_code",     "2011-12-31",
  "02232",    "ahrf_rural_urban_code",     "2012-12-31",
  "02261",    "ahrf_critical_access_hosp", "2025-12-31",
  "02261",    "ahrf_hospitals",            "2025-12-31",
  "02275",    "ahrf_md_all",               "2011-12-31",
  "02275",    "ahrf_md_all",               "2012-12-31",
  "02275",    "ahrf_population",           "2011-12-31",
  "02275",    "ahrf_population",           "2012-12-31",
  "02280",    "ahrf_critical_access_hosp", "2011-12-31",
  "02280",    "ahrf_critical_access_hosp", "2012-12-31",
  "02280",    "ahrf_dentists",             "2011-12-31",
  "02280",    "ahrf_dentists",             "2012-12-31",
  "02280",    "ahrf_good_air_pct",         "2012-12-31",
  "02280",    "ahrf_hospitals",            "2011-12-31",
  "02280",    "ahrf_hospitals",            "2012-12-31",
  "02280",    "ahrf_pcp",                  "2011-12-31",
  "02280",    "ahrf_pcp",                  "2012-12-31",
  "02280",    "ahrf_pm25",                 "2012-12-31",
  "02280",    "ahrf_pop_density",          "2011-12-31",
  "02280",    "ahrf_pop_density",          "2012-12-31",
  "02280",    "ahrf_psych",                "2011-12-31",
  "02280",    "ahrf_psych",                "2012-12-31",
  "02280",    "ahrf_rural_urban_code",     "2011-12-31",
  "02280",    "ahrf_rural_urban_code",     "2012-12-31"
) %>%
  mutate(time = as.Date(time))

message("Loading chronic disease and immunization data...")

# Epic Cosmos diabetes (HbA1c) and obesity (BMI) prevalence.
# Medicare rows are dropped here; CMS claims-based prevalence comes from cms_mmd.
epic_long <- read_parquet(
  file.path(
    INGEST_PATH,
    "bundle_chronic_diseases/dist",
    "epic_prevalence_by_geography_county_and_source.parquet"
  )
) %>%
  filter(
    age == "Total",
    source %in% c("Epic Cosmos: HbA1c", "Epic Cosmos: BMI"),
    !is.na(value), !is.na(geography)
  ) %>%
  mutate(
    measure = paste0(
      "epic_", str_to_lower(outcome_name), "_",
      if_else(str_detect(source, "HbA1c"), "hba1c", "bmi")
    ),
    time = year_end(year)
  ) %>%
  select(geography, time, measure, value)

# MMR kindergarten coverage (Washington Post / state health departments).
wapo_long <- read_parquet(
  file.path(
    INGEST_PATH,
    "bundle_childhood_immunizations/dist",
    "wapo_vax_counties.parquet"
  )
) %>%
  filter(!is.na(wapo_county_vax_rate), !is.na(geography)) %>%
  mutate(
    measure = "wapo_mmr_coverage",
    time    = mdy_to_date(time),
    value   = wapo_county_vax_rate
  ) %>%
  select(geography, time, measure, value)

# MMR coverage modeled by HealthMap.
healthmap_long <- vroom(
  file.path(INGEST_PATH, "mmr_healthmap/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(value), !is.na(geography)) %>%
  mutate(
    measure = "healthmap_mmr_coverage",
    time    = mdy_to_date(time)
  ) %>%
  select(geography, time, measure, value)

# Medical and non-medical MMR exemption rates.
exempt_long <- vroom(
  file.path(
    INGEST_PATH,
    "vaccine_exemptions_fattah/standard/data_county.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography)) %>%
  pivot_longer(
    cols = c(exemption_rate_mmr_med, exemption_rate_mmr_nonmed),
    names_to = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = recode(
      measure,
      exemption_rate_mmr_med    = "exempt_mmr_medical",
      exemption_rate_mmr_nonmed = "exempt_mmr_nonmedical"
    ),
    time = mdy_to_date(time)
  ) %>%
  select(geography, time, measure, value) %>%
  drop_alaska_defunct_duplicates()

# CMS Medicare chronic conditions and preventive screenings (under 65).
cms_long <- vroom(
  file.path(
    INGEST_PATH,
    "cms_mmd/standard/data_state_county_age.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(geography_level == "c", age == "Total", !is.na(geography)) %>%
  select(-geography_level, -age, -race_ethnicity, -sex) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(time = year_end(format(as.Date(time), "%Y")))

# NCHS drug overdose mortality.
nchs_long <- vroom(
  file.path(
    INGEST_PATH,
    "nchs_mortality/standard/data_county.csv.gz"
  ),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography)) %>%
  pivot_longer(
    cols      = c(n_deaths_overdose, pct_pending_invest),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(
    measure = recode(
      measure,
      n_deaths_overdose  = "nchs_overdose_deaths",
      pct_pending_invest = "nchs_overdose_pct_pending"
    ),
    time = month_end(time)
  ) %>%
  select(geography, time, measure, value)

# AHRF workforce, facility, demographic, and environmental measures.
ahrf_long <- vroom(
  file.path(INGEST_PATH, "area_health_resource_file/standard/data.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography)) %>%
  pivot_longer(
    cols      = starts_with("ahrf_"),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  select(geography, time, measure, value) %>%
  anti_join(ahrf_alaska_overrides, by = c("geography", "measure", "time"))

combined <- bind_rows(
  chr_long, census_long, epic_long,
  wapo_long, healthmap_long, exempt_long,
  cms_long, nchs_long, ahrf_long
) %>%
  # Guards against duplicate (geography, time, measure) rows from upstream
  # sources -- e.g. NCHS mortality repeats Bedford (51019) and Alleghany
  # (51005), VA, once per pre/post-2013 independent-city-merger FIPS mapping.
  distinct(geography, time, measure, .keep_all = TRUE) %>%
  arrange(geography, time, measure)

message("Combined ", nrow(combined), " rows across all sources")

# Group by county and write county_rates.csv.gz to each county folder
counties <- unique(combined$geography)
message("Processing ", length(counties), " counties...")

for (county_fips_code in counties) {
  county_data <- combined %>%
    filter(geography == county_fips_code) %>%
    select(geography, time, measure, value)

  # Find state folder name from FIPS reference
  match_row <- county_fips %>% filter(fips == county_fips_code)
  if (nrow(match_row) == 0) {
    warning("FIPS code ", county_fips_code, " not found in reference")
    next
  }

  state_full <- state_name_lookup %>%
    filter(state_abbr == match_row$state[1]) %>%
    pull(state_full)
  county_name <- match_row$geography_name[1]

  # is_territory() (state abbreviation -> territory?) comes from
  # geography_helpers.R, sourced above. Territory counties (e.g. Puerto Rico's
  # municipios) go under territories/ instead of states/.
  top_level_dir <- if (is_territory(match_row$state[1])) "territories" else "states"

  # Determine folder path (safe_name() comes from geography_helpers.R)
  county_folder <- file.path(
    REPO_ROOT, top_level_dir, safe_name(state_full), "counties",
    paste0(county_fips_code, "_", safe_name(county_name))
  )

  dir.create(county_folder, recursive = TRUE, showWarnings = FALSE)

  # Write county_rates.csv.gz
  output_file <- file.path(county_folder, "county_rates.csv.gz")
  vroom_write(county_data, output_file, delim = ",")
}

message(
  "\nComplete. County rate files written to states/*/counties/*/ and ",
  "territories/*/counties/*/ folders."
)
