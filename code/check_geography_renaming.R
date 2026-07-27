# =============================================================================
# check_geography_renaming.R
#
# Fails if any (measure, time) pair is reported under more than one
# generation of a geography that's been renamed, split, or merged --
# summing county folders across generations double- (or triple-) counts.
# Each event lists its generations oldest-first; codes within the same
# generation are siblings (e.g. a 1-to-many split) and may legitimately
# share a measure/time, but no two different generations should. Covers:
#   - Connecticut: legacy counties (09001-09015) vs. planning regions
#     (09110-09190), effective 2022.
#   - Alaska: 5 historical borough/census-area renames, splits, and mergers,
#     including one 3-generation chain (Skagway/Hoonah-Angoon).
# See README.md.
#
# Usage:
#   Rscript code/check_geography_renaming.R
# =============================================================================

library(dplyr)
library(tidyr)
library(vroom)
library(stringr)

REPO_ROOT <- "."
source(file.path(REPO_ROOT, "code", "geography_helpers.R"))

all_fips <- vroom(
  file.path(REPO_ROOT, "resources/all_fips.csv.gz"),
  col_types = "ccc", show_col_types = FALSE
)

state_folder_names <- all_fips %>%
  filter(nchar(geography) == 2, geography != "00") %>%
  select(state, state_folder_name = geography_name)

# tidycensus names legacy CT counties "X County"; planning regions by COG name alone.
ct_fips <- all_fips %>% filter(state == "CT", nchar(geography) == 5)
ct_old <- ct_fips %>% filter(str_detect(geography_name, " County$")) %>% pull(geography)
ct_new <- ct_fips %>% filter(!str_detect(geography_name, " County$")) %>% pull(geography)

if (length(ct_old) == 0 || length(ct_new) == 0) {
  stop(
    "Expected both legacy CT counties and planning regions in all_fips.csv.gz, ",
    "found ", length(ct_old), " county code(s) and ", length(ct_new),
    " planning region code(s). Check the tidycensus version used by all_fips.R."
  )
}

renaming_events <- list(
  list(state = "CT", label = "legacy counties vs. planning regions (2022)",
       generations = list(ct_old, ct_new)),
  list(state = "AK", label = "Prince of Wales-Outer Ketchikan -> Prince of Wales-Hyder (2008)",
       generations = list("02201", "02198")),
  list(state = "AK", label = "Skagway-Yakutat-Angoon (pre-1992) -> Skagway-Hoonah-Angoon (1992) -> Skagway, Hoonah-Angoon (2007)",
       generations = list("02231", "02232", c("02230", "02105"))),
  list(state = "AK", label = "Valdez-Cordova -> Chugach, Copper River (2019)",
       generations = list("02261", c("02063", "02066"))),
  list(state = "AK", label = "Wade Hampton -> Kusilvak (renamed 2015)",
       generations = list("02270", "02158")),
  list(state = "AK", label = "Wrangell-Petersburg -> Wrangell, Petersburg (2008)",
       generations = list("02280", c("02195", "02275")))
)

load_county_data <- function(state_abbr, fips_codes) {
  state_folder <- state_folder_names %>%
    filter(state == state_abbr) %>%
    pull(state_folder_name)

  all_fips %>%
    filter(geography %in% fips_codes) %>%
    rowwise() %>%
    reframe({
      folder <- file.path(
        REPO_ROOT, "states", safe_name(state_folder), "counties",
        paste0(geography, "_", safe_name(geography_name))
      )
      rates_file <- file.path(folder, "county_rates.csv.gz")
      if (!file.exists(rates_file)) {
        tibble()
      } else {
        vroom(rates_file, col_types = "cDcd", show_col_types = FALSE) %>%
          mutate(fips = geography)
      }
    })
}

any_failures <- FALSE

for (event in renaming_events) {
  all_codes <- unlist(event$generations)
  data <- load_county_data(event$state, all_codes)

  if (nrow(data) == 0) {
    message(event$state, ": ", event$label, " - no data found yet, skipping.")
    next
  }

  generation_of <- setNames(
    rep(seq_along(event$generations), lengths(event$generations)),
    all_codes
  )
  data <- data %>% mutate(generation = generation_of[fips])

  overlap <- data %>%
    distinct(measure, time, generation) %>%
    count(measure, time, name = "generations_present") %>%
    filter(generations_present > 1)

  if (nrow(overlap) > 0) {
    offending <- data %>%
      inner_join(overlap %>% select(measure, time), by = c("measure", "time")) %>%
      arrange(measure, time, generation, fips)

    message(
      "\n", event$state, ": ", event$label, " - found ", nrow(overlap),
      " (measure, time) pair(s) reported under more than one generation:"
    )
    print(offending, n = 100)
    any_failures <- TRUE
  } else {
    message(event$state, ": ", event$label, " - OK, no overlap.")
  }
}

if (any_failures) {
  stop("Geography renaming check failed: see overlaps listed above.")
}

message("\nGeography renaming check passed: no measure is double-reported across any renamed/split/merged geography.")
