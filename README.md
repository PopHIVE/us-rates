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
01001,2022-12-31,chr_diabetes_prevalence,11.2
01001,2022-12-31,chr_adult_smoking,19.7
01001,2021-12-31,chr_diabetes_prevalence,12.7
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

### Telling a retired geography from a current one

`us-rates-geographies.json` carries lineage metadata, so a consumer never has to infer which convention it is looking at:

| Field | Meaning |
|---|---|
| `retired` | `true` if the area is no longer a valid county-equivalent. **Present and boolean on every entry** — never absent, never null, including the national and state rows, which are simply never retired. Trust this rather than inferring from a date, since one boundary date is genuinely unknown. |
| `activeThrough` | ISO date the area ceased to be valid. Absent if current, or if the date predates the Census change logs. |
| `activeFrom` | ISO date the area came into existence, where a documented event created it. Absent for areas older than the records. |
| `supersededBy` | FIPS codes now covering this retired area's ground. Always an array. |
| `supersedes` | FIPS codes this area replaced. Always an array. |

The last four are omitted where they have nothing to say — for those, absence has exactly one meaning (no recorded boundary, no successor). `retired` is the field with two possible readings, which is why it is the one that always appears.

```json
{ "fips": "02261", "name": "Valdez-Cordova Census Area", "retired": true,
  "activeThrough": "2019-01-02", "supersededBy": ["02063", "02066"] }
```

Effective dates are the Census Bureau's own, from its [county-changes documentation](https://www.census.gov/programs-surveys/geography/technical-documentation/county-changes). `GEOGRAPHY_LINEAGE` in `code/geography_helpers.R` is the single source for both this metadata and the double-count check, so the two cannot disagree.

**Why this matters:** roughly 17,000 observations sit on county-equivalents that had already been dissolved when the data was collected — because the sources feeding them migrate on their own schedules, not because anything is wrong with the values. The data is correct; the labels need this metadata to be read correctly. **Filter on `retired` and `activeThrough` before presenting a current-year view.**

Two limits worth knowing before you rely on `supersededBy`:

