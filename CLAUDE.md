# CLAUDE.md

## Project Overview

**Study 3** of a Stage 1 Programmatic Registered Report (Ballou et al., "Psychological Wellbeing, Sleep, and Video Gaming: Analyses of Comprehensive Digital Traces"). The full registered report contains three studies; this repo implements only **Study 3: Game Genres and Wellbeing**.

The manuscript title is: *"Playtime–wellbeing associations are practically null and vary little across video game genres"* (decision 10B, 2026-10-14).

The study examines whether genre-level playtime (from digital trace data) relates to mental wellbeing, using multi-platform data from the Open Play longitudinal study (Nintendo, Xbox, Steam).

**Authors:** Thomas Hakman (lead/corresponding), Nick Ballou, Tamás Andrei Földes, Matti Vuorre, Kristoffer Magnusson
**Affiliations:** Oxford Internet Institute, Tilburg University, Karolinska Institute

**Pre-registration PDF:** `pre-registration/Ballou_etal_IPA (1).pdf`
**Pre-registration code (synthetic data):** `pre-registration/4_genres.qmd`
**Open Play data paper:** `reference/open_play_v1.3.0/index.qmd` (dataset descriptor) and `reference/open_play_v1.3.0/data-process.qmd` (cleaning pipeline), copied from the v1.3.0 archive (local only)
**Demographics paper:** `demographics paper/index.qmd` (Ballou, descriptive analysis using same data + genres)
**Earlier iteration:** `/Users/thomashakman/Projects/Academic/open-play-genres/` (previous repo structure, same analysis)

## Key Context: Open Play Data Paper

The Open Play data paper was published first and documents what actually happened during data collection. The **clean data files** that the Makefile downloads (`data/clean/`) are the output of the release's `data-process.qmd` (copy in `reference/open_play_v1.3.0/`). Critical things the data paper reveals:

### What the clean data already has
The following pre-registered exclusions are **already applied** in the clean data before this repo's analysis code runs:
- Sessions > 8 hours (480 min) are already excluded for Xbox and Nintendo
- Steam sessions > 480 minutes filtered; hourly totals >60min proportionally scaled
- 16-hour daily playtime cap already applied (days exceeding 16h removed from all platforms)
- Future-dated sessions excluded (Nintendo: `session_start < time_of_pull`)
- Xbox overlapping sessions resolved (merge adjacent, resolve concurrent titles)
- Survey attention check failures removed (`!bangs_failed_att_check` for biweekly, `!bpnsfs_failed_att_check` for daily)
- Duplicate/miscoded survey entries removed

### Wellbeing measure clarification
The pre-registration text says "WEMWBS" (Tennant et al., 2007) but the Open Play data paper confirms the actual measure is the **short form SWEMWBS** (7 items, each scored 1–5 on a Likert scale). The biweekly survey columns are `wemwbs_1` through `wemwbs_7` in `data/clean/survey_biweekly.csv.gz`.

### SWEMWBS scale: use rowMeans, NOT rowSums

**`R/01_preprocess.R` computes `wemwbs = rowMeans(across(starts_with("wemwbs_")))`** — the **item-mean on a 1–5 scale**, not the summed 7–35 score. Do not change this to `rowSums` without updating the SESOI and all downstream interpretations.

**Why 1–5 not 7–35:** the pre-registered SESOI of 0.06 per hour/day is defined on the 1–5 item-mean scale, explicitly derived in Ballou, Sewall et al. (2024) as "0.3 item-mean points minimally important difference ÷ 5 hours of realistic daily leisure = 0.06 per hour." The pre-registration's own precision analysis in `pre-registration/4_genres.qmd` line 334 also assumes a within-person SD of 0.7, which only makes sense on the 1–5 scale (on 7–35 the typical within-person SD is 3–4 summed points). An earlier version of this project used `rowSums` and was applying the SESOI on the wrong scale by a factor of 7.

