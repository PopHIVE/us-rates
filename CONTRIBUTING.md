# Contributing: Adding a New Data Source

This is the detailed walkthrough for wiring a new data source into the `us-rates`
pipeline. For the folder structure, file formats, and naming conventions the
output must follow, see the main [README](README.md) first — this doc assumes
you've read that.

---

## Where this fits

`us-rates` is the *second* half of a two-repo pipeline:

1. **`Ingest`** (sibling repo, expected at `../Ingest`) downloads a raw source and
   standardizes it into `Ingest/data/{source}/standard/*.csv.gz` (or a
   `bundle_*/dist/*.parquet` file) — wide or tall format, FIPS-coded geography,
   ISO-8601 time. If your source isn't in `Ingest` yet, that has to happen first;
   see `Ingest/CLAUDE.md`'s "Adding a New Data Source" section.
2. **`us-rates`** (this repo) reads those already-standardized files, reshapes
   them into this repo's long format (`geography`, `time`, `measure`, `value`),
   and writes them into the `national/` / `states/` / `territories/` folder tree.

This guide covers step 2 only: a source that already has a `standard/` or `dist/`
file in `Ingest` and just needs to be read into `us-rates`.

---

## Step 1: Decide which geography level(s) the source covers

Look at the `Ingest` standard file(s) for the source — does it carry a national
row (`geography == "00"`), state rows (2-digit `geography`), county rows
(5-digit `geography`), or some combination? That determines which script(s) you
touch:

| Geography level | Script |
|---|---|
| National | `code/populate_national_rates.R` |
| State / territory | `code/populate_state_rates.R` |
| County (incl. territory subdivisions) | `code/populate_county_rates.R` |

Many sources report at all three levels from the same underlying file (e.g.
CHR, Census, CMS MMD, NSSP) — in that case you add a near-identical block to
all three scripts, differing only in the geography filter. Others are
level-specific (e.g. AHRF is county-only; NOAA HeatRisk is state+county but not
national).

---

## Step 2: Read the source and reshape to long format

Every block in `populate_national_rates.R` / `populate_state_rates.R` /
`populate_county_rates.R` follows the same shape: read the `Ingest` file, filter
to the geography level for that script, reshape to `geography, time, measure,
value`, and `select()` down to exactly those four columns. Two source shapes
show up repeatedly:

**Wide format (`vroom` + `pivot_longer`)** — most CHR/Census/CMS-style sources
ship one column per measure:

```r
new_source_long <- vroom(
  file.path(INGEST_PATH, "new_source/standard/data_county.csv.gz"),
  show_col_types = FALSE
) %>%
  filter(!is.na(geography)) %>%
  pivot_longer(
    cols      = -c(geography, time),
    names_to  = "measure",
    values_to = "value"
  ) %>%
  filter(!is.na(value)) %>%
  mutate(measure = paste0("newsrc_", measure))
```

**Already-tall parquet (`read_parquet`)** — `bundle_*/dist/*.parquet` files are
usually already one-row-per-observation, just needing a filter and a `mutate()`
to assign the final `measure` name:

```r
new_source_long <- read_parquet(
  file.path(INGEST_PATH, "bundle_new_category/dist", "new_source.parquet")
) %>%
  filter(!is.na(value), !is.na(geography)) %>%
  mutate(measure = "newsrc_some_measure") %>%
  select(geography, time, measure, value)
```

A few sources need a delimiter or file-quirk override — e.g.
`epic_injury/standard/heat_year_county.csv.gz` is tab-delimited
(`vroom(..., delim = "\t")`); check the actual file rather than assuming CSV.

### Geography

If the source already carries FIPS codes, just filter on `nchar(geography)`
and/or `geography == "00"`. If it reports place *names* instead (common for
national-only sources reporting `"United States"`, or older CDC feeds using
state names), join against the FIPS reference already loaded near the top of
the script — `name_to_fips` in `populate_state_rates.R`, or build the
equivalent in `populate_national_rates.R`:

