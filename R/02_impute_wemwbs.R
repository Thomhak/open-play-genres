# =============================================================================
# Multiple imputation of SWEMWBS: hierarchical two-level MICE on the full
# participant x wave grid
# =============================================================================
#
# Protocol mirrors the two sibling Stage 2 outputs of the programmatic RR:
#   - platform-study-rr-sleep (R/imputation_panel.R): two-level MICE with
#     miceadds 2l.pmm, participants as clusters, full person x wave grid,
#     grand-mean centring, +/-1-wave lag/lead terms, chunk-parallel mice
#     combined with ibind, 20 iterations per imputation.
#   - basic-needs-in-games (index.qmd, v1.0.5): telemetry never imputed
#     (recorded absence of play), intake measures as auxiliary predictors,
#     number of imputations set from the fraction of missing information
#     via von Hippel's (2020) two-stage quadratic rule, and pre/post-mice
#     diagnostics (zero-variance and loggedEvents checks).
#
# Adaptations for Study 3 (documented in the manuscript):
#   - Only SWEMWBS is imputed. Every SWEMWBS-missing submitted survey is
#     missing on all 7 items (asserted below), so the composite item mean is
#     imputed directly; item-level imputation has nothing to condition on.
#   - Gaming exposures (total playtime and the 14 genre exposure columns) are
#     fully observed by construction (absence of telemetry play = 0 minutes)
#     and are never imputed. Their person means are entered as explicit
#     level-2 columns, which for fully observed covariates is equivalent to
#     miceadds predictor-type 3 ("fixed effect + cluster mean") and preserves
#     the within/between decomposition the analysis models rely on.
#   - Exposure windows are anchored to each participant's baseline day, not to
#     survey timestamps, so no timestamps need to be inferred for missing
#     waves (unlike the sleep study's protocol).
#   - The clean Open Play intake contains no baseline WEMWBS or life
#     satisfaction for qualified participants (all such values sit in a
#     screened-out subsample), so unlike basic-needs-in-games these cannot
#     serve as auxiliaries. Person-level anchoring comes from the cluster
#     random intercept of 2l.pmm (each participant's observed waves), the
#     +/-1-wave lag/lead terms, and the remaining intake auxiliaries
#     (self-reported weekly play, panels completed, age, gender, country).
#     Biweekly life satisfaction / affect were considered as joint auxiliaries
#     and excluded: their missingness co-occurs exactly with the outcome's
#     (same survey), so they carry no observed information for a missing wave.
#
# Outputs (data/processed/imputation/):
#   imp_wemwbs.rds       list: mids object (centred scale) + metadata
#   imputed_long.rds     list of m completed long datasets on the 1-5 scale,
#                        with within/between decompositions rebuilt on the grid
#   missingness_by_wave.csv
# QC plots (output/qc_imputation/): trace, density, strip
#
# Usage: Rscript R/02_impute_wemwbs.R
#        or source() and call impute_wemwbs() (used by manuscript.qmd)
# =============================================================================

library(here)
here::i_am("R/02_impute_wemwbs.R")

suppressPackageStartupMessages({
  library(tidyverse)
  library(mice)
  library(miceadds)
  library(future.apply)
})

source(here("R/01_preprocess.R"))

# --- Protocol constants ------------------------------------------------------
# N_IMPUTATIONS / N_ITERATIONS / SEED / one lag-lead pair mirror the sleep
# study's panel pass. MAX_IMPUTATIONS bounds the von Hippel top-up.
N_IMPUTATIONS   <- 20L
N_ITERATIONS    <- 20L
SEED            <- 42L
MAX_IMPUTATIONS <- 100L
SE_CV_TARGET    <- 0.05  # von Hippel (2020): target cv of replication SEs

IMP_DIR   <- here("data/processed/imputation")
QC_DIR    <- here("output/qc_imputation")
IMP_META_PATH <- file.path(IMP_DIR, "imp_wemwbs.rds")
IMP_LONG_PATH <- file.path(IMP_DIR, "imputed_long.rds")

# =============================================================================
# Helpers
# =============================================================================

