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

# The events come from GEOGRAPHY_LINEAGE in geography_helpers.R, which is also
# what generate_geography_manifest.R publishes as activeFrom / activeThrough /
# supersededBy / supersedes. Deriving both from one table is the point: a
# lineage this check knows about but the manifest does not would ship retired
# geographies to consumers as though they were current, and the reverse would
# let a real double-count through. Do not re-list the events here.
renaming_events <- lapply(GEOGRAPHY_LINEAGE, function(event) {
  list(
    state = event$state,
    label = event$label,
    generations = lapply(event$generations, function(codes) {
      unlist(lapply(codes, function(c) {
        if (identical(c, "CT_LEGACY_COUNTIES")) ct_old
        else if (identical(c, "CT_PLANNING_REGIONS")) ct_new
        else c
      }), use.names = FALSE)
    })
  )
})

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