```r
left_join(name_to_fips, by = c("geography" = "geography_name")) %>%
filter(!is.na(state_fips)) %>%
mutate(geography = state_fips)
```

County-level scripts don't need this — `Ingest` county files are FIPS-coded
already — but double check for non-FIPS placeholder rows some feeds mix in
(see `jhu_measles_long` in `populate_county_rates.R`, which drops anything
where `nchar(geography) != 5`) or state-level values back-filled onto every
county for privacy suppression (see `read_nssp_county()`'s
`!is_state_estimate` filter in the same file).

### Time

Reuse the helpers already defined at the top of each script rather than
writing new ones:

| Helper | Use for |
|---|---|
| `year_end(y)` | A bare year (`2023`) → `2023-12-31` |
| `month_end(d)` | A date that should snap to the last day of its month |
| `mdy_to_date(x)` | `MM-DD-YYYY` strings |
| `as.Date(x)` | Already `YYYY-MM-DD` |

### Measure names

Pick a short source prefix (matching the `{prefix}_{measure_name}` convention
in the README) and either build it with `paste0()` for a family of columns, or
`recode()` for a small fixed set of named measures — both patterns are all
over the existing blocks. Keep the prefix identical across every measure from
that source, across all three scripts, so the same measure lines up at every
geography level.

---

## Step 3: Join it into `combined`

At the bottom of each script, add your new `_long` tibble to the `bind_rows()`
call that builds `combined`:

```r
combined <- bind_rows(
  chr_long, census_long, epic_long, # ...existing sources...
  new_source_long
) %>%
  arrange(geography, time, measure)
```

Do this in every script the source applies to (per Step 1). Nothing past this
point needs to change — the existing per-geography writing loop in each script
picks up any new rows automatically.

---

## Step 4: Watch for the two known edge cases

If your source reports **county-level** data, check whether it could plausibly
touch either of these — both are documented in the README and enforced by
`code/check_geography_renaming.R`:

