# =============================================================================
# natality_helpers.R
#
# Percent-of-births measures built from CDC WONDER natality detail counts
# (Ingest: cdc_wonder_natality/standard/data_*_detail.csv.gz). Sourced by the
# populate_*_rates.R scripts.
#
# Each percent is numerator births / denominator births x 100, where both are
# sums of named detail categories. Denominators list the known categories
# explicitly, so "Unknown" is never counted. A percent is dropped (not
# estimated) when any numerator or denominator cell is suppressed (1-9 births)
# or missing for that geography and year.
# =============================================================================

natality_cells <- function(dimension, categories) {
  data.frame(dimension = dimension, category = categories, stringsAsFactors = FALSE)
}

NATALITY_PERCENT_SPECS <- list(
  natality_pct_low_birth_weight = list(
    num = natality_cells("birth_weight", c(
      "499 grams or less", "500 - 999 grams", "1000 - 1499 grams",
      "1500 - 1999 grams", "2000 - 2499 grams"
    )),
    den = natality_cells("birth_weight", c(
      "499 grams or less", "500 - 999 grams", "1000 - 1499 grams",
      "1500 - 1999 grams", "2000 - 2499 grams", "2500 - 2999 grams",
      "3000 - 3499 grams", "3500 - 3999 grams", "4000 - 4499 grams",
      "4500 - 4999 grams", "5000 - 8165 grams"
    ))
  ),
  natality_pct_preterm = list(
    num = natality_cells("gestational_age", c(
      "Under 20 weeks", "20 - 27 weeks", "28 - 31 weeks",
      "32 - 35 weeks", "36 weeks"
    )),
    den = natality_cells("gestational_age", c(
      "Under 20 weeks", "20 - 27 weeks", "28 - 31 weeks", "32 - 35 weeks",
      "36 weeks", "37 - 39 weeks", "40 weeks", "41 weeks", "42 weeks or more"
    ))
  ),
  natality_pct_educ_less_hs = list(
    num = natality_cells("mothers_education", c(
      "8th grade or less", "9th through 12th grade with no diploma"
    )),
    den = natality_cells("mothers_education", c(
      "8th grade or less", "9th through 12th grade with no diploma",
      "High school graduate or GED completed",
      "Some college credit, but not a degree", "Associate degree (AA, AS)",
      "Bachelor's degree (BA, AB, BS)",
      "Master's degree (MA, MS, MEng, MEd, MSW, MBA)",
      "Doctorate (PhD, EdD) or Professional Degree (MD, DDS, DVM, LLB, JD)"
    ))
  ),
  natality_pct_educ_hs = list(
    num = natality_cells("mothers_education", "High school graduate or GED completed"),
    den = natality_cells("mothers_education", c(
      "8th grade or less", "9th through 12th grade with no diploma",
      "High school graduate or GED completed",
      "Some college credit, but not a degree", "Associate degree (AA, AS)",
      "Bachelor's degree (BA, AB, BS)",
      "Master's degree (MA, MS, MEng, MEd, MSW, MBA)",
      "Doctorate (PhD, EdD) or Professional Degree (MD, DDS, DVM, LLB, JD)"
    ))
  ),
  natality_pct_educ_higher_ed = list(
    num = natality_cells("mothers_education", c(
      "Some college credit, but not a degree", "Associate degree (AA, AS)",
      "Bachelor's degree (BA, AB, BS)",
      "Master's degree (MA, MS, MEng, MEd, MSW, MBA)",
      "Doctorate (PhD, EdD) or Professional Degree (MD, DDS, DVM, LLB, JD)"
    )),
    den = natality_cells("mothers_education", c(
      "8th grade or less", "9th through 12th grade with no diploma",
      "High school graduate or GED completed",
      "Some college credit, but not a degree", "Associate degree (AA, AS)",
      "Bachelor's degree (BA, AB, BS)",
      "Master's degree (MA, MS, MEng, MEd, MSW, MBA)",
      "Doctorate (PhD, EdD) or Professional Degree (MD, DDS, DVM, LLB, JD)"
    ))
  ),
  natality_pct_cesarean = list(
    num = natality_cells("delivery_method", "Cesarean"),
    den = natality_cells("delivery_method", c("Cesarean", "Vaginal"))
  ),
  natality_pct_twin_plus = list(
    num = natality_cells("plurality", c("Twin", "Triplet or higher")),
    den = natality_cells("plurality", c("Single", "Twin", "Triplet or higher"))
  ),
  natality_pct_no_prenatal_care = list(
    num = natality_cells("prenatal_care_trimester", "No prenatal care"),
    den = natality_cells("prenatal_care_trimester", c(
      "1st to 3rd month", "4th to 6th month", "7th to final month", "No prenatal care"
    ))
  ),
  natality_pct_tobacco = list(
    num = natality_cells("tobacco_use", "Yes"),
    den = natality_cells("tobacco_use", c("Yes", "No"))
  ),
  natality_pct_unmarried = list(
    num = natality_cells("marital_status", "Unmarried"),
    den = natality_cells("marital_status", c("Married", "Unmarried"))
  )
)

# `detail` holds one geography level's rows from a data_*_detail.csv.gz file,
# with columns geography, time (already year-end Date), dimension, category and
# natality_births (NA where suppressed). Returns geography, time, measure, value.
natality_percent_long <- function(detail) {
  sum_cells <- function(cells) {
    detail %>%
      inner_join(cells, by = c("dimension", "category")) %>%
      group_by(geography, time) %>%
      summarise(
        n_cells = n(),
        count   = if (anyNA(natality_births)) NA_real_ else sum(natality_births),
        .groups = "drop"
      ) %>%
      filter(n_cells == nrow(cells)) %>%
      select(geography, time, count)
  }

  bind_rows(lapply(names(NATALITY_PERCENT_SPECS), function(measure) {
    spec <- NATALITY_PERCENT_SPECS[[measure]]
    inner_join(
      sum_cells(spec$num), sum_cells(spec$den),
      by = c("geography", "time"), suffix = c("_num", "_den")
    ) %>%
      filter(!is.na(count_num), !is.na(count_den), count_den > 0) %>%
      transmute(
        geography,
        time,
        measure = measure,
        value   = round(100 * count_num / count_den, 2)
      )
  }))
}
