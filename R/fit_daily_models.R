# Fit the exploratory daily-timescale models (see notes/analysis_plan_daily.md).
# Prespecified: the SESOI transfer, prior scales, and model set are fixed by
# the plan BEFORE any exposure-outcome model is estimated. This script
# computes the transfer deterministically from observed marginals and fits
# with file-based caching under models/daily/. Model constructions mirror the
# registered biweekly models in manuscript.qmd (M0 h1-fit, M2 h2-hier-fit,
# M3 mm-formula-setup) with priors rescaled by r = SESOI_LS / 0.06.
#
# Usage: Rscript R/fit_daily_models.R mm     (M3 multi-membership, longest)
#        Rscript R/fit_daily_models.R rest   (M0/M2 x both outcomes + lagged)
# The two invocations are independent and can run concurrently.

suppressPackageStartupMessages({
  library(tidyverse)
  library(brms)
  library(lme4)
  library(here)
})

which_block <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(which_block) || !which_block %in% c("mm", "rest", "bridge", "m1")) {
  stop("Argument must be 'mm', 'rest', 'bridge', or 'm1'")
}
dir.create(here("models/daily"), showWarnings = FALSE, recursive = TRUE)

# ---- Data ------------------------------------------------------------------

raw_frame <- read_csv(here("data/processed/daily/daily_model_frame.csv"),
                      show_col_types = FALSE)
gh_cols <- sort(grep("^gh_", names(raw_frame), value = TRUE))
stopifnot(length(gh_cols) == 14, "covered" %in% names(raw_frame))

# Within-between decomposition on the analysis frame. Raw gh_ columns are
# kept for the mm() weights; _w/_b suffixes carry the decomposition.
decompose <- function(df) {
  df |>
    group_by(pid) |>
    mutate(
      total_within  = total_hours_24h - mean(total_hours_24h, na.rm = TRUE),
      total_between = mean(total_hours_24h, na.rm = TRUE),
      across(all_of(gh_cols),
             list(w = ~ .x - mean(.x, na.rm = TRUE),
                  b = ~ mean(.x, na.rm = TRUE)))
    ) |>
    ungroup()
}

# Primary frame: coverage-restricted (see analysis plan, pre-fit amendment).
# Full frame retained for the M0 sensitivity refit only.
frame      <- decompose(raw_frame |> filter(covered))
frame_full <- decompose(raw_frame)
message(sprintf("Primary (covered) frame: %d responses, %d pids (full: %d, %d)",
                nrow(frame), n_distinct(frame$pid),
                nrow(frame_full), n_distinct(frame_full$pid)))
gh_w <- paste0(gh_cols, "_w")
gh_b <- paste0(gh_cols, "_b")

# ---- SESOI transfer (prespecified formula; see analysis plan) --------------

within_sd <- function(x, id) {
  d <- tibble(x = x, id = id) |>
    filter(!is.na(x)) |>
    group_by(id) |>
    filter(n() >= 2) |>
    mutate(dev = x - mean(x)) |>
    ungroup()
  sd(d$dev)
}

biweekly <- read_csv(here("data/clean/survey_biweekly.csv.gz"),
                     show_col_types = FALSE) |>
  filter(wave >= 1, wave <= 6) |>
  mutate(wemwbs = rowMeans(across(starts_with("wemwbs_")))) |>
  filter(!is.na(wemwbs), wemwbs >= 1)

# Outcome within-SDs on ALL diary responses (outcome property, not
# coverage-dependent; see analysis plan).
s_w_swemwbs <- within_sd(biweekly$wemwbs, biweekly$pid)
s_w_ls      <- within_sd(raw_frame$life_sat, raw_frame$pid)
s_w_av      <- within_sd(raw_frame$affective_valence, raw_frame$pid)

sesoi_ls <- 0.06 * s_w_ls / s_w_swemwbs
sesoi_av <- 0.06 * s_w_av / s_w_swemwbs
r_ls     <- sesoi_ls / 0.06

saveRDS(
  list(s_w_swemwbs = s_w_swemwbs, s_w_ls = s_w_ls, s_w_av = s_w_av,
       sesoi_ls = sesoi_ls, sesoi_av = sesoi_av, r_ls = r_ls,
       sesoi_range_transfer = 1.5),
  here("models/daily/sesoi.rds")
)
message(sprintf(
  "SESOI transfer: s_w(SWEMWBS)=%.3f  s_w(LS)=%.2f  s_w(AV)=%.2f  -> SESOI_LS=%.2f  SESOI_AV=%.2f  (r=%.1f)",
  s_w_swemwbs, s_w_ls, s_w_av, sesoi_ls, sesoi_av, r_ls
))

