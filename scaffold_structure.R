# =============================================================================
# scaffold_structure.R
#
# Creates the full us-rates/ folder tree from the PopHIVE FIPS reference file.
# Run once from the repo root. Re-running is safe — existing folders are
# never overwritten.
#
# Usage:
#   Rscript scaffold_structure.R
# =============================================================================

library(dplyr)
library(vroom)
library(stringr)

# ---------------------------------------------------------------------------
# Config — FIPS_FILE is written by all_fips.R; run that first if it's missing
# ---------------------------------------------------------------------------

REPO_ROOT <- "."
FIPS_FILE <- "./resources/all_fips.csv.gz"

# ---------------------------------------------------------------------------
# 1. Load FIPS reference
# ---------------------------------------------------------------------------

message("Loading FIPS reference...")

all_fips <- vroom(FIPS_FILE, col_types = "ccc", show_col_types = FALSE)
# Columns: geography (FIPS string), geography_name, state

state_fips  <- all_fips |> filter(nchar(geography) == 2)
county_fips <- all_fips |> filter(nchar(geography) == 5)

message("  ", nrow(state_fips), " states | ", nrow(county_fips), " counties")

# ---------------------------------------------------------------------------
# 2. Helper — safe folder name from a place name
#    "Autauga County" -> "autauga"
#    "New York County" -> "new_york"
# ---------------------------------------------------------------------------

safe_name <- function(x) {
  x |>
    str_to_lower() |>
    str_replace_all("[^a-z0-9]+", "_") |>
    str_remove("_county$") |>   # strip trailing " county" if present
    str_remove("^_|_$")         # strip leading/trailing underscores
}

# ---------------------------------------------------------------------------
# 3. Create national/ folder
# ---------------------------------------------------------------------------

national_dir <- file.path(REPO_ROOT, "national")
dir.create(national_dir, recursive = TRUE, showWarnings = FALSE)
message("Created: national/")

# ---------------------------------------------------------------------------
# 4. Build state and county folder tree
# ---------------------------------------------------------------------------

message("Scaffolding states and counties...")

for (i in seq_len(nrow(state_fips))) {

  state_fips_code <- state_fips$geography[i]
  state_name      <- safe_name(state_fips$geography_name[i])

  counties_dir <- file.path(REPO_ROOT, "states", state_name, "counties")
  dir.create(counties_dir, recursive = TRUE, showWarnings = FALSE)

  this_state_counties <- county_fips |>
    filter(str_starts(geography, state_fips_code))

  for (j in seq_len(nrow(this_state_counties))) {

    county_fips_code <- this_state_counties$geography[j]
    county_name      <- safe_name(this_state_counties$geography_name[j])
    folder_name      <- paste0(county_fips_code, "_", county_name)

    county_dir <- file.path(counties_dir, folder_name)
    dir.create(county_dir, recursive = TRUE, showWarnings = FALSE)
  }

  message("  ", state_name, " (", state_fips_code, "): ",
          nrow(this_state_counties), " counties")
}

message("\nScaffolding complete.")
