# =============================================================================
# update_all.R
#
# Runs the full us-rates data pipeline in order:
#   1. all_fips.R                     - refresh resources/all_fips.csv.gz
#   2. scaffold_structure.R           - create any new state/county folders
#   3. code/populate_national_rates.R - write national/national_rates.csv.gz
#   4. code/populate_state_rates.R    - write states/*/state_rates.csv.gz
#   5. code/populate_county_rates.R   - write states/*/counties/*/county_rates.csv.gz
#   6. code/check_ct_geography.R      - fail if CT geography conventions overlap
#   7. code/generate_geography_manifest.R - refresh us-rates-geographies.json
#
# Must be run from the repo root (paths in every step are relative to root).
#
# Usage:
#   Rscript code/update_all.R
#   Rscript code/update_all.R --skip-scaffold   # skip step 2
# =============================================================================

if (!file.exists("all_fips.R")) {
  stop(
    "update_all.R must be run from the us-rates repo root, e.g.:\n",
    "  Rscript code/update_all.R"
  )
}

args <- commandArgs(trailingOnly = TRUE)
skip_scaffold <- "--skip-scaffold" %in% args

steps <- list(
  list(name = "FIPS reference",     script = "all_fips.R",                      run = TRUE),
  list(name = "Folder scaffolding", script = "scaffold_structure.R",            run = !skip_scaffold),
  list(name = "National rates",     script = "code/populate_national_rates.R",  run = TRUE),
  list(name = "State rates",        script = "code/populate_state_rates.R",     run = TRUE),
  list(name = "County rates",       script = "code/populate_county_rates.R",    run = TRUE),
  list(name = "CT geography check", script = "code/check_ct_geography.R",       run = TRUE),
  list(name = "Geography manifest", script = "code/generate_geography_manifest.R", run = TRUE)
)

for (step in steps) {
  if (!step$run) {
    message("Skipping: ", step$name, " (", step$script, ")")
    next
  }
  message("\n=== ", step$name, " (", step$script, ") ===")
  status <- system2("Rscript", step$script)
  if (status != 0) {
    stop("Failed at step: ", step$name, " (", step$script, ")")
  }
}

message("\nAll steps complete.")