**Priors: all brms defaults since 2026-10-13 (Matti: "defaults are fine"; "going beyond default priors is counterproductive"):**
- Every brms model (M1–M4, the demographic refits, all daily models) uses the brms default priors: flat on `b`, `student_t(3, round(median(y), 1), S)` on the Intercept, half-`student_t(3, 0, S)` on sigma and every `sd` (including the M4/M4-D mm-group sd, σ_s), LKJ(1) on correlations, with `S = max(2.5, round(mad(y), 1))` (2.5 for SWEMWBS on 1–5; set by brms from life_sat for the daily models). No `set_prior()` on `b`, `Intercept` or `sd` anywhere.
- M3/M3-D are pure brms since 2026-10-14 (non-centred form, no stanvars, no `set_prior()`): `wemwbs ~ sum_within + sum_between + (1 | pid) + (1 | mm(gW_1, ..., gW_14, weights = cbind(gh_*_within), scale = FALSE)) + (1 | mm(gB_1, ..., gB_14, weights = cbind(gh_*_between), scale = FALSE))`, where `gW_k`/`gB_k` are constant genre-factor columns (14 levels) and the weights are the exposures themselves (`scale = FALSE` is essential; within weights are signed). This is the same model as beta_g ~ Normal(gamma, tau): gamma = `b_sum_within`/`b_sum_between` (flat default), tau = `sd_<mm group>__Intercept` (default half-Student-t(3, 0, S); `tau_prior_scale` in chunk `h2-hier-fit` is read from `brms::default_prior()` and pinned at 2.5), and the per-genre coefficients are beta_g = b_sum + `r_<mm group>[g,Intercept]`, computed draw-wise by `hier_nc_draws()` (chunk `h2-hier-fit`; object `h2_hier_nc`; also used for M3-D in `daily-fits`). brms samples r = tau * z, which removes the funnel: the centred stanvars fits (`models/h2_hier_model_v3`, 68 divergences at adapt_delta 0.999; `models/daily/m3_daily_ls_v3`, 29 at 0.9995) are kept for comparison only (`notes/compare_m3_v3_v4.R`; the v1.3.0 refit moves them to `models/archive_v126/` and `models/daily/archive_v126/`); both v4 fits run at adapt_delta 0.999. The only prior that moves is the default Intercept prior, which brms now places at the mean summed exposures with all genre deviations at zero.
- No prior-sensitivity analysis (dropped from Appendix D and from the refit driver, now `scripts/refit_v130.sh`); `R/03_prior_sensitivity.R` is superseded (stops on its first line).
- History: until 2026-10-13 the priors were `student_t(3, 0, 0.5)` on b, `student_t(3, 3, 2)` on the Intercept, Half-Normal(0, 0.1) on τ, Normal(0, 0.3) on the mm sd (daily: these scales times r = SESOI_LS / 0.06). Disclosed in Appendix F (Priors) and D3 (after results were known).
- M3 centres (since 2026-10-13, after Matti's comment C82): the genre coefficients are drawn from Normal(gamma_W, tau_within) and Normal(gamma_B, tau_between), with the centres estimated (v4 variables: gamma = `b_sum_*`, tau = `sd_<mm group>__Intercept`; the v3 names `mu_genre_*`/`tau_genre_*` exist only in the archived centred fit) (flat prior since the default switch). Previously the centres were fixed at zero. Fit files renamed so an older fit cannot be loaded: `models/h2_hier_model_v3` (was `_v2`), `models/daily/m3_daily_ls_v3` (was `_v2`), and since 2026-10-14 (non-centred form) `models/h2_hier_model_v4` and `models/daily/m3_daily_ls_v4`, the files the manuscript, `R/05_loo.R`, the supplement and `scripts/refit_v130.sh` use. `tau_share` (heterogeneity rule) depends on tau only; `tau_rope_out`/`tau_rope_out_b` use the estimated mu (`rope_out_mu()` in chunk `h2-hier-tau`)

**Scale-related code changes elsewhere:**
- `manuscript.qmd` line 881 previously had `filter(..., wemwbs >= 7)` which would silently drop every observation on the 1–5 scale — corrected to `wemwbs >= 1`
- All hardcoded ROPE bounds (`±0.06`) in plotting code remain correct under the scale correction because coefficients are now on the same scale as the SESOI
- Typical wemwbs values after rowMeans: min ≈ 1.0, max = 5.0, mean ≈ 3.32, SD ≈ 0.75 (verified as a preflight check during the Phase X scale correction)

### Clean data column names

**`survey_biweekly.csv.gz`**: `pid`, `wave`, `date`, `wemwbs_1`–`wemwbs_7` (`ideal_baseline_day` is not shipped since v1.2.5; `R/00_baseline_days.R` rebuilds it from the release's raw biweekly file `data/raw/survey_biweekly_raw.csv.gz` as `data/reference/baseline_days.csv`, joined in `load_survey_data()`), plus other measures (depression, life satisfaction, BANGS, displacement, self-reported playtime).

**`nintendo.csv.gz`**: `pid`, `title_id`, `session_start`, `session_end`, `duration`, `device_type`, `operation_mode`. No genre column — must be fetched from IGDB by `title_id`.

**`xbox.csv.gz`**: `pid`, `title_id`, `session_start`, `session_end`, `duration`, `genres`, `title_placement`, plus age ratings. **Xbox already has a `genres` column** (platform-provided), mapped to IGDB taxonomy per Appendix B. `title_id` is an anonymized random identifier for third-party games.

**`steam.csv.gz`**: `pid`, `steam_id`, `title_id`, `approximate_session_start`, `approximate_session_end`, `minutes`, `datetime_hour_start`, `timestamp`, `date`, `hour`, `playtime_forever`, `playtime_2weeks`, `game_ref`. No genre — must be fetched from IGDB by `steam_id` or `title_id`.

**`ios.csv.gz`** / **`android.csv.gz`**: `pid`, `platform`, `day_local`, `minutes`. **Daily aggregates only** — no game titles, no genres. Can contribute to H1 (total playtime) but NOT to H2 (genre-level analysis).

### Deviations from pre-registration (documented in data paper)
- **Age range**: Pre-reg said 18–75 (UK) and 18–30 (US). Actual screening: 18–40 across both regions.
- **Platform coverage threshold**: Pre-reg said 75% of play on included platforms. Actual: 50%.
- **Daily survey timing**: Pre-reg said 7pm. Actual: 2pm local time.
- **Android data**: Pre-reg planned ActivityWatch JSON exports. Actual: screenshots from Digital Wellbeing (like iOS), yielding daily aggregates only.
- **iOS/Android granularity**: Both provide only daily total gaming minutes (no game-level data), limiting them to H1 contribution only.

## Pre-Registered Hypotheses

- **H1:** Total cross-platform playtime is not meaningfully associated with fluctuations in general mental wellbeing over a 2-week period (H1a, "within-person") or with average wellbeing over the full study period (H1b, "between-person"). Tested via equivalence test with SESOI = ±0.06 WEMWBS scale points per 1-hour change in daily playtime, using 90% CIs.
- **H2:** Genres differ in how playtime relates to fluctuations in general mental wellbeing over a 2-week period (H2a, "within-person") and to average wellbeing over the full study period (H2b, "between-person"). Tested via joint Wald test on genre-specific within/between coefficients.

## Pre-Registered Analysis Plan (Study 3 Design Table)

### H1 Model
Multilevel within-between linear regression: total playtime (within- and between-centered) predicts WEMWBS. Random intercept + random slope for within-person playtime.

```r
lmer(wemwbs ~ total_time_within + total_time_between + (1 + total_time_within | pid))
```

Inference: equivalence test using 90% CI bounds against ±0.06 SESOI (see decision grid in pre-reg Design Table 3).

### H2 Model
Multilevel within-between linear regression: per-genre playtime (within- and between-centered) predicts WEMWBS. Random intercept + random slopes for within-person variables, **correlation between random intercept and slopes fixed to 0** (due to identifiability).

```r
lmer(wemwbs ~ {genre_within_vars} + {genre_between_vars} + (1 + {genre_within_vars} || pid))
```

Inference: joint Wald test via `car::linearHypothesis()` testing whether all genre coefficients are equal. If p < .05, conclude at least one genre pair differs. Visualization via caterpillar plot with corrected CIs. Do NOT interpret individual genre differences without formal post-hoc tests.

### Positive Controls (Prerequisites)
1. Significant positive correlation between self-reported and digital trace playtime
2. No overlapping sessions for a given individual on Nintendo or Xbox; no >60min Steam playtime between hourly measurements
3. (Study 3-specific) Significantly higher shooter playtime for men vs. women (d = .3)

### Exclusion Criteria
- Sessions > 8 hours ✅ already in clean data
- Daily total > 16 hours across all platforms ✅ already in clean data
- Future-dated sessions ✅ already in clean data
- Attention check: duplicated survey items differing by >1 scale point ✅ already in clean data
- Missing data: multiple imputation via `mice` package (predictive mean matching, wide format). Report both complete-case and imputed results. ❌ not yet implemented

### Platforms
- H1: all 5 platforms (Nintendo, Xbox, Steam, iOS, Android) — iOS/Android contribute daily totals only
- H2: Nintendo, Xbox, Steam only (iOS/Android have no game-level data; pre-reg also excludes iOS)

## Major Analysis Deviation: Multi-Genre Assignment

**Decision (2026-03-16):** The main analysis deviates from the pre-registration by assigning ALL IGDB genres to each game (`MAX_GENRES_PER_GAME <- 20L` in `R/01_preprocess.R`; the manuscript never claims "up to three"; 46.5% of game-platform pairs carry one label, 29.1% two, 17.5% three, 6.9% four or more), rather than only the primary (first) genre.

### Rationale
Many games span multiple genres in IGDB (e.g., an action-RPG, a strategy-adventure). Using only the primary genre discards meaningful classification information and may introduce bias depending on IGDB's arbitrary ordering of genres.

### Implementation
- `R/01_preprocess.R` — new main pipeline (multi-genre)
- `R/01_preprocess_prereg.R` — frozen pre-registered pipeline (primary genre only; still reads `ideal_baseline_day` and fails on releases >= v1.2.5, v1.3.0 included, without the sidecar join)
- The pre-registered analysis will appear in supplementary materials

### Structural consequences
- Sessions for multi-genre games appear once per genre in the long-format telemetry (full playtime per genre, not fractional)
- Genre playtime columns are **not mutually exclusive** — summing across genres exceeds actual total played time
- Total playtime (for H1) comes from `total_playtime.csv`, computed from raw sessions **before** the genre join (no double-counting)
- Output format changed from **wide** (`time_{genre}` columns per row) to **long** (`pid, wave, genre, hours_per_day`)

### Deviation documentation (for manuscript)
This deviation must be clearly documented in the manuscript's Methods section under a "Deviations from Pre-Registration" subsection. Key points to cover:
1. Primary genre only vs. all genres (up to 3)
2. Why: IGDB multi-genre assignments reflect genuine cross-genre games
3. Consequence: non-exclusive playtime counts; total playtime computed separately
4. Pre-registered analyses (primary-genre attribution, all-platform H1) are reported in manuscript Appendix D, "Preregistered Frequentist Analysis" (`@tbl-frequentist-registered`), built by chunk `frequentist-registered` from the `R/prep_primary_genre.R` output (`01_preprocess_prereg.R` is frozen and unused: its taxonomy differs)

## Discrepancies Between Pre-Registration and Current Manuscript

| Issue | Pre-Registration | Current Status |
|---|---|---|
| **Genre assignment** | Primary genre only | ⚠️ **DEVIATION** — all genres up to 3; see above |
| Session exclusion threshold | >8 hours | ✅ Already in clean data |
| Wellbeing measure | "WEMWBS" | ℹ️ Actual measure is SWEMWBS (7-item short form) |
| H1 equivalence CI level | 90% CI | ✅ Fixed — `conf_level = 0.90` |
| H2 random effects | Random slopes `(\|\| pid)` | ⚠️ Pre-reg requires attempting; document if singular |
| H1 platforms | All 5 | ℹ️ Main H1 uses Nintendo/Xbox/Steam (D4); the registered all-platform H1 model (mobile joined to the survey frame) is reported in Appendix D (`@tbl-frequentist-registered`) |
| Wave assignment | Participant-specific `ideal_baseline_day` | ✅ Fixed — uses `ideal_baseline_day` from the committed sidecar `data/reference/baseline_days.csv`, rebuilt by `R/00_baseline_days.R` from the release's own raw biweekly file (the clean files lack the column since v1.2.5; no v1.2.1 dependency) |
| Missing data imputation | `mice`, complete-case + imputed | ❌ Not yet implemented |
| Positive controls | 3 tests required | ✅ Implemented in manuscript |
| 16h daily cap | Required | ✅ Already in clean data |
| Attention checks | Required | ✅ Already in clean data |

## Repository Structure

```
manuscript.qmd                      # Main Quarto manuscript (intro, methods, analysis code, discussion)
bibliography.bib                    # BibTeX references
_quarto.yml                         # Quarto project config
Makefile                            # Downloads Open Play v1.3.0 (Zenodo 23419571) into data/clean/ (+ raw biweekly file into data/raw/)
R/
  00_baseline_days.R                # Baseline-day sidecar from the release's raw biweekly file -> data/reference/baseline_days.csv (run once after make data)
  01_preprocess.R                   # MAIN: Multi-genre preprocessing (deviation — all IGDB genres up to 3)
  01_preprocess_prereg.R            # FROZEN: Pre-registered version (older taxonomy; unused)
  prep_primary_genre.R              # Primary-genre attribution (preregistered rule) -> data/processed/genre_wave_long_primary.csv (Appendix D)
  helpers.R                         # Table formatting utilities
data/
  clean/                            # Open Play clean data (downloaded via Makefile; includes game_metadata.csv.gz)
  processed/                        # Outputs of 01_preprocess.R (multi-genre pipeline)
    genre_wave_long.csv             #   Long format: (pid, wave, genre, hours_per_day) — sessions count per genre
    total_playtime.csv              #   (pid, wave, total_hours_per_day) — raw sessions, no double-counting
    game_metadata_long.csv          #   (original_name, platform, genre, n_genres_valid) — genre lookup table
  raw/                              # survey_biweekly_raw.csv.gz from the release (input of R/00_baseline_days.R)
  reference/                        # baseline_days.csv (tracked)
pre-registration/
  4_genres.qmd                      # Original pre-registration notebook (synthetic data)
  Ballou_etal_IPA (1).pdf           # Full Stage 1 Registered Report PDF
reference/open_play_v1.3.0/         # LOCAL ONLY: README, codebook, index.qmd (data paper) and data-process.qmd copied from the v1.3.0 archive
demographics paper/
  index.qmd                         # Demographics descriptive paper (Ballou) — uses same data + genres
  references.bib                    # Bibliography for demographics paper
_extensions/                        # Quarto typst preprint extension (mvuorre/preprint)
renv.lock                           # R dependency lockfile (incl. cmdstanr from the Stan R-universe)
.Rprofile                           # Activates renv
.gitignore                          # Ignores data (except data/reference and the sim_recovery CSVs), models, caches, notes, local folders
docs/                               # GitHub Pages output: index.html, manuscript.{docx,pdf}, manuscript_v43.{docx,pdf,html}
models/                             # LOCAL ONLY (22 GB): current fits; archive_v121/, archive_v126/, archive_pre_wave7/ and daily/archive_* hold earlier fits
notes/                              # LOCAL ONLY: working documents, review plans, checklists, internal_2026-04/
literature/                         # LOCAL ONLY: Zotero digests (see Literature section)
reviews/coauthor_docx/              # LOCAL ONLY: co-author Word copies with comments (v3 to v4.2-draft, Tamás/Nick edits)
archive/                            # LOCAL ONLY: superseded documents, old renders, dev scripts; see archive/README.md and MANIFEST.tsv
data/archive/                       # LOCAL ONLY: earlier releases and pipeline outputs (v1.1.0 extract, clean/processed v1.2.1 and v1.2.6, the v1.3.0 zip)
```

Clean-up of 2026-10-18: nothing was deleted; superseded material was moved into `archive/`, `reviews/`,
`reference/` and `data/archive/` (all gitignored) with a manifest. Root build artefacts that Quarto
regenerates (`manuscript_files/`, `manuscript_v43_files/`, the two caches) stay where Quarto expects them.
`manuscript_v43.qmd` is not in the `_quarto.yml` render list, so its outputs land in the repo root and
are moved into `docs/` by hand after each render (its html output file is `manuscript_v43.html`).

## Data Pipeline

1. **Download data** — `make data` downloads [Open Play v1.3.0 from Zenodo](https://zenodo.org/records/23419571) (~200MB ZIP), extracts it, and copies the clean data files (including `game_metadata.csv.gz`) to `data/clean/` and the raw biweekly survey file to `data/raw/survey_biweekly_raw.csv.gz`. The clean files already have pre-registered exclusions applied. Then run `Rscript R/00_baseline_days.R` once: it rebuilds `data/reference/baseline_days.csv` from the raw file and stops unless it reproduces the clean biweekly file row for row. Source repo: [digital-wellbeing/open-play](https://github.com/digital-wellbeing/open-play).
2. **Preprocess (main)** — `Rscript R/01_preprocess.R` (multi-genre deviation). Expands `game_metadata.csv.gz` genres to long format (up to 3 genres per game), joins to telemetry, assigns waves, and aggregates. Outputs to `data/processed/`:
   - `genre_wave_long.csv` — `(pid, wave, genre, hours_per_day)` long format
   - `total_playtime.csv` — `(pid, wave, total_hours_per_day)` without double-counting
   - `game_metadata_long.csv` — genre lookup table
2b. **Primary-genre attribution** — `Rscript R/prep_primary_genre.R` (sources `01_preprocess.R`; same taxonomy, sample and waves, each game's playtime to its first valid genre only) → `data/processed/genre_wave_long_primary.csv`, used by chunk `frequentist-registered` (Appendix D table of preregistered frequentist analyses). `scripts/refit_v130.sh` reruns it (stage `prep_primary`) whenever the main processed files are newer.
3. **Preprocess (pre-reg, supplementary)** — `Rscript R/01_preprocess_prereg.R`. Primary genre only. Output: `data/aggregated_playtime_prereg.csv`.
4. **Render** — `quarto render manuscript.qmd`.

**Note:** All genre data comes from the Zenodo release. See [`R/label_genres.R` in the open-play repo](https://github.com/digital-wellbeing/open-play/blob/main/R/label_genres.R) for how `game_metadata.csv.gz` was produced.

### Genre pipeline: single source of truth

`game_metadata.csv.gz` (from the Open Play Zenodo release) is the **single source of truth** for genre labels across all platforms. It was produced by [`R/label_genres.R`](https://github.com/digital-wellbeing/open-play) in the open-play repo, which:
- Fetched IGDB genres for Steam (by Steam app ID, then name fallback) and Nintendo (by name)
- Mapped Xbox's platform-provided genres to IGDB equivalents via an explicit mapping table
- The Xbox→IGDB mapping in `label_genres.R` matches the pre-registration Appendix B

Our `01_preprocess.R` applies **one additional layer**: collapsing IGDB sub-genres per the pre-registration. This is done by `standardize_igdb_genre()` uniformly across all platforms:
- Hack and slash/Beat 'em up → Action
- TBS, RTS, Tactical → Strategy
- Point-and-click, Visual Novel → Adventure
- Quiz/Trivia → Puzzle
- All other IGDB genres kept as-is (Indie, Music, MOBA, Card & Board Game, etc.)

### Genre collapsing: pre-registration vs demographics paper

The demographics paper's `clean_genre()` collapses genres more aggressively. **This repo uses the pre-registration mapping**, which keeps genres granular:

| Raw IGDB Genre | Pre-reg mapping (this repo) | Demographics paper |
|---|---|---|
| Indie | Kept as "Indie" | **Excluded (NA)** |
| Music | Kept as "Music" | Arcade |
| Pinball | (not handled) | Arcade |
| MOBA | Kept as "MOBA" | Strategy |
| Card & Board Game | Kept as "Card & Board Game" | Puzzle |

## Lessons from Demographics Paper and Earlier `open-play-genres` Project

### Data loading: Zenodo ZIP vs GitHub raw files
The demographics paper downloads the **full Zenodo archive** (v1.1.0, ~194MB ZIP) which contains `game_metadata.csv.gz` plus `R/helpers.R`. The current Makefile downloads individual files from GitHub v1.0.0 raw URLs which may not include `game_metadata.csv.gz`. **Decision needed:** either (a) switch to Zenodo ZIP approach (simpler, includes everything), or (b) add `game_metadata.csv.gz` to the Makefile's download list and bump to v1.1.0.

### Genre pipeline simplification
The demographics paper's genre pipeline is much simpler than the current repo's:
1. Load `game_metadata.csv.gz` (pre-fetched IGDB genres for all Steam/Nintendo games, plus Xbox genres)
2. Join `original_name` from metadata to `title_id` in telemetry
3. Apply `clean_genre()` to collapse sub-genres
4. Done — no IGDB API calls needed

This means `R/01_fetch_igdb.R` is **entirely unnecessary** if `game_metadata.csv.gz` is available. The IGDB genre data was already fetched and released as part of the Open Play dataset. The current repo's approach of calling the IGDB API is redundant.

### Reference manuscript: `archive/manuscript_versions/papers/genres/index.qmd` (earlier repository structure, March 2026; archived 2026-10-18)
This is a polished earlier version of the same analysis with proper structure:
- Sources `01_preprocess.R` at the top via `source(here("papers/genres/R/01_preprocess.R"))`
- Calls `preprocess_genre_data()` which runs the full pipeline and returns aggregated data
- Caches result to `data/aggregated_playtime.csv` to avoid re-running
- Uses `here::i_am()` for path resolution
- Clean chunk organization with descriptive labels
- Proper caterpillar plots for both within-person and between-person effects
- Includes precision analysis section
- Has both `preprint-typst` and `html` format outputs
- Properly names the wellbeing measure as SWEMWBS
- Correctly describes genre classification methodology (matching rates: 93.7% Steam, 89.8% Nintendo)
- Appendix B genre mapping table built in

### Manuscript structure from the reference
The `open-play-genres` manuscript follows this structure (which the current `manuscript.qmd` should adopt):
1. **Setup** (libraries, `source()` preprocessing, data load/cache)
2. **Descriptive Statistics** (N participants, N observations, genre means table)
3. **H1 Model** (REWB with random slopes, `bobyqa` optimizer)
4. **H1 Equivalence Test** (with proper results table)
5. **H2 Model** (genre-specific REWB, random intercepts)
6. **H2 Joint Hypothesis Tests** (within-person and between-person separately)
7. **H2 Visualization** (caterpillar plot with corrected CIs, equivalence bounds)
8. **Between-Person Effects** (separate caterpillar plot)
9. **Sensitivity: Random Slopes** (attempted with `|| pid`, documented failure)
10. **Precision Analysis** (simulation-based)
11. **Discussion**
12. **Appendix A** (full model outputs)
13. **Appendix B** (genre mapping table)

### Key code patterns from reference manuscript
- Uses `lmerControl(optimizer = "bobyqa")` for model fitting
- Extracts coefficients via `broom.mixed::tidy(model, conf.int = TRUE)`
- Multiplicity correction: `confint(glht(model, linfct = paste0(vars, " = -0.06")), adjusted(type = "bonferroni"))`
- Joint tests: `car::linearHypothesis()` comparing all genres pairwise against first genre
- Data description with inline R: `` `r print_num(n_participants)` ``

## Literature: how to read a paper (zotero-digest, since 2026-09-02)

`literature/genre-paper/INDEX.md` lists every paper in the Zotero collection "genre paper" with a one-line gist; `literature/genre-paper/<citekey>.md` is its digest (design, findings, effect sizes, verbatim quotes with pdf page numbers, relevance to genres and wellbeing, how it can be cited, where manuscript.qmd already cites it). Read in this order and stop as soon as the question is answered:

1. `INDEX.md` to find candidate papers; `python3 scripts/zotero_digest.py find "<terms>"` searches all stored digests in the library, not only this collection.
2. The paper's digest.
3. `python3 scripts/zotero_digest.py text <citekey> --outline`, then `--section <name>` or `--pages A-B` for the part you need (a section is 1-5k tokens; a whole paper 15-30k).
4. `python3 scripts/zotero_digest.py text <citekey> --grep "<number or phrase>"` to verify a specific figure with its pdf page before it goes into the manuscript.
5. The PDF itself only if the text is missing or garbled.

Cite only keys that exist in `bibliography.bib`: run `python3 scripts/zotero_digest.py check` before rendering (it fails on any cited key the .bib lacks and names the Zotero key to add); add a missing paper with `python3 scripts/zotero_digest.py bib <citekey> --append-to bibliography.bib`, never by typing an entry. The `bib` export pastes any Zotero child note (digest text) into the entry as bare lines, which breaks pandoc although `check` passes; after every append run `quarto pandoc -f bibtex -t csljson bibliography.bib -o /dev/null && echo BIB_OK` and strip bare lines (seen 2026-10-12). To add a paper that is not yet in Zotero without an API key, POST translator-format JSON to the desktop app's connector endpoint `http://localhost:23119/connector/saveItems` (headers `X-Zotero-Connector-API-Version: 3`, `Zotero-Allowed-Request: 1`); it lands in the collection selected in the Zotero window.

Digests are model-written (Claude Sonnet 5; model recorded in each digest's frontmatter); treat them as a map and verify numbers with step 4. The tool is two-layered: the project-independent core digest of each paper is stored as a Zotero child note when `ZOTERO_API_KEY` is set (else in `~/.local/share/zotero-digest/notes/`), and the project layer is generated from that note. Regenerate or extend with `python3 scripts/zotero_digest.py run` (config in `zotero-digest.json`; needs Zotero running; skips up-to-date papers; `--dry-run`, `--only <citekey>`, `--force`). The script is a copy of the standalone tool at https://github.com/Thomhak/zotero-digest (canonical; update from there). `literature/` is gitignored.

## Data release and sample rule (Open Play v1.3.0, since 2026-10-17)

The study analyses **Open Play v1.3.0** (Zenodo record 23419571, DOI 10.5281/zenodo.23419571,
released 16 Oct 2026). v1.3.0 re-keyed survey and console records to each participant's
canonical identifier, corrected the intake `qualified` flag (79 of the 306 flags revoked in
v1.2.4 were restored) and removed 362 duplicate sign-ups (backend PR
digital-wellbeing/platform-study-rr-backend#10). The sample rule is unchanged:
**participants with `qualified == TRUE` in `data/clean/survey_intake.csv.gz` AND at least one
valid SWEMWBS in waves 1–6**, implemented once as `analytic_pids()` in `R/01_preprocess.R`
(`load_survey_data(pids = analytic_pids())`); every R script and manuscript chunk that reads
survey files goes through it (the daily diary too, in `R/04_daily_aggregate.R`). On v1.3.0 the
sample is **1,668 participants and 6,518 person-waves** (v1.2.6: 1,608 and 6,293).

The baseline-day sidecar `data/reference/baseline_days.csv` (tracked) is rebuilt by
`R/00_baseline_days.R` from the same release's raw biweekly file
(`data/raw/survey_biweekly_raw.csv.gz`, extracted by `make data`) with the rule of Open Play's
`data-process.qmd`. Run it once after `make data`; it stops unless it reproduces the clean
biweekly file row for row. There is no dependency on v1.2.1 any more.

No deviation is recorded for a change of data release (Thomas, 2026-10-17): the paper is built
on the most recent release, which the Methods name (v1.3.0, record 23419571). Deviation D7
(qualified-only sample) and the earlier-sample (v1.2.1) comparison in Appendix D were removed,
together with `R/00_revoked_pids.R`, `R/prep_v121_sample.R` and the reference lists of revoked
and no-intake participants. Local copies of earlier releases and outputs (gitignored):
`data/archive/clean_v121/`, `data/archive/clean_v126/`, `data/archive/processed_v121/`, `data/archive/processed_v126/`.

All brms fits, the imputation, demographic sensitivity, LOO, the daily models and the M4
recovery simulation are regenerated by `scripts/refit_v130.sh` (resumable, memory-guarded,
logged under `~/open-play-render-logs/refit_v130_*`; `REFIT_DRYRUN=1` shows the plan). It first
archives the v1.2.6 outputs once (`models/*.rds` → `models/archive_v126/`, `models/daily/*.rds` →
`models/daily/archive_v126/`, `data/processed/imputation/` and `data/processed/sim_recovery/` →
`data/archive/processed_v126/`). It fits M1–M4 by purling and executing the chunks of `manuscript.qmd`
(`R/fit_main_models.R`); preflight stops unless `manuscript_v43.qmd` has the same chunk labels
and identical chunk code outside the nine known prose/guard chunks (`KNOWN_CHUNK_DIFFS`), so one
set of fits serves both files. It precomputes LOO one fit at a time (`R/05_loo.R` →
`models/loo_*.rds`, read by the `loo-comparison` chunk), reruns the recovery simulation (stage
`sim_recovery`), and ends with cold `--to docx` renders of `manuscript_v43.qmd` and then
`manuscript.qmd`, which are expected to stop on stale `stopifnot` pins; re-pin them from the
post-refit checklist (`notes/post_refit_checklist_v130.md`). Lanes run stages in parallel:
`REFIT_LANE=<name> REFIT_STAGES="..."` starts a helper lane beside the main lane (own lock,
progress log and memory guard; it waits for the main lane's archive and data manifest). A stage
lock keeps a stage from running in two lanes, the main lane skips what a helper lane finished,
and `REFIT_WAIT_FOR="stage:<name> <file>"` delays a lane. Until that run, every fitted number in
the manuscript (and the fit-dependent pins) is still a v1.2.6 value; data-only numbers (sample,
descriptives, missingness, the abstract hours and titles, the lme4 preregistered tests) are already
v1.3.0. The superseded `run_refit.sh` is archived under `archive/scripts_dev/`.

**Stan backend (since 2026-10-17):** every brms fit samples with CmdStan 2.39 through `cmdstanr`
0.9.0 (installed from https://stan-dev.r-universe.dev, not CRAN; `cmdstanr::install_cmdstan()`),
with within-chain parallelisation `brms::threading(3)` (3 threads x 4 chains = the 12 cores of the
M3 Pro). Set once by `options(brms.backend = "cmdstanr", brms.threads = ...)` in the `setup` chunk
(both qmds, identical) and at the top of `R/fit_daily_models.R`, `R/fit_sensitivity_models.R` and
`R/sim_mm_recovery.R`; no `brm()` call carries a `backend`/`threads` argument except the AR(1)
daily refit (`threads = NULL`, because brms refuses threading for ARMA terms). Measured on M3 (one
chain, 200 iterations): 14 min with 3 threads against more than 30 min single-threaded (rstan or
CmdStan), so stages run sequentially on one lane; two lanes would oversubscribe the cores. The
Methods software sentence discloses CmdStan and the threading (`txt_cmdstan_version`). Posterior,
priors and sampler settings are unchanged; only computation time differs.

- **M4 recovery simulation (2026-10-14):** `SIM_REPS=20 SIM_ITER=8000 SIM_RENDER=1 Rscript R/sim_mm_recovery.R` (about 20 min per replication; resumable; refuses saved replications if the four M4 chunks change). Design constants (genre shares, labelled and unlabelled play, missing outcomes) recomputed on v1.3.0 on 2026-10-17. `SIM_REP_RANGE=a:b` restricts a process to replications a..b, so two processes can share the 20; the process that finds all of them on disk writes the summary and the report, the other exits 0. Outputs in `data/processed/sim_recovery/` (`recovery_summary.csv`, `diagnostics.csv`), read by chunk `sim-recovery-summary` with guards (20 reps, coverage ≥ 19/20, 0 divergences). Report `R/sim_mm_recovery_report.html`.

## Build Commands

```bash
make data                           # Download Open Play v1.3.0 from Zenodo (~200MB; clean files + raw biweekly file); then Rscript R/00_baseline_days.R once
REFIT_DRYRUN=1 bash scripts/refit_v130.sh   # refit plan (archive, stages, lanes); changes nothing
Rscript R/01_preprocess.R           # Run preprocessing pipeline (uses game_metadata.csv.gz)
quarto render manuscript.qmd        # Render manuscript (all formats)
quarto render manuscript.qmd --to docx   # Word copy for co-author rounds (docs/manuscript.docx)
python3 scripts/docx_changes.py reviews/coauthor_docx/manuscript_v3.2.docx   # list tracked changes + comments
rm -rf manuscript_cache             # clear knitr cache after ANY data/model/R-script change
quarto preview manuscript.qmd       # Live preview
Rscript -e "renv::restore()"        # Restore R dependencies (lockfile incomplete)
```

## Co-author docx review loop (since 2026-08-31)

- `execute: cache: true` is on globally (knitr chunk cache in `manuscript_cache/`). Prose-only edits re-render in a minute or two; the `setup` and `model-data` chunks are `cache: false` because their side effects (locale, seed, `options()`, `theme_set()`) are not restored from cache. Cached chunks do NOT notice changed input files: run `rm -rf manuscript_cache` before rendering after any change to `data/`, `models/`, or `R/*.R`.
- `docs/manuscript.docx` is a build artefact, overwritten by every render; never edit it in place. Co-author copies live in `reviews/coauthor_docx/` (local only; moved out of `docs/`, the GitHub Pages directory, on 2026-10-18). Extract with `scripts/docx_changes.py`, implement in `manuscript.qmd`, re-render. Word Review → Compare (their `v3.x` vs the fresh render) shows what was implemented.
- `_quarto.yml` post-render must be `./ensure-nojekyll.sh` (Quarto 1.9 does not spawn a bare filename).
- `loo-comparison` is the other memory bomb: computing LOO for the four fits builds draws × observations log-likelihood matrices on top of the loaded fits and memory-killed the machine on 2026-09-01 when a derived qmd (`manuscript_conventional.qmd`) rendered with a cold cache. Never render any of these qmds with a cold/deleted cache wholesale; seed the new cache by copying entries for byte-identical chunks from `manuscript_cache/<format>/` first (knitr keys caches on content hash, so copied entries hit), and only invalidate `loo-comparison` deliberately, ideally overnight with everything else closed.
- The six chunks that load brms fits (`h1-fit`, `h2-fit`, `h2-hier-fit`, `h2-mm-fit`, `daily-fits`, `sensitivity-demographics-bayes`) are `cache: false` on purpose: loading from `models/*.rds` is fast, and caching them made knitr serialise ~6 GB of fit objects per output format, which pushed a 19 GB machine into kernel memory-pressure kills on 2026-08-31 (the render and the Claude Code session both died). Do not re-enable caching on them. knitr keeps one cache per format (`manuscript_cache/{docx,html,typst}`), so `--to docx` only warms the docx cache.

## Known Infrastructure Issues

- **Data not yet downloaded:** `data/clean/` is empty. Run `make data` first (downloads ~200MB from Zenodo).
- **renv lockfile:** Updated with all required packages. Run `renv::restore()` to install.
- **Path inconsistency:** ✅ **Resolved** — Manuscript now sources `01_preprocess.R` and loads real data from `data/clean/`.
- **Co-author roles:** Blank for all co-authors except Hakman.
- **`.Renviron` contains IGDB API secrets** — no longer needed (genres come from Zenodo). Can be deleted.
- **`.gitignore` excludes `*.md` and `R/*`** — CLAUDE.md won't be tracked (fine). `R/*` exclusion means `01_preprocess.R` won't be tracked by git either — may need revisiting.

## Statistical Methods

- Multilevel linear models via `lme4::lmer()` with random intercepts and slopes by participant
- Within-between decomposition via manual person-mean centering (`across()` with `mean()` subtraction)
- Registered H1 rule: Stage 1 decision grid on lme4 Wald 90% CIs via `reg_h1_verdict()` (chunk `frequentist-registered`, Appendix D); see the H1 decision-rules note below
- Joint Wald tests via `car::linearHypothesis()` for H2 (genre coefficient equality)
- Multiplicity correction via `multcomp::glht()` for genre-level CIs in caterpillar plot
- Missing data imputation via `mice` (not yet implemented, required by pre-reg)
- **H1 decision rules (since 2026-10-13):** main text = Bayesian ROPE rule (95% CrI inside ±0.06; Deviation D3). Registered rule = the full Stage 1 Design Table grid on the 90% CI (`reg_h1_verdict()` in chunk `frequentist-registered`: practically significant / may be practically significant / not practically significant, positive or negative; no practically significant association when the CI covers 0 inside ±0.06; inconclusive). On v1.3.0 (lme4, final, 2026-10-17): H1a and H1b both "No practically significant association" (H1b 90% CI [-0.0307, 0.0002], upper bound just above zero); the all-platform H1b likewise [-0.0302, 0.0005]. (On v1.2.6 H1b had been "Negative association, not practically significant".) The all-platform H1b CI includes 0, so it is "No practically significant association". Imputation verdicts use the same function.
- **H2 carries no SESOI verdict (since 2026-10-13):** H2 is answered only by the registered joint Wald tests (h2-wald; on v1.3.0, lme4, final: within p = .025 rejects, between p = .315 does not; primary attribution rejects neither, p = .216 / .284). The spreads (M2 per-draw SD, M3 τ, M4 σ_s) are descriptive: `het_share()` (share/expected number of the 14 genres > 0.06 from the average), `pair_share()` (share of genre pairs > 0.06 apart) and the ROPE share. 0.031 (0.06/1.96) and 0.022 (0.06/(1.96·√2)) are reference values only, never thresholds. Do not reintroduce "practically negligible"/"inconclusive" verdicts for H2.

## Genre Taxonomy

IGDB's genre system is the canonical taxonomy (Appendix A in pre-reg). Games classified by primary (first) IGDB genre. Xbox genres were mapped to IGDB by `label_genres.R` in the open-play repo (matching Appendix B). Sub-genres collapsed by `standardize_igdb_genre()` in `R/01_preprocess.R`: Hack-and-slash → Action, Turn-based/Real-time strategy/Tactical → Strategy, Point-and-click/Visual novel → Adventure, Quiz/Trivia → Puzzle. All other genres kept as-is.

## Coding Conventions

- **Appendix F (since 2026-10-14, decision 3B):** `manuscript.qmd` Appendix F "Model Specifications and Priors" holds the M1–M4 equation blocks and symbol definitions, the M3 non-centred form, the M4 multi-membership mechanics and recovery check, and the priors paragraph with its disclosure; the main-text Methods keep only verbal model descriptions with pointers to Appendix F. If the PCI RR Stage 1 design-table appendix is added later it becomes Appendix G.

- **Terminology (Thomas, 2026-10-13):** write *preregistered* / *preregistration*, never *registered* / *registration* / *unregistered*, for anything that refers to the Stage 1 plan; *Registered Report* is kept only as the article type. Code identifiers (`frequentist-registered`, `reg_h1_verdict`) stay as they are.

- 2-space indentation, tidyverse style, ~100 char lines
- R scripts use `here::here()` for path resolution relative to project root
- Chunk labels use `snake_case` with descriptive names
- Genre variable naming: `time_{genre}` (raw), `time_{genre}_within` / `time_{genre}_between` (demeaned)
- File numbering: `01_`, `02_` for sequential pipeline steps