#' Run mice in parallel chunks and combine with ibind (sleep-study pattern)
run_mice_chunks <- function(data, meth, pred, m_total, seed, label = "main") {
  n_workers   <- max(1L, min(4L, future::availableCores() - 1L, m_total))
  chunk_sizes <- diff(floor(seq(0, m_total, length.out = n_workers + 1)))
  chunk_sizes <- chunk_sizes[chunk_sizes > 0]
  set.seed(seed)
  chunk_seeds <- sample.int(1e7, length(chunk_sizes))

  message(sprintf("  [%s] %d imputations in %d chunks (%s), %d iterations",
                  label, m_total, length(chunk_sizes),
                  paste(chunk_sizes, collapse = "+"), N_ITERATIONS))

  future::plan(future::multisession, workers = length(chunk_sizes))
  on.exit(future::plan(future::sequential), add = TRUE)

  imp_list <- future.apply::future_lapply(seq_along(chunk_sizes), function(i) {
    suppressPackageStartupMessages(library(miceadds))
    mice::mice(
      data,
      m               = chunk_sizes[i],
      method          = meth,
      predictorMatrix = pred,
      maxit           = N_ITERATIONS,
      seed            = chunk_seeds[i],
      printFlag       = FALSE
    )
  }, future.seed = TRUE)

  Reduce(mice::ibind, imp_list)
}

#' Fit the H1 REWB model (console/PC total, matching M0's scope) in each
#' completed dataset; used for the von Hippel FMI check.
fit_h1_per_imputation <- function(imp_obj, wemwbs_grand_mean) {
  lapply(seq_len(imp_obj$m), function(i) {
    d <- mice::complete(imp_obj, i) |>
      mutate(
        wemwbs     = wemwbs_c + wemwbs_grand_mean,
        tt_within  = total_hours_per_day - total_hours_per_day_pm,
        tt_between = total_hours_per_day_pm
      )
    suppressWarnings(suppressMessages(
      lme4::lmer(wemwbs ~ tt_within + tt_between + (1 + tt_within | pid_int),
                 data = d,
                 control = lme4::lmerControl(optimizer = "bobyqa",
                                             calc.derivs = FALSE))
    ))
  })
}

# =============================================================================
# Main pipeline
# =============================================================================