* **Connecticut's legacy counties and planning regions do not nest.** The regions were assembled from towns and several counties split across more than one region, so each retired county points at all nine regions. Read it as "look at these instead", not as a containment mapping.
* **Alaska's 2008 Prince of Wales-Outer Ketchikan dissolution also moved territory into Ketchikan Gateway Borough (`02130`) and Wrangell City and Borough (`02275`)**, both of which survive. Only the direct successor (`02198`) is recorded, so a user sent there is not seeing the whole of the old area.

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
    "scale": "0-100",
    "time_resolution": "Year",
    "sources": [{ "id": "chr" }, { "id": "census_sahie" }],
    "compiled_via": "chr",
    "display_status": "primary",
    "duplicate_group": "uninsured_all_ages",
    "duplicate_note": "Census SAHIE under-65 uninsured rate, via CHR&R"
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
| `scale` | Percents only. **`0-100` is the standard** — a percent measure stores `18.44`, not `0.1844` — and every percent measure in the repo now declares it. `0-1` remains valid in the schema and the QA bounds check still honours it, so a future source that cannot be conformed can declare it honestly rather than silently |
| `unit` | Optional label where `measure_type` isn't self-explanatory (e.g. `Micrograms per cubic meter`) |
| `time_resolution` | `Week`, `Month`, or `Year` |
| `sources` | Ordered source ids, **first is where PopHIVE pulls the measure from** — for a compiled measure that's the compiler, with the original producer following it |
| `compiled_via` | Present when the measure comes through a compiler (`chr`, `ahrf`); always equals `sources[0]` |
| `display_status` | `primary`, `historical`, or `qa-only` — **present on every measure**, so treat an absent value as an error rather than as `primary`. See [Tracker Files](#tracker-files) |
| `duplicate_group` | Present only where a measure shares a concept with others; absent means ungrouped. `duplicate_note` records how this member differs from its siblings |
| `vintage` fields | Optional; see [Data Vintage](#data-vintage) |

### Attribution

`_sources[].restrictions` carries each source's terms, and `sources[0]` is who to credit. Most upstream federal sources are public domain, but the compilers are not — **County Health Rankings & Roadmaps is CC BY 4.0 and requires attribution**, and its own redistribution is bounded by the terms of its upstream sources, so a `chr_` measure can carry obligations beyond that citation.

**Everything needed to build the citation is in `measure_info.json`.** Take the wording from `_sources[compiled_via].restrictions` and the edition from the measure's own `vintage_release` — which every `chr_` measure carries, enforced at build time. Cite the edition the measure actually came from, **not the current one**: `chr_hospice_use` last appeared in CHR&R's 2010 release and must cite 2010. Reaching for `_sources.chr.date_accessed` instead would cite the 2025 edition for a measure not published since 2010.

`tracker/measure_registry.csv` also carries a pre-composed `compiler_citation`, along with `compiler_first_year` / `compiler_last_year`, if you are already reading the registry — but it is a convenience, not the only route.

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

**Join on both keys.** Doing so resolves **100%** of the observations this file covers, at either scope below. The `vintage` fields in `measure_info.json` describe only each measure's *most recent* release, so how badly a measure-only join misleads depends entirely on which files you are reading:

| Reading | Observations | Measure-only join correct |
|---|---|---|
| `*_latest.csv.gz` (one row per geography × measure) | 337,269 | 93% |
| `county_rates.csv.gz` (the full time series) | 3,232,772 | 11% |

The latest-value files mostly hold each measure's newest release, so the measure-level fields are usually right there — but the ~7% they get wrong are the small counties suppressed in recent releases and carried forward from older ones, which is exactly where a confidently wrong year does the most damage. Across a full time series the same shortcut is wrong nine times out of ten.

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

**Check `display_status` before presenting a measure.** Not every measure in the catalog is a live one, and nothing in a value itself says otherwise. It is declared on every measure in `measure_info.json` — never omitted, so an absent field is a defect and not a `primary` — and copied onto the registry:

| `display_status` | Meaning |
|---|---|
| `primary` | A current measure. Show it normally. |
| `historical` | The upstream source is gone and the series is closed — it will never gain another year. The observations are real and kept for comparison, but its newest value is not a current reading and must not be shown as one. |
| `qa-only` | A pipeline diagnostic rather than a health measure (how provisional a month's counts are). Useful for judging the data; not for the public measure list. |

Each measure's own `long_description` says why it carries a non-`primary` status.

**Check `chartable` before drawing any chart for a measure.** 32 measures carry `"chartable": false` in `measure_info.json`, meaning **show no charts at all** — neither the time series nor the county-comparison dots. Show the value on its own instead. An absent value means chartable, so only the exceptions are declared.

They fall into three groups, all reviewed measure by measure:

| Group | Count | Why |
|---|---|---|
| Not a quantity | 7 | The value is a code, not an amount: `ahrf_rural_urban_code` (RUCC 1–9), the three `ahrf_hpsa_*` designations (`0=none, 1=whole county, 2=partial`), `noaa_heat_risk_score` (0–4 category), and the two `wapo_met_herd_immunity_*` flags. A county reading `7` for rurality is more rural than one reading `3`, but the midpoint of two categories is not a value, and a state "average rurality" of `4.6` does not exist. |
| Single-state supplement | 17 | CHR&R's `_fl`, `_ny` and `_wi` extras cover one state's counties only, so a comparison would silently mean "other counties in that state". |
| Fragment | 8 | Too few counties for a chart to say anything — `chr_drug_arrests` has 2, `chr_child_abuse` 3, `chr_w_2_enrollment` 6. |

`duplicate_group` marks measures covering the same concept from different sources, so a reader sees one concept rather than several unrelated-looking rows. Like `display_status`, it is declared in `measure_info.json` and copied onto the registry — but only where a cluster has been confirmed against measured values, so an absent `duplicate_group` means ungrouped. The registry fills that gap with the measure's own id, so counting distinct `duplicate_group` values gives the number of concepts in the catalog. Grouping is not merging: members are deliberately kept as separate series and are not interchangeable, and the `duplicate_note` on each records how it differs from its siblings.

---

## Categories

| Category | Subcategories |
|---|---|
| `chronic_disease` | `cancer`, `cardiovascular_metabolic`, `musculoskeletal`, `neurological`, `other_chronic_conditions`, `respiratory_disease` |
| `environmental_health` | `air_and_water_quality`, `other_environmental_hazards` |
| `infectious_disease` | `hiv_and_sexually_transmitted_infections`, `respiratory_infections`, `vaccine_preventable_disease` |
| `injury_and_violence` | `firearm_injury`, `motor_vehicle_crashes`, `suicide_and_self_harm`, `unintentional_injury`, `violence_and_crime` |
| `maternal_and_infant_health` | `birth_outcomes_and_fertility`, `infant_and_child_mortality` |
| `mental_health` | `mental_health_care_access`, `mental_health_conditions`, `mental_health_status`, `social_connection` |
| `overall_health_status_and_mortality` | `length_and_quality_of_life`, `mortality_data_and_completeness` |
| `population_demographics` | `age_structure`, `disability`, `population_size_and_density`, `race_and_ethnicity`, `sex` |
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
