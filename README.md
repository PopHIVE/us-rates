# us-rates

This repository organizes health measures and disease rates by geographic level, aligned with PopHIVE data conventions:

* United States (national)
* State
* County

Each state has its own folder. Within each state folder, each county has its own subfolder named using the 5-digit county FIPS code followed by the county name. All data files use compressed CSV format (`.csv.gz`) and follow PopHIVE's **long format** standard for bundles.

---

## Directory Structure

```
us-rates/
│
├── README.md
├── measure_info.json
│
├── national/
│   └── national_rates.csv.gz
│
└── states/
    ├── alabama/
    │   ├── state_rates.csv.gz
    │   └── counties/
    │       ├── 01001_autauga/
    │       │   └── county_rates.csv.gz
    │       ├── 01003_baldwin/
    │       │   └── county_rates.csv.gz
    │       └── ...
    │
    ├── alaska/
    │   ├── state_rates.csv.gz
    │   └── counties/
    │       └── ...
    │
    ├── arizona/
    └── ...
```

---

## County Folder Naming Convention

County folders use the 5-digit FIPS code followed by the county name, all lowercase with underscores:

```
[5-digit FIPS]_[county_name]
```

**Examples:**

| Folder Name         | State       | County    |
|---------------------|-------------|-----------|
| `01001_autauga`     | Alabama     | Autauga   |
| `01003_baldwin`     | Alabama     | Baldwin   |
| `09001_fairfield`   | Connecticut | Fairfield |
| `09003_hartford`    | Connecticut | Hartford  |
| `36061_new_york`    | New York    | New York  |

> **Note:** Multi-word county names use underscores (e.g., `36061_new_york`, not `36061_newyork`). Do not include the word "county" in the folder name.

---

## Geographic Levels & FIPS Codes

PopHIVE uses FIPS codes as the standard geography identifier in all data files:

| Level    | FIPS Format    | Example |
|----------|----------------|---------|
| National | `"00"`         | `00`    |
| State    | 2-digit string | `01`    |
| County   | 5-digit string | `01001` |

FIPS codes must always be stored as zero-padded strings, never as integers.

---

## Connecticut: Counties vs. Planning Regions

Connecticut retired its 8 counties in favor of 9 planning regions as county equivalents, effective with the Census Bureau's 2022 vintage. Because sources migrate to this convention at different times, `states/connecticut/counties/` holds folders for **both** conventions at once:

| Convention        | FIPS range      | Folders                                                    |
|--------------------|-----------------|-------------------------------------------------------------|
| Legacy counties    | `09001`-`09015` | `09001_fairfield` ... `09015_windham` (8)                    |
| Planning regions   | `09110`-`09190` | `09110_capitol` ... `09190_western_connecticut` (9)          |

Both sets come from `tidycensus::fips_codes`, which lists both conventions simultaneously — no CT-specific branching is needed elsewhere in the pipeline as a result.

Sources migrate to planning regions on their own schedules, so the same `Ingest` bundle can carry both conventions for different years or even different measures within the same year. As of the last refresh:

| Source                                    | Convention                                                                                          |
|--------------------------------------------|------------------------------------------------------------------------------------------------------|
| Census (ACS)                                | Legacy counties through 2021, planning regions from 2022 on — a clean cutover                        |
| County Health Rankings                      | Legacy counties 2010-2024; the 2025 release splits measures across both conventions (never the same measure under both) |
| Epic Cosmos, NCHS mortality, CMS MMD         | Legacy counties throughout, including releases after 2022                                            |
| WaPo vaccination rates, HealthMap            | Planning regions throughout, including years before 2022 (these aggregate by Council-of-Governments boundary, which predates the 2022 FIPS change) |

Because the two conventions carve up the same towns, summing county folders for a given `(measure, time)` pair double-counts if that pair is ever reported under both conventions. `code/check_ct_geography.R` checks for exactly that after every `populate_county_rates.R` run and fails the pipeline if it finds one.

---

## File Format Standard

All data files must follow PopHIVE's **long format** with compressed CSV encoding:

* File extension: `.csv.gz` (gzip-compressed CSV)
* One row per unique `(geography, time, measure)` combination
* `geography` — FIPS code string
* `time` — `YYYY-MM-DD` (annual: `YYYY-12-31`, monthly: last day of month)
* `measure` — measure name string following `{prefix}_{measure_name}` convention
* `value` — numeric

