# =============================================================================
# update_all.R
#
# Runs the full us-rates data pipeline in order:
#   1. all_fips.R                     - refresh resources/all_fips.csv.gz
#   2. scaffold_structure.R           - create any new state/territory/county folders
#   3. code/populate_national_rates.R - write national/national_rates.csv.gz
#   4. code/populate_state_rates.R    - write states/*/state_rates.csv.gz and territories/*/{commonwealth,territory}_rates.csv.gz
#   5. code/populate_county_rates.R   - write states|territories/*/counties/*/county_rates.csv.gz
#   6. code/populate_latest_rates.R   - write states/states_latest.csv.gz and
#      states/*/counties_latest.csv.gz
#   7. code/check_geography_renaming.R - fail if a renamed/split/merged
#      geography's old and new FIPS conventions overlap
#   8. code/generate_geography_manifest.R - refresh us-rates-geographies.json
#   9. code/build_measure_vintages.R   - write tracker/measure_vintages.csv
#  10. code/build_measure_registry.R   - write tracker/measure_registry.csv
#  11. code/qa_audit.R                 - write tracker/qa_findings.csv
#
# Steps 9-11 refresh the tracker tables so they can never drift from the data
# they describe. They only WRITE to tracker/ -- no step here touches a rate
# file, measure_info.json, or us-rates-geographies.json, so a failure in this
# block leaves the published data exactly as steps 1-8 wrote it.
#
# Order matters between 9 and 10: build_measure_registry.R reads
# tracker/measure_vintages.csv for the compiler-credit columns, and running it
# first leaves all 153 citations empty. Enforced by position here rather than
# by convention.
#
# Nothing in tracker/ is part of the published data contract -- the explorer
# reads measure_info.json, the *_rates.csv.gz files, and
# us-rates-geographies.json. These tables are internal, so refreshing them
# cannot affect a downstream consumer.
#
# Must be run from the repo root (paths in every step are relative to root).
#
# Usage:
#   Rscript code/update_all.R
#   Rscript code/update_all.R --skip-scaffold   # skip step 2
#   Rscript code/update_all.R --skip-qa         # skip step 11 (the slow one:
#                                                 it rescans every rate file)
#   Rscript code/update_all.R --skip-tracker    # skip steps 9-11 entirely
# =============================================================================

if (!file.exists("all_fips.R")) {
  stop(
    "update_all.R must be run from the us-rates repo root, e.g.:\n",
    "  Rscript code/update_all.R"
  )
}

args <- commandArgs(trailingOnly = TRUE)
skip_scaffold <- "--skip-scaffold" %in% args
skip_tracker  <- "--skip-tracker"  %in% args
skip_qa       <- "--skip-qa" %in% args || skip_tracker

steps <- list(
  list(name = "FIPS reference",     script = "all_fips.R",                      run = TRUE),
  list(name = "Folder scaffolding", script = "scaffold_structure.R",            run = !skip_scaffold),
  list(name = "National rates",     script = "code/populate_national_rates.R",  run = TRUE),
  list(name = "State rates",        script = "code/populate_state_rates.R",     run = TRUE),
  list(name = "County rates",       script = "code/populate_county_rates.R",    run = TRUE),
  list(name = "Latest-value rates", script = "code/populate_latest_rates.R",    run = TRUE),
  list(name = "Geography renaming check", script = "code/check_geography_renaming.R", run = TRUE),
  list(name = "Geography manifest", script = "code/generate_geography_manifest.R", run = TRUE),
  # Tracker tables. Vintages MUST run before the registry -- see the header.
  list(name = "Measure vintages",   script = "code/build_measure_vintages.R",   run = !skip_tracker),
  list(name = "Measure registry",   script = "code/build_measure_registry.R",   run = !skip_tracker),
  list(name = "QA audit",           script = "code/qa_audit.R",                 run = !skip_qa)
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
