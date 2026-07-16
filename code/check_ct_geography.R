# =============================================================================
# check_ct_geography.R
#
# Fails if any (measure, time) pair is reported under both CT's legacy
# counties (09001-09015) and its planning regions (09110-09190) - summing
# county folders for that pair would double count. See README.md.
#
# Usage:
#   Rscript code/check_ct_geography.R
# =============================================================================

library(dplyr)
library(vroom)
library(stringr)

REPO_ROOT <- "."

all_fips <- vroom(
  file.path(REPO_ROOT, "resources/all_fips.csv.gz"),
  col_types = "ccc", show_col_types = FALSE
)

ct_fips <- all_fips %>%
  filter(state == "CT", nchar(geography) == 5)

# tidycensus names legacy counties "X County"; planning regions by COG name alone.
old_codes <- ct_fips %>% filter(str_detect(geography_name, " County$")) %>% pull(geography)
new_codes <- ct_fips %>% filter(!str_detect(geography_name, " County$")) %>% pull(geography)

if (length(old_codes) == 0 || length(new_codes) == 0) {
  stop(
    "Expected both legacy CT counties and planning regions in all_fips.csv.gz, ",
    "found ", length(old_codes), " county code(s) and ", length(new_codes),
    " planning region code(s). Check the tidycensus version used by all_fips.R."
  )
}

ct_folders <- ct_fips %>%
  mutate(
    convention = if_else(geography %in% old_codes, "county", "planning_region"),
    folder = file.path(
      REPO_ROOT, "states", "connecticut", "counties",
      paste0(
        geography, "_",
        geography_name %>%
          str_to_lower() %>%
          str_replace_all("[^a-z0-9]+", "_") %>%
          str_remove("_county$") %>%
          str_remove("^_|_$")
      )
    )
  )

ct_data <- ct_folders %>%
  rowwise() %>%
  reframe({
    rates_file <- file.path(folder, "county_rates.csv.gz")
    if (!file.exists(rates_file)) {
      tibble()
    } else {
      vroom(rates_file, col_types = "cDcd", show_col_types = FALSE) %>%
        mutate(convention = convention)
    }
  })

if (nrow(ct_data) == 0) {
  message("No CT county data found yet - nothing to check.")
  quit(status = 0)
}

overlap <- ct_data %>%
  distinct(measure, time, convention) %>%
  count(measure, time, name = "conventions_present") %>%
  filter(conventions_present > 1)

if (nrow(overlap) > 0) {
  offending <- ct_data %>%
    inner_join(overlap %>% select(measure, time), by = c("measure", "time")) %>%
    arrange(measure, time, geography)

  message(
    "Found ", nrow(overlap), " (measure, time) pair(s) reported under both ",
    "conventions:"
  )
  print(offending, n = 100)

  stop(
    "CT geography check failed: ", nrow(overlap), " measure/time pair(s) ",
    "present under both the legacy county and planning region conventions."
  )
}

message("CT geography check passed: no measure is double-reported across county/planning-region conventions.")