* **Alaska's renamed/split/merged boroughs and census areas** — if your source
  might report values under a retired FIPS code (see
  [Geography lineages](#geography-lineages-and-how-they-are-resolved) below),
  decide whether to drop the duplicate unconditionally
  (`drop_alaska_defunct_duplicates()`) or need a per-row override
  (`ahrf_alaska_overrides`-style `tribble()`) the way `populate_county_rates.R`
  already does for `vaccine_exemptions_fattah` and `area_health_resource_file`.
* **Connecticut counties vs. planning regions** — if your source could report
  under both the legacy 8-county FIPS codes and the 9 planning-region codes for
  the same `(measure, time)`, that's a double-count. Usually the source itself
  only uses one convention consistently, but confirm rather than assume.

If neither applies, no action needed — `check_geography_renaming.R` will fail
loudly on the next pipeline run if it turns out you were wrong.

Also consider whether the source could produce outright duplicate
`(geography, time, measure)` rows from its own upstream quirks (e.g. NCHS
mortality repeating a couple of Virginia independent-city FIPS mappings) — if
so, add a `distinct(geography, time, measure, .keep_all = TRUE)` the way
`populate_county_rates.R` already does for the whole `combined` table, rather
than a source-specific fix.

---

## Step 5: Document every new measure in `measure_info.json`

Every measure name you introduced needs an entry in the root `measure_info.json`
— see the README's [Measure Documentation](README.md#measure-documentation)
section for the full field list, `_sources` entry requirements, and the
category/subcategory table. Add the source's own `_sources` entry too if this
is its first measure in this repo.

`sources` is ordered **pull-point first**. If you pulled the measure through a
compiler rather than from the producer, the compiler leads and the producer
follows — `"sources": [{ "id": "chr" }, { "id": "brfss" }]`, plus
`"compiled_via": "chr"`. List the producer only when you actually know it;
a compiler-only array is correct otherwise. Getting the order wrong isn't
cosmetic: CHR&R is CC BY 4.0 and requires attribution, so a `chr_` measure
that credits only its public-domain upstream under-credits the one party
whose licence demands it.

---

## Step 6: Run and verify

Make sure `../Ingest` is up to date, then run just the script(s) you changed:

```
Rscript code/populate_state_rates.R
Rscript code/populate_county_rates.R
```

or the whole pipeline (`--skip-scaffold` is safe — you're not adding new
geographies):

```
Rscript code/update_all.R --skip-scaffold
```

Check that:

* `code/check_geography_renaming.R` still passes (it runs as part of
  `update_all.R`, or run it standalone) — a failure here means an Alaska/CT
  overlap you need to resolve per Step 4.
* Your new measure shows up correctly for a spot-checked geography, e.g.:

  ```r
  vroom::vroom("states/california/state_rates.csv.gz") |>
    dplyr::filter(measure == "newsrc_some_measure")
  ```
* The row count message each script prints (`"Combined N rows..."`) went up by
  a plausible amount.

---

## Checklist

- [ ] Confirmed the source's standardized file(s) already exist in `../Ingest`
- [ ] Identified which of national/state/county the source covers
- [ ] Added a read + reshape block to each applicable `populate_*_rates.R`,
      producing `geography, time, measure, value`
- [ ] Used the shared time/geography helpers rather than one-off logic
- [ ] Joined the new tibble into that script's `combined <- bind_rows(...)`
- [ ] Checked for Alaska defunct-FIPS and CT county/planning-region overlap
      (county-level sources only)
- [ ] Added an entry to `measure_info.json` for every new measure name (and a
      `_sources` entry if this source is new to the repo)
- [ ] Ordered `sources` pull-point first, with `compiled_via` set to match
      `sources[0]` for anything pulled through a compiler
- [ ] Ran the affected script(s) (or `update_all.R --skip-scaffold`) and
      confirmed `check_geography_renaming.R` passes
- [ ] Spot-checked the new measure's values in the written output

---

# Reference: pipeline decisions and their rationale

Background for anyone changing the pipeline. None of this is needed to *use*
the data — the README covers that — but each item below records a decision that
is easy to undo by accident.

## The pipeline, step by step

`code/update_all.R` runs these in order. Steps 9-11 write only to `tracker/`,
so a failure there leaves the published data exactly as steps 1-8 wrote it.
Step 9 must precede step 10, which reads `measure_vintages.csv`.

| # | Script | Writes |
|---|---|---|
| 1 | `all_fips.R` | `resources/all_fips.csv.gz`, the FIPS-to-name reference (via `tidycensus`) |
| 2 | `scaffold_structure.R` | any new `states\|territories/{name}/counties/{fips}_{name}/` folders. Safe to re-run; never overwrites. Skip with `--skip-scaffold` |
| 3 | `code/populate_national_rates.R` | `national/national_rates.csv.gz` |
| 4 | `code/populate_state_rates.R` | `states/*/state_rates.csv.gz`, `territories/*/{commonwealth,territory}_rates.csv.gz` |
| 5 | `code/populate_county_rates.R` | `states\|territories/*/counties/*/county_rates.csv.gz` |
| 6 | `code/populate_latest_rates.R` | the `*_latest.csv.gz` cuts — must run after 4 and 5, which it reads |
| 7 | `code/check_geography_renaming.R` | nothing; **fails the build** on a cross-convention double-count |
| 8 | `code/generate_geography_manifest.R` | `us-rates-geographies.json` |
| 9 | `code/build_measure_vintages.R` | `tracker/measure_vintages.csv` |
| 10 | `code/build_measure_registry.R` | `tracker/measure_registry.csv` |
| 11 | `code/qa_audit.R` | `tracker/qa_findings.csv` — the slow step; skip with `--skip-qa` |

## Geography lineages, and how they are resolved

The lineage tables — which retired FIPS code maps to which successor, for both
Alaska and Connecticut — are in the
[README](README.md#geographies-that-changed-over-time), since they're needed to
read the folder tree. What follows is how the pipeline resolves them.

Two sources write to retired Alaska codes rather than cutting over cleanly,
both resolved in `populate_county_rates.R`:

* `vaccine_exemptions_fattah` always writes the identical value to a retired
  code and its successor(s), so the retired copy is dropped unconditionally
  (`drop_alaska_defunct_duplicates()`).
* `area_health_resource_file` sometimes duplicates and sometimes *disagrees*
  between a retired code and its successor(s) for the same `(measure, time)`.
  The disagreements are almost always a new code's placeholder `0` before real
  tracking starts, or a retired code decaying to `0` in its last year or two.
  Each of the 79 affected rows is resolved by an explicit override table
  (`ahrf_alaska_overrides`) rather than a general rule — guessing wrong here
  silently reports the wrong health-workforce count.

**Connecticut** — the 2022 planning-region cutover. The direct Census feeds are
single-current-vintage patches, so any row still on a legacy county code is
stale by definition once the vintage is 2022+; `drop_ct_legacy_duplicates()`
drops those rather than double-reporting the same year under both conventions.

## Direct sources keep their own prefix

Several concepts are available both directly from their producer and through a
compiler that redistributes them. Both are kept, under separate ids
(`pep_population` and `chr_population`, `sahie_pct_uninsured` and
`chr_uninsured`), and neither overwrites the other.

This was originally done the other way — direct values were mapped onto the
matching `chr_` id so they would replace the compiler's. That was wrong, and
the failure is worth remembering: each Census file holds one current-vintage
year, while the compiler's series lags its release year consistently, so a
single spliced point produced a false spike in up to 63% of counties. 2024
median household income jumped ~19% and fell back the next year. Separate ids
remove the conflict entirely — each series is internally consistent and no
precedence rule is needed.

It also keeps coverage honest. Where a compiler still reports legacy geography
codes, the direct pull is the *only* source for the current ones — Connecticut's
planning regions, Alaska's Chugach and Copper River, and Puerto Rico's
municipios, which some compilers do not cover at all.

Corollary for new sources: **never map a direct pull onto a compiler's measure
id.** Give it its own prefix and let `duplicate_group` in the registry record
that the two describe the same concept.

### Adding a duplicate_group

Group on measured values, never on names — measures that look alike from their
ids are routinely methodologically distinct. The screen is: compare the two
across every county and year they both cover, on the year with the most
overlap. One concept correlates near 1 across counties even when its members
use different units, because county-to-county variation is the concept's own
signal.

Two failure modes of that screen, both live in this catalog:

* **Counts all correlate with population.** `acs_POP_I` (infants) and
  `acs_POP_J` (juveniles) reach r = 0.997 and are plainly different concepts.
  For counts, only a value ratio near 1 is evidence.
* **Low-variance shares fail it while being identical.** Female share is ~50%
  in every county, so `chr_female` and `pep_pct_female` correlate at just
  0.945 — with a value ratio of 1.000. Judge those on ratio.

Declare the group on each member in `measure_info.json` — `duplicate_group` with
the group name, `duplicate_note` recording what the check found, with the
numbers. Both are validated at build time in `code/build_measure_registry.R`: a
group of one, a group name colliding with a measure id, and a grouped measure
with no note each fail the build. They are declared there rather than in the
build script because `measure_info.json` is the file consumers read; a group
declared anywhere else cannot be displayed.

Grouping is not merging: members stay separate series and are never
interchangeable.

**Pairs deliberately *not* grouped**, so they are not re-litigated:

* `chr_dentists` / `ahrf_dentists` and `chr_primary_care_physicians` /
  `ahrf_pcp` — r = −0.18 and −0.16. One is a population-per-provider ratio, the
  other a provider count. Inverses of each other, not the same measure.
* `chr_unemployment` / `acs_UMP` — r = 0.638. A rolling 5-year survey estimate
  against a point-in-time administrative rate; too weak to call one concept.
* `chr_income_inequality` / `acs_GNI` — ratio 0.100. A percentile ratio against
  a Gini index: different statistics. `acs_OWS` is the right counterpart.
* `acs_PCT_P` / `pep_pct_aian` (ratio 3.9) and `acs_PCT_P1` / `pep_pct_nhpi`
  (ratio 1.4) — the ACS shares are non-Hispanic-alone and the PEP shares are
  not, so for these two groups the ACS member counts a different population.
  The other four race groups match at ratio 1.0–1.1 and are grouped.

### Marking a measure not chartable

Set `"chartable": false` in `measure_info.json` to suppress **both** charts on
the explore page for that measure. Declare it only where it applies; absence
means chartable, the same convention `duplicate_group` uses.

Three things earn it, and each was reviewed measure by measure:

* **The value is not a quantity** — a classification, designation code, or 0/1
  flag, where the midpoint of two values means nothing.
* **A single-state supplement** — covers one state's counties, so a comparison
  reads as national when it is not.
* **A fragment** — too few counties for a chart to carry meaning.

**Classify from the definition, never from the values.** A data-driven screen
looks tempting -- "few distinct small integers means a code" -- and it is wrong
here. `cms_asthma` shows 12 distinct integers, `cms_schizophrenia` 8, and
`cms_acute_myocardial_infarction` 4, because CMS publishes whole percentages;
they are ordinary rates, coarsely rounded. Fifteen `cms_` measures would be
misclassified by that rule.

**Do not infer it from coverage either.** A rule of "county-only means do not
chart" was tried and was wrong: it caught `census_ur_pct_urban_pop` (3,221
counties across 52 states) and `epic_heat_ed_rate` (3,110 across 50), which
chart perfectly well and merely lack a state roll-up.

Two borderline cases were deliberately left chartable:

* `chr_adverse_climate_events` — "count of thresholds met", 0–3. A genuine
  count, so it behaves like a quantity.
* `chr_drinking_water_violations` — a binary flag from the 2016 release onward
  but a continuous proportion before it. The break is recorded in
  `qa_findings.csv` and in the measure's `long_description` instead.

`chartable` is a different question from `display_status`. `display_status` is
*should this measure be shown at all*; `chartable` is *should it be drawn as a
chart*. A `chartable: false` measure is still shown — as a value, without a
graph.

### Setting display_status

Every measure declares one in `measure_info.json`, never omitted — absent and
`primary` are different things to a consumer, the same reason
`us-rates-geographies.json` publishes `retired` on every entry.

| Value | When |
|---|---|
| `primary` | The default: a live measure, safe to present. |
| `qa-only` | A pipeline diagnostic rather than a health outcome, kept because it is useful for judging how provisional a count is — `nchs_pct_complete`, `nchs_overdose_pct_pending`. |
| `historical` | The upstream is gone, so the series is closed and will never gain another year. |

`historical` is a labelling problem, not a staleness one: nothing in a value
from 2015 says it is the last one, so a closed series presented beside live ones
reads as current. Label rather than delete — the observations are real, and
deleting the three Dartmouth Atlas measures would have destroyed 53,078 of them.
Record *why* the series closed in that measure's `long_description`, including
each ending separately where there is more than one: CHR&R stopped publishing
those three after its 2018 release, **and** the Dartmouth Atlas itself has since
been discontinued, so there is no upstream to migrate to and no ticket to
re-source them.

## Compiler credit

`compiler_first_year`, `compiler_last_year`, and `compiler_citation` on the
registry record that a compiler supplied a measure — which stays true even if
it is later converted to a direct source. `compiled_via` is different: it
tracks who compiles it *now*, and can change.

The columns are generic rather than one set per compiler, since `compiled_via`
already names which one; per-compiler columns would be the same three facts
written twice. The citation year is that measure's own last release, so a
retired measure cites the edition it actually came from rather than the current
one.

## Detecting a mid-series redefinition

A publisher can change what a measure means without any obvious signal. Three
columns in `tracker/measure_vintages.csv` catch different cases, and none of
them catches all three:

* **`format_type`** is the publisher's own display-format code, and it reliably
  flags a **unit** change. `chr_drinking_water_violations` went from a
  percentage (1) to a yes/no indicator (5) between the 2015 and 2016 releases
  while `years_used` stayed *identical* — invisible in the vintage alone. Three
  measures change it: `chr_drinking_water_violations` (2016, 1->5),
  `chr_primary_care_physicians` (2011, 0->3), `chr_drug_overdose_deaths_modeled`
  (2018, 4->6).
* **`description_changed`** is the **only** signal that catches a denominator or
  population-base change. `chr_preventable_hospital_stays` switched from "per
  1,000 Medicare enrollees" to "per 100,000" between the 2018 and 2019 releases
  with `format_type` fixed and `years_used` advancing normally.
* **`vintage`** catches neither on its own.

Most rewordings are cosmetic. Filtering `description_changed` for denominator or
framing wording currently surfaces four real breaks:

| Measure | Release | Break | Handling |
|---|---|---|---|
| `chr_primary_care_physicians` | 2011 | rate -> ratio | corrected in `populate_county_rates.R` |
| `chr_drinking_water_violations` | 2016 | proportion -> binary flag | triaged in `qa_findings.csv`; values stand |
| `chr_preventable_hospital_stays` | 2019 | per 1,000 -> per 100,000 | corrected in `populate_county_rates.R` |
| `chr_diabetes_prevalence` | 2025 | adults 20+ -> adults 18+ | documented in `long_description`; values stand |

The 2025 case is the one to imitate when a new break appears. It changes *who
is counted* rather than what the number means, so no correction applies — the
values are correct as published and the discontinuity is documented instead.
Note also that its step (+5.6% median, 81% of counties up, against +0.7% the
prior release) runs *opposite* to what broadening the age base would produce
alone, so the upstream evidently revised more than the age cut. Record what the
description actually says; don't attribute the whole step to it.

Re-screen `description_changed` whenever a new compiler release lands.

## Labelling breaks rather than repairing values

A run of `qa_audit.R` findings are not defects. `mixed_units_within_series`
compares consecutive observations within a geography, and a genuine
definitional change looks identical to a scale error at that resolution. Before
"fixing" one, check the raw upstream archive: if the stored values match what
the publisher published, the fix is to label the break, not to alter the data.
`flagged_root_causes` in `qa_audit.R` carries the written diagnosis for each
finding already triaged this way, and the `status` column separates the two
kinds: `auto-detected` is a machine guess awaiting triage, `flagged` is a
diagnosis someone confirmed against source.

A flagged entry is emitted whether or not its check still fires. That matters
because the jump check's gates (below) are tuned to suppress ratio noise, and
one verified break — `chr_drinking_water_violations`, whose pre-2016 era is a
genuine near-zero proportion — does not clear them. Verified diagnoses are not
re-suppressed by a heuristic; add the entry and it stays reported.

A real break that trips no threshold at all — a few percent, rather than the
50x jump check — still has no machine-readable home. Those are recorded in the
measure's `long_description` instead.

### Why the jump check has two gates

A bare ratio test does not work, and the reason generalises. A ratio blows up on
a near-zero denominator, so any measure reaching down toward zero — a hazard
index, a sparse case count, a segregation index in a county with almost no
minority population — throws jumps of thousands of x that mean nothing. Run
bare, the check found nothing but that, and a check with no true positives
trains its reader to skip it.

So a jump is reported only if it clears both:

* **Magnitude** — the jumps' median low end, measured against the measure's own
  median *positive* value, is at least `LOW_END_FLOOR`. Moving out of an
  ordinary reading is interesting; moving out of a thousandth of typical is
  arithmetic on noise. (Median over positives, not over all values: several of
  these series are mostly zeros, which would put the reference at 0 and admit
  everything.)
* **Breadth** — at least `MIN_GEOGRAPHIES` distinct geographies show it. Unit
  mixing is systemic; one county jumping once is a data-quality incident.

Neither gate works alone, and neither proves a series is clean — a measure
dropped here may still carry two units, it just has not shown it in a way this
check can distinguish. Signed measures are excluded from the check outright,
since a ratio is undefined across zero; filtering them to their positive half
hides every break in the negative half and manufactures findings out of
ordinary zero-crossings.

### Why the zero-run check needs three gates

A **closure** leaves a trailing run of zeros — the county had a hospital, lost
it, and reports zero from then on. A zero run with positive values on *both*
sides is a different shape entirely, and it is impossible on its own: a county
cannot lose every hospital and then regain them. The check needs no external
reference data to make that judgement, which is what makes it worth running.

But "impossible" only holds at scale, so the check gates three times:

* **Run length** ≥ `MIN_ZERO_RUN`. A one- or two-period gap is a plausible
  reporting lapse.
* **Breadth** ≥ `MIN_RUN_GEOGRAPHIES`, for the same reason the jump check has
  it — one county is an incident, many is a mechanism.
* **Bracket magnitude** ≥ `MIN_BRACKET_VALUE`. This is the gate that does the
  real work. A county with a single rural hospital that closes and is replaced
  years later moves `1 → 0 → 1` legitimately, and that is what most of the
  shape actually is: 44 of 51 `ahrf_hospitals` runs are bracketed by 1. Losing
  **two or more** and later recovering is the shape that does not happen.

Scope is an explicit list of **stock** counts, and it has to be, because the
distinction is semantic and no field we hold encodes it. A bracketed zero run is
ordinary in an *incidence* count — a county records measles cases, then none for
six years, then cases again — so running this over `jhu_measles_cases` or the
`nhtsa_` death counts would report real epidemiology as a defect. The
`acs_POP_*` race and age subgroups are excluded for a related reason: they are
5-year survey *estimates* of small subpopulations, and a rural county estimating
zero Native Hawaiian residents in one vintage and four in the next is sampling
behaviour. Including them produced 105 findings, every one of that kind.

**What the check actually caught, and the lesson in it.** Every surviving
finding is an `ahrf_` count, and the cause is not in this pipeline. AHRF
*retroactively reassigns* facilities between geographies in later editions.
Verified on Henrico County VA (`51087`) against raw HRSA bytes: for the same
data year, 1996, the 1999 edition reads `016` for Henrico and `000` for Richmond
City (`51760`), while the 2005 edition reads `000` for Henrico and `016` for
Richmond City. The 16 Richmond-area hospitals moved from the county to the
independent city. The 1990-vintage variable was left alone by that revision and
still reads `019` for Henrico in both editions — the control that proves a
reassignment rather than a layout shift.

The general form is worth remembering when adding any multi-edition source:
**assembling a series as one point per edition is only safe if the source never
revises earlier years.** Where it does, the series has to be built by *data*
year, taking the newest edition that covers each year. Note the constraint that
makes this non-trivial for AHRF: the recent CSV editions carry only two years
each, so the deep history exists only in the older fixed-width editions and the
series cannot simply be rebuilt from the latest one.

## Watch for a silent rescale when a source updates

The most dangerous change an upstream source can make is to rescale a whole
series at once, because the obvious checks all look elsewhere. When the six ACS
income-share measures moved from 0-100 to 0-1 upstream, `scale_bounds_violation`
stayed silent (0.03 is a legal value on a 0-100 scale) and
`mixed_units_within_series` stayed silent too (it compares consecutive
observations within a geography, and every year had moved by the same factor,
so there was no jump). `measure_info.json` went on declaring `0-100` against
data that was no longer on it.

`scale_magnitude_mismatch` exists to catch exactly this: a measure declared
`0-100` whose maximum never exceeds 1 across the entire catalog. If it fires
after a refresh, **check the upstream source before touching anything** — an
intentional upstream rescale means `measure_info.json` is what needs updating,
not the data. `Ingest/data/census/ingest.R` records the reasoning for its own
rescale in a comment, which is the pattern to follow.

More generally, after any refresh that moves a lot of values, confirm the
change is a *revision* and not a *unit change* before committing: compare a
handful of old and new values and look at the ratio. A constant ratio across
every geography and year — 0.01, 100, 1000 — is a unit change, not new data.

Note that `scale` in this repo is descriptive: it records the scale each source
publishes on, and values are never normalised. Sources split roughly evenly
between the two conventions and each one is internally consistent, so a measure
that disagrees with the rest of its own prefix family is worth a second look.
