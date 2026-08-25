# us-rates

This repository organizes health measures and disease rates by geographic level, aligned with PopHIVE data conventions:

* United States (national)
* State
* U.S. territory
* County

Each state (and, separately, each U.S. territory — see [U.S. Territories](#us-territories)) has its own folder. Within each, every county (or territory subdivision) has its own subfolder named using the 5-digit FIPS code followed by the name. All data files use compressed CSV format (`.csv.gz`) and follow PopHIVE's **long format** standard for bundles.

---

## Directory Structure

```
us-rates/
│
├── README.md
├── measure_info.json
├── us-rates-geographies.json
│
├── national/
│   └── national_rates.csv.gz
│
├── states/
│   ├── states_latest.csv.gz
│   ├── alabama/
│   │   ├── state_rates.csv.gz
│   │   ├── counties_latest.csv.gz
│   │   └── counties/
│   │       ├── 01001_autauga/
│   │       │   └── county_rates.csv.gz
│   │       ├── 01003_baldwin/
│   │       │   └── county_rates.csv.gz
│   │       └── ...
│   │
│   ├── alaska/
│   │   ├── state_rates.csv.gz
│   │   ├── counties_latest.csv.gz
│   │   └── counties/
│   │       └── ...
│   │
│   ├── arizona/
│   └── ...
│
└── territories/
    ├── puerto_rico/
    │   ├── commonwealth_rates.csv.gz
    │   ├── counties_latest.csv.gz
    │   └── counties/
    │       ├── 72001_adjuntas_municipio/
    │       │   └── county_rates.csv.gz
    │       └── ...
    │
    ├── guam/
    │   ├── territory_rates.csv.gz
    │   └── counties/
    │       └── ...
    │
    └── ...
```

DC is a state-equivalent for this repo's purposes and lives under `states/district_of_columbia/`, not `territories/`.

---

## County Folder Naming Convention

Applies identically to county-equivalent subdivisions under `territories/` (e.g. Puerto Rico's municipios). Folders use the 5-digit FIPS code followed by the county name, all lowercase with underscores:

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

| Level     | FIPS Format    | Example |
|-----------|----------------|---------|
| National  | `"00"`         | `00`    |
| State     | 2-digit string | `01`    |
| Territory | 2-digit string | `72`    |
| County    | 5-digit string | `01001` |

FIPS codes must always be stored as zero-padded strings, never as integers.

---

## U.S. Territories

DC and the 50 states aren't the only 2-digit geographies — `tidycensus::fips_codes` also carries 2-digit codes for 6 non-state U.S. territories. DC is treated as a state-equivalent and lives under `states/`; the other 6 live under their own top-level `territories/` folder instead, since they aren't states:

| Territory                   | Abbreviation | FIPS | Political Status                          | Top-level file            |
|------------------------------|--------------|------|--------------------------------------------|----------------------------|
| Puerto Rico                   | `PR`         | `72` | Commonwealth (organized, unincorporated)    | `commonwealth_rates.csv.gz` |
| Northern Mariana Islands      | `MP`         | `69` | Commonwealth (organized, unincorporated)    | `commonwealth_rates.csv.gz` |
| Guam                          | `GU`         | `66` | Territory (organized, unincorporated)       | `territory_rates.csv.gz`   |
| U.S. Virgin Islands           | `VI`         | `78` | Territory (organized, unincorporated)       | `territory_rates.csv.gz`   |
| American Samoa               | `AS`         | `60` | Territory (unorganized, unincorporated)     | `territory_rates.csv.gz`   |
| U.S. Minor Outlying Islands   | `UM`         | `74` | No organized government or population       | `territory_rates.csv.gz`   |

Each territory's folder (`territories/american_samoa/`, `territories/guam/`, etc.) follows the exact same shape as a state folder — a top-level rates file plus a `counties/` subfolder for its FIPS-coded subdivisions (e.g. Puerto Rico's 78 municipios) — except the top-level file is named for that territory's actual political status rather than reusing `state_rates.csv.gz`, since territories aren't states: `commonwealth_rates.csv.gz` for Puerto Rico and the Northern Mariana Islands (the two organized, unincorporated commonwealths), `territory_rates.csv.gz` for the rest. `code/geography_helpers.R`'s `is_territory()` and `territory_rates_filename()` are the single source of truth for this; `scaffold_structure.R`, `populate_state_rates.R`, `populate_county_rates.R`, and `generate_geography_manifest.R` all route on them, so a geography's folder and filename are never hand-picked per script.

Most territories have little to no data across the sources in `measure_info.json` (health-workforce and mortality sources being the most likely to report any territory-level values) — an empty or missing `territories/{name}/` file just means no source reported data for it, not a pipeline bug.

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

Because the two conventions carve up the same towns, summing county folders for a given `(measure, time)` pair double-counts if that pair is ever reported under both conventions. `code/check_geography_renaming.R` checks for exactly that after every `populate_county_rates.R` run and fails the pipeline if it finds one — see [Alaska: Historical Borough and Census Area Changes](#alaska-historical-borough-and-census-area-changes) for the same issue elsewhere in the pipeline.

---

## Alaska: Historical Borough and Census Area Changes

Alaska's boroughs and census areas have been renamed, split, and merged repeatedly, and `tidycensus::fips_codes` carries every historical version at once, so `states/alaska/counties/` holds folders for defunct geographies too:

| Old (defunct)                                  | FIPS(es)          | Replaced by                                              | FIPS(es)                 |
|-------------------------------------------------|-------------------|------------------------------------------------------------|----------------------------|
| Prince of Wales-Outer Ketchikan Census Area (2008) | `02201`          | Prince of Wales-Hyder Census Area                          | `02198`                    |
| Skagway-Yakutat-Angoon Census Area (pre-1992) -> Skagway-Hoonah-Angoon Census Area (1992-2007) | `02231`, `02232` | Skagway Municipality, Hoonah-Angoon Census Area | `02230`, `02105` |
| Valdez-Cordova Census Area (2019)                | `02261`          | Chugach Census Area, Copper River Census Area               | `02063`, `02066`            |
| Wade Hampton Census Area (renamed 2015)          | `02270`          | Kusilvak Census Area                                        | `02158`                    |
| Wrangell-Petersburg Census Area (2008)           | `02280`          | Wrangell City and Borough, Petersburg Census Area            | `02275`, `02195`            |

`code/check_geography_renaming.R` checks each of these 5 events the same way as the CT check above. Yakutat City and Borough (`02282`) isn't part of the Skagway lineage above despite the "Skagway-Yakutat-Angoon" name -- it's been separately tracked since at least 1992 and never overlaps with `02231`/`02232`.

Two sources duplicate data onto these retired codes rather than cutting over cleanly, resolved in `populate_county_rates.R`:

* `vaccine_exemptions_fattah` always writes the exact same value to a retired code and its successor(s), so the retired code's copy is dropped unconditionally (`drop_alaska_defunct_duplicates()`).
* `area_health_resource_file` sometimes duplicates and sometimes disagrees between a retired code and its successor(s) for the same (measure, time) -- the disagreements are almost always a newly-created code's placeholder `0` before real tracking starts, or a retired code's value decaying to `0` in its last year or two before being dropped from the file. Each of the 79 affected rows is resolved by an explicit, documented override table (`ahrf_alaska_overrides`) rather than a general rule, since guessing wrong here means silently reporting the wrong health-workforce count.

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

## Latest-Value Files

Alongside the full time-series files above, two derived files hold a single "latest" cut for charts that compare many places at once rather than one place over time. Same columns and long-format rules as every other file (`geography`, `time`, `measure`, `value`) — just one row per `(geography, measure)` pair, keeping that geography's own most recent `time` for that measure (different geographies and measures update on different schedules, so this is not one global cutoff date):

| File                                     | Contents                                                              |
|-------------------------------------------|-------------------------------------------------------------------------|
| `states/states_latest.csv.gz`              | Every state, DC, and territory that reports at least one measure, one row per `(geography, measure)`. No national (`00`) row. |
| `states/{state}/counties_latest.csv.gz` and `territories/{territory}/counties_latest.csv.gz` | Every county (or territory subdivision) in that place, one row per `(geography, measure)`. Omitted for a place with no county-level data. |

Both are written by `code/populate_latest_rates.R`, which derives them from the already-written `state_rates.csv.gz` / `commonwealth_rates.csv.gz` / `territory_rates.csv.gz` and `county_rates.csv.gz` files rather than re-reading `Ingest` — so it must run after `populate_state_rates.R` and `populate_county_rates.R` (see [Updating the Data](#updating-the-data)). These are chart-only conveniences; use the regular rate files above for a specific place's time series or a US comparison.

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
├── counties_latest.csv.gz ← latest value per county x measure (see Latest-Value Files)
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
    "statement": "In {location}, {value} of adults have been diagnosed with diabetes.",
    "measure_type": "percent",
    "scale": "0-100",
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
| `statement`         | Template string for display: `"In {location}, ..."` — `{value}` holds a pre-formatted value; do not wrap it in `%`, `$`, or other symbols |
| `measure_type`      | One of: `percent`, `number`, `dollars` — indicates how to format `{value}` |
| `scale`             | Only present when `measure_type` is `percent`. One of: `0-1`, `0-100` — the scale the raw value is stored on |
| `unit`              | Optional. A data label to show alongside the value, only when necessary to contextualize it (e.g. `Micrograms per cubic meter`). Omitted when `measure_type` already conveys enough (e.g. plain percents/dollars) |
| `time_resolution`   | One of: `Week`, `Month`, `Year`                                           |
| `sources`           | Array of source IDs matching entries in `_sources`                        |

**Vintage fields (optional):**

The `time` column in the rate files carries the **release year**, which for compiled sources is often much later than the year the underlying data describes. These optional fields record the true data vintage so the two are never confused:

| Field             | Description                                                                 |
|-------------------|------------------------------------------------------------------------------|
| `vintage`         | The data years as the upstream source states them, verbatim — may be a single year (`"2022"`), a range (`"2016-2022"`), or a set (`"2020 & 2016"`) |
| `vintage_min`     | Earliest data year, parsed from `vintage`                                    |
| `vintage_max`     | Latest data year, parsed from `vintage`                                      |
| `vintage_release` | The release the vintage describes — i.e. which edition `vintage` came from  |

Present on the 137 `chr_` measures that CHR&R supplies a `years_used` value for (118 of them), sourced from CHR&R's own `t_measure_years.csv`. They describe each measure's **most recent release**, which is what the latest-only explorer displays; they are not per-observation, so they should not be used to label historical years in a trend view. Measures from other pipelines have no vintage yet — each needs its own upstream vintage source before these can be filled in.

Absent for four measures retired after the 2010/2011 editions (`chr_college_degrees`, `chr_hospice_use`, `chr_liquor_store_density`, `chr_single_parent_households`), where CHR&R left `years_used` blank, and for the 15 state-specific `_fl`/`_ny` measures, which come from CHR&R's state additional-measures tables and have different data years than the national measure of the same name — deliberately not inherited from it.

The registry (`tracker/measure_registry.csv`) carries these plus a derived `vintage_lag` (`vintage_release - vintage_min`), which is the fastest way to spot measures whose displayed year badly overstates how current they are.

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
2. **`scaffold_structure.R`** — creates any new `states|territories/{name}/counties/{fips}_{name}/` folders (safe to re-run; existing folders are never overwritten). Skip with `--skip-scaffold` once the tree is already up to date.
3. **`code/populate_national_rates.R`** — writes `national/national_rates.csv.gz`.
4. **`code/populate_state_rates.R`** — writes `states/*/state_rates.csv.gz` and `territories/*/{commonwealth,territory}_rates.csv.gz`.
5. **`code/populate_county_rates.R`** — writes `states|territories/*/counties/*/county_rates.csv.gz`.
6. **`code/populate_latest_rates.R`** — writes `states/states_latest.csv.gz` and `states|territories/*/counties_latest.csv.gz`, the chart-only "latest value per geography x measure" cuts (see [Latest-Value Files](#latest-value-files)).
7. **`code/check_geography_renaming.R`** — fails the pipeline if any `(measure, time)` pair is reported under both an old and new FIPS convention for a renamed/split/merged geography (see [Connecticut: Counties vs. Planning Regions](#connecticut-counties-vs-planning-regions) and [Alaska: Historical Borough and Census Area Changes](#alaska-historical-borough-and-census-area-changes)).
8. **`code/generate_geography_manifest.R`** — refreshes `us-rates-geographies.json`, a flat manifest of every geography (national/state/county) with its display name, slug, and the relative path to its rate file, for front-end/site consumption.

To skip the (usually unnecessary) scaffolding step on a routine data refresh:

```
Rscript code/update_all.R --skip-scaffold
```

**Before running:** make sure the `Ingest` repo alongside this one is up to date, since the `populate_*` scripts read directly from `../Ingest/data/`. Any script can also be run individually (see the `Usage` comment at the top of each file) if you only need to refresh one part of the pipeline.

**Adding a new data source:** add a block to the relevant `populate_*_rates.R` script(s) that reads the new Ingest source, reshapes it into long format (`geography`, `time`, `measure`, `value`), and joins it into that script's `combined` bind_rows() call — then add a corresponding entry to `measure_info.json` for every new measure name. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full step-by-step walkthrough, including which script(s) to touch for a given geography level and the Alaska/Connecticut edge cases to check for.

---

## Principles

* **FIPS-first:** All geographies are identified by FIPS codes, never by name alone.
* **Long format:** One row per `(geography, time, measure)` combination. Sparse measures have no rows rather than `NA` values.
* **Compressed files:** All data files use `.csv.gz` to minimize storage across thousands of county folders.
* **Consistent naming:** The `measure` column follows `{prefix}_{measure_name}` across all files without exception.
* **Documented measures:** Every measure must have a corresponding entry in the top-level `measure_info.json`.
* **No integers for FIPS:** FIPS codes are always stored as zero-padded strings (e.g., `"01"` not `1`, `"01001"` not `1001`).
* **Folder names are stable:** Once created, county folder names should not change. The FIPS code ensures uniqueness even if county names change over time.
