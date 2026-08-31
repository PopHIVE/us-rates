# us-rates

US health measures and disease rates, organized by geography and published in PopHIVE's long-format convention.

Every measure is available at up to four levels — national, state, US territory, and county — each in its own folder, as gzip-compressed CSV. Measure definitions, sources, and citations live in a single top-level [`measure_info.json`](measure_info.json).

* **Using the data?** Start with [File Format](#file-format) and [Measure Documentation](#measure-documentation).
* **Adding a source or changing the pipeline?** See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Directory Structure

```
us-rates/
│
├── measure_info.json           definitions, sources, and citations for every measure
├── us-rates-geographies.json   flat manifest of every geography and its file path
│
├── national/
│   └── national_rates.csv.gz
│
├── states/
│   ├── states_latest.csv.gz    latest value per state × measure
│   ├── alabama/
│   │   ├── state_rates.csv.gz
│   │   ├── counties_latest.csv.gz
│   │   └── counties/
│   │       ├── 01001_autauga/
│   │       │   └── county_rates.csv.gz
│   │       └── ...
│   └── ...
│
├── territories/
│   ├── puerto_rico/
│   │   ├── commonwealth_rates.csv.gz
│   │   ├── counties_latest.csv.gz
│   │   └── counties/
│   │       └── 72001_adjuntas_municipio/
│   │           └── county_rates.csv.gz
│   └── ...
│
├── code/                       the pipeline that builds all of the above
├── resources/                  FIPS reference table
└── tracker/                    measure registry, vintages, and QA findings
```

Every county folder holds exactly one file. There are no per-county metadata files — all measure documentation is in the top-level `measure_info.json`.

---

## File Format

All data files use PopHIVE's **long format**: one row per `(geography, time, measure)`.

| Column      | Type   | Notes                                                              |
|-------------|--------|--------------------------------------------------------------------|
| `geography` | string | FIPS code, zero-padded — `"00"` national, `"01"` state, `"01001"` county |
| `time`      | string | `YYYY-MM-DD`. Annual values use `YYYY-12-31`; monthly use the last day of the month |
| `measure`   | string | `{prefix}_{measure_name}` — see [Measure Names](#measure-names)      |
| `value`     | number |                                                                      |

```
geography,time,measure,value
01001,2022-12-31,chr_diabetes_prevalence,0.124
01001,2022-12-31,chr_adult_smoking,0.208
01001,2021-12-31,chr_diabetes_prevalence,0.121
```

Sparse measures simply have no row — missing data is never written as `NA`.

**FIPS codes are always strings.** Storing them as integers drops the leading zero and silently corrupts every geography in Alabama, Alaska, Arizona, and Arkansas.

### Latest-value files

Alongside the full time series, two derived files hold a single "latest" cut for charts that compare many places at once:

| File | Contents |
|---|---|
| `states/states_latest.csv.gz` | Every state, DC, and territory reporting at least one measure. No national row. |
| `states/{state}/counties_latest.csv.gz`<br>`territories/{territory}/counties_latest.csv.gz` | Every county or subdivision in that place. Omitted where there is no county-level data. |

One row per `(geography, measure)`, keeping that geography's own most recent `time` for that measure. Because places and measures update on different schedules, this is **not** one global cutoff date. Use the regular rate files for a time series or a like-for-like comparison across places.

---

## Geographies

| Level     | FIPS           | Example |
|-----------|----------------|---------|
| National  | `"00"`         | `00`    |
| State     | 2-digit string | `01`    |
| Territory | 2-digit string | `72`    |
| County    | 5-digit string | `01001` |

County folders are named `{5-digit FIPS}_{county_name}`, lowercase with underscores and without the word "county" — `01001_autauga`, `36061_new_york`. Once created, a folder name never changes; the FIPS code keeps it unique even when a county is renamed.

`us-rates-geographies.json` is a flat manifest of every geography with its display name, slug, and relative file path — the easiest way to enumerate what exists.

### Territories

DC is treated as a state-equivalent and lives under `states/district_of_columbia/`. The six non-state territories live under `territories/`, each shaped exactly like a state folder except that the top-level file is named for the territory's actual political status:

| Territory | FIPS | Top-level file |
|---|---|---|
| Puerto Rico, Northern Mariana Islands | `72`, `69` | `commonwealth_rates.csv.gz` |
| Guam, U.S. Virgin Islands, American Samoa, U.S. Minor Outlying Islands | `66`, `78`, `60`, `74` | `territory_rates.csv.gz` |

Most territories have little or no data. An empty or missing territory file means no source reported values for it, not a pipeline failure.

### Geographies that changed over time

Some county-equivalents have been renamed, split, or merged. `tidycensus::fips_codes` carries every historical version at once and sources migrate on their own schedules, so **this repo holds folders for both conventions simultaneously**. If you're wondering what `02261_valdez_cordova` is doing next to `02063_chugach`, this is why.

**Connecticut** retired its 8 counties for 9 planning regions as county equivalents, effective with the Census Bureau's 2022 vintage:

| Convention | FIPS range | Folders |
|---|---|---|
| Legacy counties | `09001`–`09015` | `09001_fairfield` … `09015_windham` (8) |
| Planning regions | `09110`–`09190` | `09110_capitol` … `09190_western_connecticut` (9) |

**Alaska** has five such changes, so `states/alaska/counties/` holds folders for defunct geographies too:

| Old (defunct) | FIPS | Replaced by | FIPS |
|---|---|---|---|
| Prince of Wales-Outer Ketchikan Census Area (2008) | `02201` | Prince of Wales-Hyder Census Area | `02198` |
| Skagway-Yakutat-Angoon (pre-1992) → Skagway-Hoonah-Angoon (1992–2007) | `02231`, `02232` | Skagway Municipality, Hoonah-Angoon Census Area | `02230`, `02105` |
| Valdez-Cordova Census Area (2019) | `02261` | Chugach, Copper River Census Areas | `02063`, `02066` |
| Wade Hampton Census Area (renamed 2015) | `02270` | Kusilvak Census Area | `02158` |
| Wrangell-Petersburg Census Area (2008) | `02280` | Wrangell City and Borough, Petersburg Census Area | `02275`, `02195` |

Yakutat City and Borough (`02282`) is *not* part of the Skagway lineage despite the "Skagway-Yakutat-Angoon" name — it has been tracked separately since at least 1992 and never overlaps `02231`/`02232`.

**If you aggregate county files, do not sum blindly across both conventions** — the old and new codes carve up the same ground. No single `(measure, time)` pair is ever reported under both conventions for the same place; `code/check_geography_renaming.R` enforces this on every pipeline run and fails the build otherwise. So filtering to one convention is safe, but summing every folder is not.

---

## Measure Names

The `measure` column follows `{prefix}_{measure_name}`:

* **`{prefix}`** identifies the source, and is identical across every measure from that source — `chr`, `acs`, `cms`, `brfss`, `nchs`, `ahrf`.
* **`{measure_name}`** describes the measure — `diabetes_prevalence`, `pct_obesity`, `population`.

All lowercase with underscores, short but unambiguous, with no redundancy (don't append `rate` when the measure type already says so).

A measure pulled from a compiler carries the **compiler's** prefix, not the original producer's. `chr_uninsured` comes to us through County Health Rankings & Roadmaps, which redistributes a Census SAHIE estimate — both facts are recorded in `measure_info.json`, and the prefix reflects the first. Where the same concept is also ingested directly from its producer, that direct pull keeps its own prefix and lives as a separate series: `sahie_pct_uninsured` alongside `chr_uninsured`, `pep_population` alongside `chr_population`. They are not interchangeable — a compiler's series is usually lagged and internally consistent, while a direct pull is current-vintage — so neither overwrites the other.

---

## Measure Documentation

[`measure_info.json`](measure_info.json) documents every measure in the repo, following the PopHIVE schema. `_sources` describes each data source once; each measure then references it by id.

```json
{
  "_sources": {
    "chr": {
      "name": "County Health Rankings & Roadmaps",
      "organization": "University of Wisconsin Population Health Institute",
      "url": "https://www.countyhealthrankings.org",
      "restrictions": "CC BY 4.0. Attribution required. ..."
    }
  },

  "chr_uninsured": {
    "id": "chr_uninsured",
    "short_name": "Uninsured",
    "long_name": "Population Without Health Insurance",
    "category": "social_determinants_of_health",
    "subcategory": "health_care_access_and_quality",
    "short_description": "Percentage of population under age 65 without health insurance.",
    "long_description": "... from the Small Area Health Insurance Estimates (SAHIE) program.",
    "statement": "In {location}, {value} of the population under 65 lacked health insurance.",
    "measure_type": "percent",
    "scale": "0-1",
    "time_resolution": "Year",
    "sources": [{ "id": "chr" }, { "id": "census_sahie" }],
    "compiled_via": "chr"
  }
}
```

| Field | Description |
|---|---|
| `id` | Matches the `measure` column exactly |
| `short_name` / `long_name` | Display labels |
| `category` / `subcategory` | See [Categories](#categories); `subcategory` is `null` where the category has none |
| `short_description` / `long_description` | One sentence, and a fuller note including methodology and any comparability caveats |
| `statement` | Display template — `{value}` is pre-formatted, so don't wrap it in `%` or `$` |
| `measure_type` | `percent`, `number`, or `dollars` |
| `scale` | Percents only: `0-1` or `0-100`, the scale the raw value is stored on |
| `unit` | Optional label where `measure_type` isn't self-explanatory (e.g. `Micrograms per cubic meter`) |
| `time_resolution` | `Week`, `Month`, or `Year` |
| `sources` | Ordered source ids, **first is where PopHIVE pulls the measure from** — for a compiled measure that's the compiler, with the original producer following it |
| `compiled_via` | Present when the measure comes through a compiler (`chr`, `ahrf`); always equals `sources[0]` |
| `vintage` fields | Optional; see [Data Vintage](#data-vintage) |

### Attribution

`_sources[].restrictions` carries each source's terms, and `sources[0]` is who to credit. Most upstream federal sources are public domain, but the compilers are not — **County Health Rankings & Roadmaps is CC BY 4.0 and requires attribution**, and its own redistribution is bounded by the terms of its upstream sources, so a `chr_` measure can carry obligations beyond that citation. `tracker/measure_registry.csv` carries the required citation string per measure in `compiler_citation`.

---

## Data Vintage

**`time` is the release year, not the year the data describes.** Compiled sources typically lag: a value published in the 2025 County Health Rankings release may describe 2022. The two must never be conflated when displaying a year alongside a value.

`tracker/measure_vintages.csv` is the authoritative lookup — one row per `(measure, release)`, giving the true data years behind each published value:

```r
rates |>
  left_join(
    vroom("tracker/measure_vintages.csv"),
    by = c("measure" = "measure_id", "time" = "release_time")
  )
```

**Join on both keys.** The `vintage` fields in `measure_info.json` describe only each measure's most recent release, so applying them across a measure's full history mislabels the great majority of its observations. Joining on both `measure` and `time` resolves every observation this file covers.

A `vintage` of `NA` means the publisher stated no data year for that release, not that the row is missing.

---

## Tracker Files

Machine-readable records of what's in the repo and what's known about it. These are generated — never hand-edited.

| File | Grain | Purpose |
|---|---|---|
| `tracker/measure_registry.csv` | one row per measure | Source, pipeline, coverage counts, time range, vintage, citation, and duplicate-group membership. The catalog. |
| `tracker/measure_vintages.csv` | one row per (measure, release) | True data years behind each release — see [Data Vintage](#data-vintage). |
| `tracker/qa_findings.csv` | one row per finding | Automated checks for out-of-scale values, inverted ratios, mixed units, and wrong-magnitude series, each with a `status` and a written diagnosis. |

**Check `qa_findings.csv` before treating a long series as continuous.** Some measures have genuine breaks where a publisher changed a definition, a denominator, or a unit mid-series — values either side are not comparable, and the values as stored are correct rather than something to be repaired. Where a break is known, it is also described in that measure's `long_description`.

`duplicate_group` in the registry marks measures covering the same concept from different sources. They are deliberately kept as separate series and are not interchangeable; the `duplicate_note` explains how they differ.

---

## Categories

| Category | Subcategories |
|---|---|
| `chronic_disease` | `cancer`, `cardiovascular_metabolic`, `musculoskeletal`, `neurological`, `other_chronic_conditions`, `respiratory_disease` |
| `environmental_health` | `air_and_water_quality`, `other_environmental_hazards` |
| `infectious_disease` | none |
| `injury_and_violence` | none |
| `maternal_and_infant_health` | none |
| `mental_health` | none |
| `overall_health_status_and_mortality` | `length_and_quality_of_life`, `mortality_data_and_completeness` |
| `population_demographics` | none |
| `preventive_care` | `clinical_screenings`, `immunizations`, `nutrition_and_exercise`, `sexual_and_reproductive_health` |
| `social_determinants_of_health` | `economic_stability`, `education_access_and_quality`, `health_care_access_and_quality`, `neighborhood_and_built_environment`, `social_and_community_context` |
| `substance_abuse` | `alcohol_use`, `drug_use_and_overdose`, `tobacco_use` |

---

## Rebuilding the Data

The repo is generated by a pipeline of R scripts that read from a sibling `Ingest` clone, expected at `../Ingest`. From the repo root:

```
Rscript code/update_all.R --skip-scaffold
```

Make sure `Ingest` is up to date first — the pipeline reads directly from `../Ingest/data/`. Drop `--skip-scaffold` when new geographies need folders created. Individual scripts can be run on their own; each carries a `Usage` note at the top.

For what each step does, how to add a data source, and the conventions a new source has to satisfy, see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Principles

* **FIPS-first** — geographies are identified by code, never by name alone.
* **Long format** — one row per `(geography, time, measure)`; sparse measures have no row rather than an `NA`.
* **Consistent naming** — `{prefix}_{measure_name}` across every file, without exception.
* **Documented measures** — every measure has an entry in `measure_info.json`.
* **Stable folders** — county folder names don't change once created.
* **Credit where the data was pulled from** — `sources[0]` names the immediate provider, with the original producer recorded behind it.
* **Label the break, don't repair the data** — where a publisher changed a definition mid-series, the values stand as published and the discontinuity is documented.
