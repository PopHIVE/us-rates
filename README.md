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
| `category`          | One of: `respiratory`, `immunization`, `chronic`, `injury`, `demographic` |
| `short_description` | One-sentence description                                                   |
| `long_description`  | Detailed description including methodology notes                           |
| `statement`         | Template string for display: `"In {location}, ..."`                       |
| `measure_type`      | One of: `Incidence`, `Prevalence`, `Rate`, `Percent`, `Count`             |
| `unit`              | e.g., `Cases per 100,000`, `Percent`, `Count`                             |
| `time_resolution`   | One of: `Week`, `Month`, `Year`                                           |
| `sources`           | Array of source IDs matching entries in `_sources`                        |

---

## Principles

* **FIPS-first:** All geographies are identified by FIPS codes, never by name alone.
* **Long format:** One row per `(geography, time, measure)` combination. Sparse measures have no rows rather than `NA` values.
* **Compressed files:** All data files use `.csv.gz` to minimize storage across thousands of county folders.
* **Consistent naming:** The `measure` column follows `{prefix}_{measure_name}` across all files without exception.
* **Documented measures:** Every measure must have a corresponding entry in the top-level `measure_info.json`.
* **No integers for FIPS:** FIPS codes are always stored as zero-padded strings (e.g., `"01"` not `1`, `"01001"` not `1001`).
* **Folder names are stable:** Once created, county folder names should not change. The FIPS code ensures uniqueness even if county names change over time.