impute_wemwbs <- function() {

  dir.create(IMP_DIR, showWarnings = FALSE, recursive = TRUE)
  dir.create(QC_DIR,  showWarnings = FALSE, recursive = TRUE)

  # ---------------------------------------------------------------------------
  # 1. Full participant x wave grid
  # ---------------------------------------------------------------------------
  message("=== Building full participant x wave grid ===")

  survey <- load_survey_data() |>
    # The clean biweekly file contains a handful of rows with wave == 7
    # (outside the six-wave design); exclude them from the imputation frame.
    filter(wave >= 1, wave <= N_WAVES)

  analysis_pids <- survey |> filter(!is.na(wemwbs)) |> distinct(pid) |> pull(pid)
  n_no_outcome  <- n_distinct(survey$pid) - length(analysis_pids)
  message(sprintf(
    "  %d participants with >=1 valid SWEMWBS (%d surveyed participants with none excluded)",
    length(analysis_pids), n_no_outcome
  ))

  grid <- expand_grid(pid = analysis_pids, wave = 1:N_WAVES) |>
    left_join(survey |> select(pid, wave, wemwbs, baseline_date),
              by = c("pid", "wave")) |>
    group_by(pid) |>
    fill(baseline_date, .direction = "downup") |>
    ungroup()

  # Premise check: every missing submitted SWEMWBS is missing on ALL 7 items,
  # so imputing the composite directly loses nothing.
  biw_items <- read_csv(here("data/clean/survey_biweekly.csv.gz"),
                        show_col_types = FALSE) |>
    filter(wave >= 1, wave <= N_WAVES) |>
    select(starts_with("wemwbs_"))
  n_partial <- sum({
    k <- rowSums(is.na(biw_items)); k > 0 & k < 7
  })
  stopifnot("Partial item missingness found; impute items instead" = n_partial == 0)
  message("  Verified: no partial item-level missingness (all-or-nothing by wave)")

  # ---------------------------------------------------------------------------
  # 2. Fully observed gaming exposures (never imputed)
  # ---------------------------------------------------------------------------
  message("=== Attaching telemetry exposures (recorded absence of play = 0) ===")

  genre_wave_long <- read_csv(here("data/processed/genre_wave_long.csv"),
                              show_col_types = FALSE)
  total_playtime  <- read_csv(here("data/processed/total_playtime.csv"),
                              show_col_types = FALSE)

  mobile <- bind_rows(
    read_csv(here("data/clean/ios.csv.gz"),     show_col_types = FALSE),
    read_csv(here("data/clean/android.csv.gz"), show_col_types = FALSE)
  ) |>
    mutate(date = as.Date(day_local)) |>
    group_by(pid, date) |>
    summarise(minutes = sum(minutes, na.rm = TRUE), .groups = "drop") |>
    left_join(survey |> distinct(pid, baseline_date), by = "pid") |>
    filter(!is.na(baseline_date)) |>
    mutate(wave = assign_wave_vec(date, baseline_date)) |>
    filter(!is.na(wave)) |>
    group_by(pid, wave) |>
    summarise(mobile_hours_per_day = sum(minutes, na.rm = TRUE) / 60 / WAVE_LENGTH_DAYS,
              .groups = "drop")

  genre_hours_wide <- genre_wave_long |>
    mutate(col = {
      clean <- gsub("[^a-z0-9]+", "_", tolower(genre))
      clean <- gsub("^_+|_+$", "", clean)
      clean <- gsub("__+", "_", clean)
      paste0("gh_", clean)
    }) |>
    select(pid, wave, col, hours_per_day) |>
    pivot_wider(names_from = col, values_from = hours_per_day, values_fill = 0)

  gh_vars <- sort(setdiff(names(genre_hours_wide), c("pid", "wave")))

  grid <- grid |>
    left_join(total_playtime |> select(pid, wave, total_hours_per_day),
              by = c("pid", "wave")) |>
    left_join(mobile, by = c("pid", "wave")) |>
    left_join(genre_hours_wide, by = c("pid", "wave")) |>
    mutate(
      total_hours_per_day      = replace_na(total_hours_per_day, 0),
      mobile_hours_per_day     = replace_na(mobile_hours_per_day, 0),
      total_time_all_platforms = total_hours_per_day + mobile_hours_per_day,
      across(all_of(gh_vars), ~ replace_na(.x, 0))
    )

  # Person means as explicit level-2 predictor columns (complete covariates;
  # equivalent to predictor-type 3). total_hours_per_day is the console/PC
  # total used by the main manuscript's models; total_time_all_platforms is
  # the pre-registered all-platform total.
  exposure_vars <- c("total_hours_per_day", "total_time_all_platforms", gh_vars)
  grid <- grid |>
    group_by(pid) |>
    mutate(across(all_of(exposure_vars), ~ mean(.x), .names = "{.col}_pm")) |>
    ungroup()
  exposure_pm_vars <- paste0(exposure_vars, "_pm")

  # ---------------------------------------------------------------------------
  # 3. Level-2 auxiliaries from the intake survey
  # ---------------------------------------------------------------------------
  message("=== Attaching intake auxiliaries ===")

  intake_aux <- read_csv(here("data/clean/survey_intake.csv.gz"),
                         show_col_types = FALSE) |>
    filter(qualified) |>
    mutate(
      pid = as.character(pid),
      gender_num = case_when(
        gender %in% c("Man", "Male")     ~ 1,
        gender %in% c("Woman", "Female") ~ 2,
        is.na(gender)                    ~ NA_real_,
        gender == "Prefer not to say"    ~ NA_real_,
        TRUE                             ~ 3
      ),
      country_num = if_else(country == "US", 0, 1)
    ) |>
    select(pid, age, gender_num, country_num,
           srwp_baseline = self_reported_weekly_play,
           panels_completed) |>
    distinct(pid, .keep_all = TRUE)

  grid <- grid |> left_join(intake_aux, by = "pid")

  n_aux_missing <- grid |> distinct(pid, age) |>
    summarise(n = sum(is.na(age))) |> pull(n)
  message(sprintf(
    "  Intake auxiliaries attached; %d participants lack an intake match (2lonly.pmm)",
    n_aux_missing
  ))

  # ---------------------------------------------------------------------------
  # 4. Grand-mean centring, lag/lead, cluster id, missingness table
  # ---------------------------------------------------------------------------
  wemwbs_grand_mean <- mean(grid$wemwbs, na.rm = TRUE)
  grid <- grid |>
    arrange(pid, wave) |>
    mutate(wemwbs_c = wemwbs - wemwbs_grand_mean) |>
    group_by(pid) |>
    mutate(
      wemwbs_c_lag1  = dplyr::lag(wemwbs_c,  n = 1L),
      wemwbs_c_lead1 = dplyr::lead(wemwbs_c, n = 1L)
    ) |>
    ungroup() |>
    mutate(pid_int = as.integer(factor(pid)))

  missingness_by_wave <- grid |>
    group_by(wave) |>
    summarise(
      n_possible  = n(),
      n_observed  = sum(!is.na(wemwbs)),
      n_missing   = sum(is.na(wemwbs)),
      pct_missing = round(100 * mean(is.na(wemwbs)), 1),
      .groups = "drop"
    )
  write_csv(missingness_by_wave, file.path(IMP_DIR, "missingness_by_wave.csv"))
  message("  Missingness by wave:")
  for (i in seq_len(nrow(missingness_by_wave))) {
    message(sprintf("    wave %d: %d/%d missing (%.1f%%)",
      missingness_by_wave$wave[i], missingness_by_wave$n_missing[i],
      missingness_by_wave$n_possible[i], missingness_by_wave$pct_missing[i]))
  }

  # ---------------------------------------------------------------------------
  # 5. mice setup: methods, predictor matrix, pre-flight diagnostics
  # ---------------------------------------------------------------------------
  imp_frame <- grid |>
    select(pid_int, wave,
           all_of(c(exposure_vars, exposure_pm_vars)),
           age, gender_num, country_num, srwp_baseline, panels_completed,
           wemwbs_c, wemwbs_c_lag1, wemwbs_c_lead1) |>
    as.data.frame()

  l1_impute_vars <- c("wemwbs_c", "wemwbs_c_lag1", "wemwbs_c_lead1")
  l2_aux_vars    <- c("age", "gender_num", "country_num",
                      "srwp_baseline", "panels_completed")

  # Pre-flight (basic-needs-in-games pattern): any declared auxiliary that is
  # constant or empty would be dropped silently by mice; fail loudly instead.
  for (v in c(l2_aux_vars, exposure_vars)) {
    n_unique <- dplyr::n_distinct(imp_frame[[v]], na.rm = TRUE)
    if (n_unique < 2) {
      stop(sprintf(
        "Auxiliary/exposure '%s' has %d unique non-missing values; it would be dropped by mice. Fix the data preparation.",
        v, n_unique
      ))
    }
  }
  message("  Pre-flight: all auxiliaries and exposures vary (nothing for mice to drop)")

  meth <- setNames(rep("", ncol(imp_frame)), names(imp_frame))
  meth[l1_impute_vars] <- "2l.pmm"
  for (v in l2_aux_vars) {
    if (any(is.na(imp_frame[[v]]))) meth[v] <- "2lonly.pmm"
  }

  pred <- matrix(0L, ncol(imp_frame), ncol(imp_frame),
                 dimnames = list(names(imp_frame), names(imp_frame)))
  for (target in l1_impute_vars) {
    pred[target, ] <- 1L
    pred[target, "pid_int"] <- -2L
    pred[target, target] <- 0L
  }
  for (target in names(meth)[meth == "2lonly.pmm"]) {
    pred[target, ] <- 0L
    pred[target, "pid_int"] <- -2L
    pred[target, c(l2_aux_vars, exposure_pm_vars)] <- 1L
    pred[target, target] <- 0L
  }

  message(sprintf(
    "=== mice: %d rows x %d cols; imputing %s (2l.pmm)%s ===",
    nrow(imp_frame), ncol(imp_frame),
    paste(l1_impute_vars, collapse = ", "),
    if (any(meth == "2lonly.pmm")) {
      sprintf("; %s (2lonly.pmm)",
              paste(names(meth)[meth == "2lonly.pmm"], collapse = ", "))
    } else ""
  ))

  # ---------------------------------------------------------------------------
  # 6. Run mice, then top up per von Hippel (2020)
  # ---------------------------------------------------------------------------
  t0 <- Sys.time()
  imp <- run_mice_chunks(imp_frame, meth, pred, N_IMPUTATIONS, seed = SEED)
  message(sprintf("  mice finished in %.1f min",
                  as.numeric(difftime(Sys.time(), t0, units = "mins"))))

  message("=== von Hippel (2020) m-sufficiency check ===")
  pilot_pool <- mice::pool(mice::as.mira(
    fit_h1_per_imputation(imp, wemwbs_grand_mean)))
  fmi_terms  <- pilot_pool$pooled[
    pilot_pool$pooled$term %in% c("tt_within", "tt_between"),
    c("term", "fmi")]
  fmi_max  <- max(fmi_terms$fmi, na.rm = TRUE)
  m_needed <- ceiling(1 + 0.5 * (fmi_max / SE_CV_TARGET)^2)
  message(sprintf("  pilot FMI: within = %.3f, between = %.3f -> m_needed = %d (current m = %d)",
                  fmi_terms$fmi[fmi_terms$term == "tt_within"],
                  fmi_terms$fmi[fmi_terms$term == "tt_between"],
                  m_needed, imp$m))

  m_target <- min(m_needed, MAX_IMPUTATIONS)
  if (m_target > imp$m) {
    message(sprintf("  Topping up with %d additional imputations", m_target - imp$m))
    imp_extra <- run_mice_chunks(imp_frame, meth, pred, m_target - imp$m,
                                 seed = SEED + 1L, label = "top-up")
    imp <- mice::ibind(imp, imp_extra)
  }
  if (m_needed > MAX_IMPUTATIONS) {
    message(sprintf(
      "  NOTE: m_needed (%d) exceeds cap (%d); using m = %d. Achieved SE cv ~= %.3f (reported in the manuscript).",
      m_needed, MAX_IMPUTATIONS, imp$m, fmi_max / sqrt(2 * imp$m)))
  }
  message(sprintf("  Final m = %d", imp$m))

  # Post-flight: no imputed variable or declared auxiliary may have been
  # dropped by mice (constant/collinear); dropped exposure person-means are
  # tolerated (they are near-collinear by construction) but reported.
  le <- imp$loggedEvents
  if (!is.null(le) && nrow(le) > 0) {
    critical <- le[le$out %in% c(l1_impute_vars, l2_aux_vars, exposure_vars), ]
    if (nrow(critical) > 0) {
      print(critical)
      stop("mice dropped imputation-critical variables (see above).")
    }
    message(sprintf("  loggedEvents: %d non-critical events (e.g. collinear person-mean columns)",
                    nrow(le)))
  } else {
    message("  loggedEvents: none")
  }

  # ---------------------------------------------------------------------------
  # 7. QC diagnostics
  # ---------------------------------------------------------------------------
  message("=== QC diagnostics ===")
  png(file.path(QC_DIR, "trace_wemwbs.png"), width = 1400, height = 900, res = 150)
  print(plot(imp))
  dev.off()
  png(file.path(QC_DIR, "density_wemwbs.png"), width = 1400, height = 900, res = 150)
  print(mice::densityplot(imp, ~ wemwbs_c))
  dev.off()
  png(file.path(QC_DIR, "strip_wemwbs.png"), width = 1400, height = 900, res = 150)
  print(mice::stripplot(imp, wemwbs_c ~ .imp, pch = 20, cex = 0.4))
  dev.off()
  message("  Saved trace/density/strip plots to output/qc_imputation/")

  # ---------------------------------------------------------------------------
  # 8. Export completed long datasets on the analysis scale
  # ---------------------------------------------------------------------------
  message("=== Exporting completed datasets ===")

  pid_lookup <- grid |> distinct(pid, pid_int)

  imputed_long <- lapply(seq_len(imp$m), function(i) {
    mice::complete(imp, i) |>
      as_tibble() |>
      left_join(pid_lookup, by = "pid_int") |>
      mutate(
        wave   = as.integer(wave),
        wemwbs = wemwbs_c + wemwbs_grand_mean,
        .imp   = i
      ) |>
      group_by(pid) |>
      mutate(
        # Within/between decompositions over the full six-wave grid.
        # Exposures are complete, so these are identical across imputations.
        total_within  = total_hours_per_day - total_hours_per_day_pm,
        total_between = total_hours_per_day_pm,
        total_time_all_platforms_within  =
          total_time_all_platforms - total_time_all_platforms_pm,
        total_time_all_platforms_between = total_time_all_platforms_pm,
        across(all_of(gh_vars),
               list(within  = ~ .x - mean(.x),
                    between = ~ mean(.x)),
               .names = "{.col}_{.fn}")
      ) |>
      ungroup() |>
      select(.imp, pid, wave, wemwbs,
             total_hours_per_day, total_within, total_between,
             starts_with("total_time_all_platforms"),
             all_of(gh_vars), matches("^gh_.*_(within|between)$"))
  })

  # PMM donates observed values, so back-transformed scores stay in [1, 5]
  stopifnot(all(vapply(imputed_long,
                       function(d) all(d$wemwbs >= 1 & d$wemwbs <= 5),
                       logical(1))))

  meta <- list(
    imp                 = imp,
    center_mean         = wemwbs_grand_mean,
    grid_pids           = length(analysis_pids),
    n_cells             = nrow(imp_frame),
    n_missing           = sum(is.na(imp_frame$wemwbs_c)),
    fmi_pilot           = fmi_terms,
    fmi_max_pilot       = fmi_max,
    m_needed            = m_needed,
    se_cv_achieved      = fmi_max / sqrt(2 * imp$m),
    seed                = SEED,
    n_iterations        = N_ITERATIONS,
    missingness_by_wave = missingness_by_wave
  )
  saveRDS(meta, IMP_META_PATH)
  saveRDS(imputed_long, IMP_LONG_PATH)

  message(sprintf(
    "Saved: imp_wemwbs.rds (m = %d) and imputed_long.rds (%d datasets x %d rows)",
    imp$m, length(imputed_long), nrow(imputed_long[[1]])
  ))
  message("Done.")

  invisible(meta)
}

# =============================================================================
# Run if executed directly
# =============================================================================

if (sys.nframe() == 0) {
  impute_wemwbs()
}
