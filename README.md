# Playtime–wellbeing associations are practically null across video game genres

**Thomas Hakman, Nick Ballou, Tamás Andrei Földes, Matti Vuorre, Kristoffer Magnusson, Andrew K. Przybylski**

Oxford Internet Institute · Tilburg University · Karolinska Institute

---

Stage 2 of Study 3 from an accepted PCI Registered Reports programmatic registered report (Ballou et al., *Psychological Wellbeing, Sleep, and Video Gaming: Analyses of Comprehensive Digital Traces*). We test whether total cross-platform gaming playtime is meaningfully associated with mental wellbeing (H1), and whether that association varies by game genre (H2), using multi-platform digital trace data and biweekly self-report surveys from the Open Play longitudinal dataset.

## Reproducing the analysis

**Requirements:** R ≥ 4.4, [renv](https://rstudio.github.io/renv/), [Quarto](https://quarto.org), `wget`, `unzip`

```bash
# 1. Download Open Play v1.1.0 data from Zenodo (~194MB)
make data

# 2. Install R dependencies
Rscript -e "renv::restore()"

# 3. Run preprocessing pipeline
Rscript R/01_preprocess.R

# 4. Run the multiple imputation (cached; ~20 min)
Rscript R/02_impute_wemwbs.R

# 5. Render manuscript
quarto render manuscript.qmd
```

**Note on first run:** The manuscript fits four Bayesian models via `brms`. On a first render (no cached model files), this takes roughly **24+ hours** depending on hardware. Fitted models are cached as `.rds` files in `models/`, and the multiple imputation is cached in `data/processed/imputation/` (neither tracked by git; the manuscript regenerates the imputation automatically if the cache is missing). Subsequent renders load the cached fits and complete in minutes.

## Repository structure

```
manuscript.qmd                  Main manuscript (introduction, methods, analysis, discussion)
supplement_model_output.qmd     Supplement: full posterior summaries for the four Bayesian models
bibliography.bib                References
_quarto.yml                     Quarto project config
Makefile                        Downloads data from Zenodo
renv.lock                       R dependency lockfile
R/
  01_preprocess.R               Preprocessing pipeline (multi-genre full attribution)
  02_impute_wemwbs.R            Two-level MICE imputation of SWEMWBS on the person x wave grid
  fit_sensitivity_models.R      Fits the demographic sensitivity models (caches to models/)
  helpers.R                     Table formatting utilities
  sim_mm_recovery_report.qmd    Supplementary: multi-membership model simulation validation
_extensions/                    Quarto typst preprint extension (mvuorre/preprint)
```

## Data

Gameplay telemetry and survey data are from the **Open Play** longitudinal dataset (v1.1.0), available on Zenodo:

> Ballou, N., et al. (2025). *Open Play: A longitudinal dataset of video game play and psychological wellbeing*. Zenodo. https://zenodo.org/records/18430947

Data files are not stored in this repository. Run `make data` to download them into `data/clean/`.

## Deviations from pre-registration

The main analysis assigns **all IGDB genres** to each game rather than only the primary genre, as pre-registered, and uses Bayesian rather than frequentist inference. Missing outcomes are multiply imputed with the hierarchical two-level protocol shared with the programmatic RR's sibling Stage 2 studies (`R/02_impute_wemwbs.R`), reported as a sensitivity analysis. All deviations are documented in the manuscript's deviation appendix (Appendix B). The full pre-registered analysis — primary-genre attribution, frequentist `lmer` models, TOST equivalence tests, joint Wald tests, and multiple imputation — is reported in a standalone supplement accompanying the manuscript.

## Pre-registration

This study was pre-registered as part of a Stage 1 Programmatic Registered Report. Pre-registration materials are available at <https://osf.io/mvngt/>.

## Authors

| Name | ORCID | Affiliation |
|------|-------|-------------|
| Thomas Hakman | [0009-0009-8292-2482](https://orcid.org/0009-0009-8292-2482) | Oxford Internet Institute |
| Nick Ballou | [0000-0003-4126-0696](https://orcid.org/0000-0003-4126-0696) | Oxford Internet Institute |
| Tamás Andrei Földes | [0000-0002-0623-9149](https://orcid.org/0000-0002-0623-9149) | Oxford Internet Institute |
| Matti Vuorre | [0000-0001-5052-066X](https://orcid.org/0000-0001-5052-066X) | Tilburg University |
| Kristoffer Magnusson | [0000-0003-0713-0556](https://orcid.org/0000-0003-0713-0556) | Karolinska Institute |
| Andrew K. Przybylski | [0000-0001-5547-2185](https://orcid.org/0000-0001-5547-2185) | Oxford Internet Institute |
