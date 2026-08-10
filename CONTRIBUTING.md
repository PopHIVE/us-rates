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
  might report values under a retired FIPS code (see the table in the README's
  [Alaska section](README.md#alaska-historical-borough-and-census-area-changes)),
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
— see the README's [`measure_info.json`](README.md#top-level-measure_infojson)
section for the full field list, `_sources` entry requirements, and the
category/subcategory table. Add the source's own `_sources` entry too if this
is its first measure in this repo.

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
- [ ] Ran the affected script(s) (or `update_all.R --skip-scaffold`) and
      confirmed `check_geography_renaming.R` passes
- [ ] Spot-checked the new measure's values in the written output