# ---- Prior scales (registered scales times r) ------------------------------

b_scale     <- 0.5 * r_ls   # registered student_t(3, 0, 0.5)
tau_scale   <- 0.1 * r_ls   # registered Half-Normal(0, 0.1)
sigma_scale <- 0.3 * r_ls   # registered mm sd normal(0, 0.3)
prior_b         <- sprintf("student_t(3, 0, %.3f)", b_scale)
prior_intercept <- "student_t(3, 50, 25)"  # midpoint + half-range, as registered

model_data_ls <- frame |> filter(!is.na(life_sat))
model_data_av <- frame |> filter(!is.na(affective_valence))
message(sprintf("Rows: life_sat %d, valence %d, pids %d",
                nrow(model_data_ls), nrow(model_data_av),
                n_distinct(frame$pid)))

# ---- Model blocks ----------------------------------------------------------

if (which_block == "m1") {

  # M1-daily: unpooled fixed-effects genre specification (mirrors the
  # registered h2_genre_model), primary outcome only. Same prior family as
  # the other daily fits. Its raw per-draw coefficient SDs carry sampling
  # noise, as in the registered analysis; reported with that caveat.
  m1_rhs <- paste(c(gh_w, gh_b), collapse = " + ")
  message("Fitting M1-daily (life_sat)...")
  invisible(brm(
    bf(as.formula(paste("life_sat ~", m1_rhs, "+ (1 | pid)"))),
    data   = model_data_ls,
    prior  = set_prior(prior_b, class = "b") +
             set_prior(prior_intercept, class = "Intercept"),
    family = gaussian(),
    chains = 4, iter = 4000, warmup = 2000, cores = 4, seed = 8675309,
    control = list(adapt_delta = 0.95),
    file = here("models/daily/m1_daily_ls"), file_refit = "never"
  ))
  message("M1-daily done.")

} else if (which_block == "bridge") {

  # Same-instrument bridge: M0 structure on BIWEEKLY life satisfaction.
  # Mirrors the registered M0 frame (full survey, zero-filled exposure, no
  # coverage restriction): its purpose is comparability with the registered
  # SWEMWBS analysis, holding the outcome instrument constant across grains.
  bls <- read_csv(here("data/clean/survey_biweekly.csv.gz"),
                  show_col_types = FALSE) |>
    filter(wave >= 1, wave <= 6, !is.na(life_sat)) |>
    select(pid, wave, life_sat)
  message(sprintf("Biweekly life_sat: n=%d, pids=%d, min=%.1f, max=%.1f",
                  nrow(bls), n_distinct(bls$pid), min(bls$life_sat),
                  max(bls$life_sat)))
  tp <- read_csv(here("data/processed/total_playtime.csv"),
                 show_col_types = FALSE)
  bframe <- bls |>
    left_join(tp, by = c("pid", "wave")) |>
    mutate(total_hours_per_day = replace_na(total_hours_per_day, 0)) |>
    group_by(pid) |>
    mutate(
      total_within  = total_hours_per_day - mean(total_hours_per_day),
      total_between = mean(total_hours_per_day)
    ) |>
    ungroup()

  s_w_bls    <- within_sd(bframe$life_sat, bframe$pid)
  sesoi_bls  <- 0.06 * s_w_bls / s_w_swemwbs
  r_bls      <- sesoi_bls / 0.06
  scale_max  <- max(bframe$life_sat)
  int_prior  <- if (scale_max <= 10) "student_t(3, 5, 2.5)" else "student_t(3, 50, 25)"
  message(sprintf("Bridge SESOI: s_w(bLS)=%.3f -> SESOI_bLS=%.3f (r=%.1f); intercept prior %s",
                  s_w_bls, sesoi_bls, r_bls, int_prior))

  s_all <- readRDS(here("models/daily/sesoi.rds"))
  s_all$s_w_bls   <- s_w_bls
  s_all$sesoi_bls <- sesoi_bls
  s_all$bls_scale_max <- scale_max
  saveRDS(s_all, here("models/daily/sesoi.rds"))

  message("Fitting M0-biweekly life_sat bridge...")
  invisible(brm(
    bf(life_sat ~ total_within + total_between + (1 + total_within | pid)),
    data   = bframe,
    prior  = set_prior(sprintf("student_t(3, 0, %.3f)", 0.5 * r_bls), class = "b") +
             set_prior(int_prior, class = "Intercept"),
    family = gaussian(),
    chains = 4, iter = 4000, warmup = 2000, cores = 4, seed = 8675309,
    control = list(adapt_delta = 0.95),
    file = here("models/daily/m0_biweekly_ls_bridge"), file_refit = "never"
  ))
  message("Bridge fit done.")

} else if (which_block == "rest") {

  # M0-daily, primary outcome (mirrors h1-fit)
  message("Fitting M0-daily (life_sat)...")
  invisible(brm(
    bf(life_sat ~ total_within + total_between + (1 + total_within | pid)),
    data   = model_data_ls,
    prior  = set_prior(prior_b, class = "b") +
             set_prior(prior_intercept, class = "Intercept"),
    family = gaussian(),
    chains = 4, iter = 4000, warmup = 2000, cores = 4, seed = 8675309,
    control = list(adapt_delta = 0.95),
    file = here("models/daily/m0_daily_ls"), file_refit = "never"
  ))
  message("M0-daily (life_sat) done.")

  # M0-daily, secondary outcome
  message("Fitting M0-daily (valence)...")
  invisible(brm(
    bf(affective_valence ~ total_within + total_between + (1 + total_within | pid)),
    data   = model_data_av,
    prior  = set_prior(prior_b, class = "b") +
             set_prior(prior_intercept, class = "Intercept"),
    family = gaussian(),
    chains = 4, iter = 4000, warmup = 2000, cores = 4, seed = 8675309,
    control = list(adapt_delta = 0.95),
    file = here("models/daily/m0_daily_av"), file_refit = "never"
  ))
  message("M0-daily (valence) done.")

  # M0-daily sensitivity: full frame (all responses, structural zeros as-is)
  message("Fitting M0-daily full-frame sensitivity (life_sat)...")
  invisible(brm(
    bf(life_sat ~ total_within + total_between + (1 + total_within | pid)),
    data   = frame_full |> filter(!is.na(life_sat)),
    prior  = set_prior(prior_b, class = "b") +
             set_prior(prior_intercept, class = "Intercept"),
    family = gaussian(),
    chains = 4, iter = 4000, warmup = 2000, cores = 4, seed = 8675309,
    control = list(adapt_delta = 0.95),
    file = here("models/daily/m0_daily_ls_full"), file_refit = "never"
  ))
  message("M0-daily full-frame sensitivity done.")

  # M2-daily: hierarchical prior over genre coefficients (mirrors h2-hier-fit)
  sv_hier <- stanvar(
    scode = "real<lower=0> tau_genre_within;\nreal<lower=0> tau_genre_between;",
    block = "parameters"
  ) +
  stanvar(
    scode = paste(
      sprintf("target += normal_lpdf(tau_genre_within | 0, %.3f) - normal_lccdf(0 | 0, %.3f);",
              tau_scale, tau_scale),
      sprintf("target += normal_lpdf(tau_genre_between | 0, %.3f) - normal_lccdf(0 | 0, %.3f);",
              tau_scale, tau_scale),
      sep = "\n"
    ),
    block = "model"
  )
  hier_priors_within <- do.call(c, lapply(gh_w, function(g) {
    set_prior("normal(0, tau_genre_within)", class = "b", coef = g)
  }))
  hier_priors_between <- do.call(c, lapply(gh_b, function(g) {
    set_prior("normal(0, tau_genre_between)", class = "b", coef = g)
  }))
  hier_priors <- c(
    set_prior(prior_b, class = "b"),
    set_prior(prior_intercept, class = "Intercept"),
    hier_priors_within,
    hier_priors_between
  )
  hier_rhs <- paste(c(gh_w, gh_b), collapse = " + ")

  message("Fitting M2-daily (life_sat)...")
  invisible(brm(
    bf(as.formula(paste("life_sat ~", hier_rhs, "+ (1 | pid)"))),
    data     = model_data_ls,
    prior    = hier_priors,
    stanvars = sv_hier,
    family   = gaussian(),
    chains   = 4, iter = 8000, warmup = 4000, cores = 4, seed = 2025,
    control  = list(adapt_delta = 0.999, max_treedepth = 15),
    file = here("models/daily/m2_daily_ls"), file_refit = "never"
  ))
  message("M2-daily (life_sat) done.")

  message("Fitting M2-daily (valence)...")
  invisible(brm(
    bf(as.formula(paste("affective_valence ~", hier_rhs, "+ (1 | pid)"))),
    data     = model_data_av,
    prior    = hier_priors,
    stanvars = sv_hier,
    family   = gaussian(),
    chains   = 4, iter = 8000, warmup = 4000, cores = 4, seed = 2025,
    control  = list(adapt_delta = 0.999, max_treedepth = 15),
    file = here("models/daily/m2_daily_av"), file_refit = "never"
  ))
  message("M2-daily (valence) done.")

  # Lagged direction check (frequentist): previous consecutive day's exposure.
  # Responses arrive at ~the same time daily, so the previous response's
  # 24 h window approximates the 24 h preceding today's window.
  lagged <- frame |>
    arrange(pid, day) |>
    group_by(pid) |>
    mutate(
      lag_total = lag(total_hours_24h),
      lag_gap   = day - lag(day)
    ) |>
    ungroup() |>
    filter(lag_gap == 1, !is.na(life_sat), !is.na(lag_total)) |>
    group_by(pid) |>
    mutate(
      lag_within  = lag_total - mean(lag_total),
      lag_between = mean(lag_total)
    ) |>
    ungroup()
  message(sprintf("Lagged frame: %d consecutive-day pairs, %d pids",
                  nrow(lagged), n_distinct(lagged$pid)))
  lag_fit <- lmer(life_sat ~ lag_within + lag_between + (1 | pid),
                  data = lagged, REML = TRUE,
                  control = lmerControl(optimizer = "bobyqa"))
  saveRDS(list(fit = lag_fit, n = nrow(lagged),
               n_pid = n_distinct(lagged$pid)),
          here("models/daily/lagged_lmer.rds"))
  message("Lagged lmer done. All 'rest' fits complete.")

} else {

  # M3-daily: multi-membership, primary outcome only (mirrors mm-formula-setup)
  K <- length(gh_cols)
  mm_data <- model_data_ls |>
    mutate(gh_row_total = rowSums(across(all_of(gh_cols))))
  for (i in seq_along(gh_cols)) {
    mm_data[[paste0("w_", i)]] <- ifelse(
      mm_data$gh_row_total > 0,
      mm_data[[gh_cols[i]]] / mm_data$gh_row_total,
      1 / K
    )
    mm_data[[paste0("g_", i)]] <- sub("^gh_", "", gh_cols[i])
  }
  g_cols <- paste0("g_", seq_len(K))
  w_cols <- paste0("w_", seq_len(K))
  w_sums <- rowSums(mm_data[, w_cols])
  stopifnot(all(abs(w_sums - 1) < 0.001))

  mm_term <- paste0(
    "mm(", paste(g_cols, collapse = ", "),
    ", weights = cbind(", paste(w_cols, collapse = ", "), "))"
  )
  mm_formula <- bf(paste0(
    "life_sat ~ total_within + total_between + ",
    "(1 + total_within | pid) + ",
    "(0 + total_within + total_between | ", mm_term, ")"
  ))
  mm_groups <- get_prior(mm_formula, data = mm_data) |>
    filter(grepl("^mm", group)) |>
    pull(group) |>
    unique()
  if (length(mm_groups) == 0) stop("No mm() group found in get_prior() output.")
  message(sprintf("mm() group name: %s", mm_groups[1]))

  mm_priors <- c(
    set_prior(prior_b, class = "b"),
    set_prior(prior_intercept, class = "Intercept"),
    set_prior(sprintf("normal(0, %.3f)", sigma_scale),
              class = "sd", group = mm_groups[1])
  )

  # Registered mm used iter 8000 / adapt_delta 0.999; the daily frame is 2.4x
  # larger, so the exploratory pass starts at iter 4000 / adapt_delta 0.995
  # (documented de-escalation; escalate only if diagnostics fail).
  message("Fitting M3-daily mm (life_sat)...")
  invisible(brm(
    formula = mm_formula,
    data    = mm_data,
    prior   = mm_priors,
    family  = gaussian(),
    chains  = 4, iter = 4000, warmup = 2000, cores = 4, seed = 8675309,
    control = list(adapt_delta = 0.995, max_treedepth = 15),
    file = here("models/daily/m3_daily_mm_ls"), file_refit = "never"
  ))
  message("M3-daily mm done.")
}