**Example — `county_rates.csv.gz` (first few rows):**

```
geography,time,measure,value
01001,2022-12-31,chr_diabetes_prevalence,12.4
01001,2022-12-31,brfss_pct_obesity,34.1
01001,2022-12-31,cdc_heart_disease_rate,198.6
01001,2021-12-31,chr_diabetes_prevalence,12.1
01001,2021-12-31,brfss_pct_obesity,33.7
01001,2021-12-31,cdc_heart_disease_rate,201.2
```

---

## Column Naming Convention

The `measure` column follows the `{prefix}_{measure_name}` pattern:

* **`{prefix}`** — Short identifier for the data source (e.g., `cdc`, `brfss`, `acs`, `cms`). Consistent across all measures from the same source.
* **`{measure_name}`** — Short, descriptive name for the specific measure (e.g., `diabetes_prevalence`, `pct_obesity`, `heart_disease_rate`).

**Rules:**
* All lowercase with underscores — no spaces or special characters
* Prefix must be consistent across all measures from the same source
* Names should be short but unambiguous
* Avoid redundancy (e.g., don't repeat `rate` if the measure type is already a rate)

**Examples:**

| Measure Name                 | Source | Description                       |
|------------------------------|--------|-----------------------------------|
| `cdc_diabetes_prevalence`    | CDC    | Diabetes prevalence               |
| `cdc_cancer_incidence`       | CDC    | Cancer incidence rate             |
| `cdc_heart_disease_rate`     | CDC    | Heart disease mortality rate      |
| `brfss_pct_obesity`          | BRFSS  | Percent obese                     |
| `brfss_pct_smoking`          | BRFSS  | Percent current smokers           |
| `acs_pct_poverty`            | ACS    | Percent below poverty line        |
| `acs_pop_total`              | ACS    | Total population                  |
| `cms_pct_medicare`           | CMS    | Percent enrolled in Medicare      |

---

## County Folder Contents

Each county folder contains a single rates file:

```
01001_autauga/
└── county_rates.csv.gz    ← all measures for this county, long format
```

All counties share the same measure definitions. Measure documentation lives in the top-level `measure_info.json` only — there are no per-county metadata files.

---

## State Folder Contents

Each state folder contains state-level rates and a counties subfolder:

```
alabama/
├── state_rates.csv.gz     ← state-level measures for Alabama (geography = "01")
└── counties/
    ├── 01001_autauga/
    ├── 01003_baldwin/
    └── ...
```

---

## Top-Level `measure_info.json`

The root `measure_info.json` documents every measure used across the repository. It follows the PopHIVE schema:

```json
{
  "_sources": {
    "cdc": {
      "name": "Centers for Disease Control and Prevention",
      "url": "https://www.cdc.gov",
      "organization": "CDC",
      "organization_url": "https://www.cdc.gov",
      "description": "Federal public health agency providing national disease surveillance data.",
      "restrictions": "Public domain unless otherwise noted."
    }
  },

  "cdc_diabetes_prevalence": {
    "id": "cdc_diabetes_prevalence",
    "short_name": "Diabetes Prevalence",
    "long_name": "Diagnosed Diabetes Prevalence",
    "category": "chronic",
    "short_description": "Percentage of adults with diagnosed diabetes.",
    "long_description": "Age-adjusted percentage of adults ever told by a doctor they have diabetes, excluding gestational diabetes. Source: CDC PLACES.",
    "statement": "In {location}, {value} percent of adults have been diagnosed with diabetes.",
    "measure_type": "Prevalence",
    "unit": "Percent",
    "time_resolution": "Year",
    "sources": [{ "id": "cdc" }]
  }
}
```

**Required fields for each measure:**

| Field               | Description                                                                |
|---------------------|----------------------------------------------------------------------------|
| `id`                | Measure name (matches the `measure` column value exactly)                  |
| `short_name`        | Human-readable short label                                                 |
| `long_name`         | Full descriptive name                                                      |
| `category`          | One of the categories listed below                                         |
| `subcategory`       | A subcategory from the table below, or `null` if the category has none     |
| `short_description` | One-sentence description                                                   |
| `long_description`  | Detailed description including methodology notes                           |
| `statement`         | Template string for display: `"In {location}, ..."`                       |
| `measure_type`      | One of: `Incidence`, `Prevalence`, `Rate`, `Percent`, `Count`, `Category` |
| `unit`              | e.g., `Cases per 100,000`, `Percent`, `Count`                             |
| `time_resolution`   | One of: `Week`, `Month`, `Year`                                           |
| `sources`           | Array of source IDs matching entries in `_sources`                        |

**Categories and their subcategories:**

| Category                              | Subcategories                                                                                          |
|----------------------------------------|---------------------------------------------------------------------------------------------------------|
| `chronic_disease`                      | `cancer`, `cardiovascular_metabolic`, `musculoskeletal`, `neurological`, `other_chronic_conditions`, `respiratory_disease` |
| `environmental_health`                  | `air_and_water_quality`, `other_environmental_hazards`                                                  |
| `infectious_disease`                    | none (`null`)                                                                                            |
| `injury_and_violence`                   | none (`null`)                                                                                            |
| `maternal_and_infant_health`            | none (`null`)                                                                                            |
| `mental_health`                         | none (`null`)                                                                                            |
| `overall_health_status_and_mortality`   | `length_and_quality_of_life`, `mortality_data_and_completeness`                                          |
| `population_demographics`               | none (`null`)                                                                                            |
| `preventive_care`                       | `clinical_screenings`, `immunizations`, `nutrition_and_exercise`, `sexual_and_reproductive_health`       |
| `social_determinants_of_health`         | `economic_stability`, `education_access_and_quality`, `health_care_access_and_quality`, `neighborhood_and_built_environment`, `social_and_community_context` |
| `substance_abuse`                       | `alcohol_use`, `drug_use_and_overdose`, `tobacco_use`                                                    |

---

## Updating the Data

The repo is built by a pipeline of R scripts that pull from a sibling `Ingest` clone (expected at `../Ingest` relative to this repo) and write into the folder structure described above. Run everything at once with the wrapper script, from the repo root:

```
Rscript code/update_all.R
```

This runs, in order:

1. **`all_fips.R`** — refreshes `resources/all_fips.csv.gz`, the FIPS-code-to-name reference table (via `tidycensus`).
2. **`scaffold_structure.R`** — creates any new `states/{state}/counties/{fips}_{name}/` folders (safe to re-run; existing folders are never overwritten). Skip with `--skip-scaffold` once the tree is already up to date.
3. **`code/populate_national_rates.R`** — writes `national/national_rates.csv.gz`.
4. **`code/populate_state_rates.R`** — writes `states/*/state_rates.csv.gz`.
5. **`code/populate_county_rates.R`** — writes `states/*/counties/*/county_rates.csv.gz`.
6. **`code/check_ct_geography.R`** — fails the pipeline if any `(measure, time)` pair is reported under both of CT's county/planning-region conventions (see [Connecticut: Counties vs. Planning Regions](#connecticut-counties-vs-planning-regions)).

To skip the (usually unnecessary) scaffolding step on a routine data refresh:

```
Rscript code/update_all.R --skip-scaffold
```

**Before running:** make sure the `Ingest` repo alongside this one is up to date, since the `populate_*` scripts read directly from `../Ingest/data/`. Any script can also be run individually (see the `Usage` comment at the top of each file) if you only need to refresh one part of the pipeline.

**Adding a new data source:** add a block to the relevant `populate_*_rates.R` script(s) that reads the new Ingest source, reshapes it into long format (`geography`, `time`, `measure`, `value`), and joins it into that script's `combined` bind_rows() call — then add a corresponding entry to `measure_info.json` for every new measure name.

---

## Principles

* **FIPS-first:** All geographies are identified by FIPS codes, never by name alone.
* **Long format:** One row per `(geography, time, measure)` combination. Sparse measures have no rows rather than `NA` values.
* **Compressed files:** All data files use `.csv.gz` to minimize storage across thousands of county folders.
* **Consistent naming:** The `measure` column follows `{prefix}_{measure_name}` across all files without exception.
* **Documented measures:** Every measure must have a corresponding entry in the top-level `measure_info.json`.
* **No integers for FIPS:** FIPS codes are always stored as zero-padded strings (e.g., `"01"` not `1`, `"01001"` not `1001`).
* **Folder names are stable:** Once created, county folder names should not change. The FIPS code ensures uniqueness even if county names change over time.
