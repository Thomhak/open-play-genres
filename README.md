# Playtime–wellbeing associations are practically null and vary little across video game genres

**Thomas Hakman, Matti Vuorre, Nick Ballou, Tamás Andrei Földes, Kristoffer Magnusson, Andrew K. Przybylski**

Oxford Internet Institute · Tilburg University · Karolinska Institute · Imperial College London

---

This repository contains the analysis code and manuscript for Stage 2 of Study 3 from an accepted PCI Registered Reports programmatic registered report (Ballou et al., *Psychological Wellbeing, Sleep, and Video Gaming: Analyses of Comprehensive Digital Traces*). We test whether total cross-platform gaming playtime is meaningfully associated with mental wellbeing (H1), and whether that association varies by game genre (H2), using multi-platform digital trace data and biweekly self-report surveys from the Open Play longitudinal dataset.

**Read the rendered manuscript:** <https://thomhak.github.io/open-play-genres/>
([PDF](https://thomhak.github.io/open-play-genres/manuscript.pdf) · [DOCX](https://thomhak.github.io/open-play-genres/manuscript.docx))

**Stage 1 Registered Report (pre-registration):** <https://osf.io/mvngt/>

## Getting started

The best entry point is the rendered manuscript linked above. Key repository components:

- `manuscript.qmd` — the full manuscript (introduction, methods, analysis code, results, discussion)
- `supplement_model_output.qmd` — supplement with full posterior summaries for the four Bayesian models
- `R/01_preprocess.R` — preprocessing pipeline (multi-genre full attribution)
- `R/02_impute_wemwbs.R` — two-level MICE imputation of SWEMWBS on the person × wave grid
- `models/` — cached model fits (not tracked by git; regenerated on first render)
- `bibliography.bib` — references
- `renv.lock` — R package version specifications

## Data

Gameplay telemetry and survey data are from the **Open Play** longitudinal dataset (v1.2.6), available on Zenodo:

> Ballou, N., et al. (2025). *Open Play: A longitudinal dataset of video game play and psychological wellbeing*. Zenodo. https://doi.org/10.5281/zenodo.22811439 (record https://zenodo.org/records/22811439)

The dataset covers multi-platform gaming telemetry (Nintendo Switch, Xbox, Steam, iOS, Android) and biweekly wellbeing surveys. Data files are not stored in this repository; run `make data` to download them into `data/clean/`. See the [Open Play repository](https://github.com/digital-wellbeing/open-play) for full documentation of the data cleaning pipeline.

The analytic sample is restricted to participants whose intake record is flagged `qualified` in v1.2.6 and who have at least one valid SWEMWBS (`analytic_pids()` in `R/01_preprocess.R`; manuscript Appendix A, Deviation D7). Releases from v1.2.5 on no longer contain the per-participant `ideal_baseline_day` used to assign telemetry to waves, so `R/00_baseline_days.R` writes it once from the v1.2.1 release (record 20119134) to `data/reference/baseline_days.csv`; `R/00_revoked_pids.R` compares the v1.2.1 and v1.2.6 intake files and writes the participant lists in `data/reference/` (tracked in git) that the manuscript uses to report the sample correction. Both scripts read the v1.2.1 clean files from `data/clean_v121/`; `R/00_baseline_days.R` downloads the v1.2.1 release if that folder is absent.

## Reproducing the analysis

**Requirements:** R ≥ 4.5, [renv](https://rstudio.github.io/renv/), [Quarto](https://quarto.org), `wget`, `unzip`

```bash
# 1. Download Open Play v1.2.6 data from Zenodo (~197MB)
make data
Rscript R/00_baseline_days.R          # baseline-day sidecar from v1.2.1 (downloads v1.2.1 if data/clean_v121/ is absent)

# 2. Install R dependencies
Rscript -e "renv::restore()"

# 3. Run preprocessing pipeline
Rscript R/01_preprocess.R
Rscript R/prep_primary_genre.R        # primary-genre attribution (registered rule) for the Appendix D frequentist table
Rscript R/prep_v121_sample.R          # earlier-sample (v1.2.1, Deviation D7) playtime in data/processed_v121/ for the same table (downloads v1.2.1 into data/clean_v121/ if needed; checks, never overwrites, existing files)

# 4. Run the multiple imputation (cached; ~20 min)
Rscript R/02_impute_wemwbs.R

# 5. Fit the models that the manuscript loads from cache rather than fitting itself
Rscript R/04_daily_aggregate.R        # daily-diary exposure frame (exploratory analysis)
Rscript R/fit_daily_models.R bridge   # daily SESOI transfer + biweekly life-satisfaction comparison
Rscript R/fit_daily_models.R rest     # M1-D, M3-D and the M1-D sensitivity refits
Rscript R/fit_daily_models.R m2       # M2-D
Rscript R/fit_daily_models.R mm       # M4-D (multi-membership; longest)
Rscript R/fit_daily_models.R dyn      # AR(1) and window-length sensitivities
Rscript R/fit_sensitivity_models.R    # demographic sensitivity models (optional; the render fits them if missing)

# 6. Render manuscript (HTML + PDF + DOCX → docs/ for GitHub Pages)
quarto render manuscript.qmd --to html
quarto render manuscript.qmd --to preprint-typst
quarto render manuscript.qmd --to docx
```

**Note on first run:** The manuscript fits the four registered-analysis Bayesian models (M1–M4) via `brms` on first render, which takes roughly **24+ hours** depending on hardware; the daily-timescale and sensitivity models in step 5 are fit outside the render and add a similar amount. Fitted models are cached as `.rds` files in `models/`, and the multiple imputation is cached in `data/processed/imputation/` (neither tracked by git; the manuscript regenerates the imputation automatically if the cache is missing). Subsequent renders load the cached fits and complete in minutes. Each render loads all fits into memory (several GB), so render one format at a time rather than the bare `quarto render manuscript.qmd`. Delete `models/` to refit everything from scratch.

## Repository structure

```
manuscript.qmd                  Main manuscript (introduction, methods, analysis, discussion)
supplement_model_output.qmd     Supplement: full posterior summaries for the four Bayesian models
bibliography.bib                References
_quarto.yml                     Quarto project config (renders to docs/ for GitHub Pages)
Makefile                        Downloads data from Zenodo
renv.lock                       R dependency lockfile
docs/                           Published site (manuscript HTML, PDF, DOCX)
R/
  01_preprocess.R               Preprocessing pipeline (multi-genre full attribution)
  02_impute_wemwbs.R            Two-level MICE imputation of SWEMWBS on the person x wave grid
  03_prior_sensitivity.R        Superseded (2026-10-13): all models use brms default priors; not run
  04_daily_aggregate.R          Daily diary exposure pipeline (same-day windows; exploratory analysis)
  fit_daily_models.R            Fits the exploratory daily models (caches to models/daily/)
  fit_sensitivity_models.R      Fits the demographic sensitivity models (caches to models/)
  helpers.R                     Table formatting utilities
  sim_mm_recovery.R             Supplementary: M4 parameter-recovery engine (fits the manuscript's own M4 chunks to simulated data; SIM_REPS, SIM_ITER)
  sim_mm_recovery_report.qmd    Supplementary: recovery report (reads data/processed/sim_recovery/, never fits)
  sim_mm_recovery_report.html   Rendered recovery report (2026-10-14, 20 replications, 8,000 iterations)
  model_comparison_report.html  Rendered supplementary model comparison (LOO)
apa.csl                         APA citation style
ensure-nojekyll.sh              Post-render hook keeping the GitHub Pages marker in docs/
_extensions/                    Quarto typst preprint extension (mvuorre/preprint)
```

## Deviations from pre-registration

The main analysis assigns **all IGDB genres** to each game rather than only the primary genre, as pre-registered, and uses Bayesian rather than frequentist inference. Missing outcomes are multiply imputed with the hierarchical two-level protocol shared with the programmatic RR's sibling Stage 2 studies (`R/02_impute_wemwbs.R`), reported as a sensitivity analysis. All deviations are documented in the manuscript's deviation appendix (Appendix A).

## Authors

| Name | ORCID | Affiliation |
|------|-------|-------------|
| Thomas Hakman | [0009-0009-8292-2482](https://orcid.org/0009-0009-8292-2482) | Oxford Internet Institute |
| Matti Vuorre | [0000-0001-5052-066X](https://orcid.org/0000-0001-5052-066X) | Tilburg University |
| Nick Ballou | [0000-0003-4126-0696](https://orcid.org/0000-0003-4126-0696) | Imperial College London, Oxford Internet Institute |
| Tamás Andrei Földes | [0000-0002-0623-9149](https://orcid.org/0000-0002-0623-9149) | Oxford Internet Institute |
| Kristoffer Magnusson | [0000-0003-0713-0556](https://orcid.org/0000-0003-0713-0556) | Karolinska Institute, Oxford Internet Institute |
| Andrew K. Przybylski | [0000-0001-5547-2185](https://orcid.org/0000-0001-5547-2185) | Oxford Internet Institute |

## License

Code is released under the [MIT License](LICENSE). The Open Play data are distributed under their own terms; see the [Open Play repository](https://github.com/digital-wellbeing/open-play) and Zenodo record.
