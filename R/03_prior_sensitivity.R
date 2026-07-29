# =============================================================================
# Prior-sensitivity refits for the H2 heterogeneity hyperpriors (review M13)
# =============================================================================
#
# Refits M2 (hierarchical prior; tau ~ Half-Normal(0, s)) and M3
# (multi-membership; sigma_s ~ Half-Normal(0, s)) with halved and doubled
# hyperprior scales around the manuscript's choices (M2: 0.1; M3: 0.3).
# The base-scale fits are the manuscript's cached models and are not refit.
#
# Data construction replicates manuscript.qmd chunks `model-data` and
# `mm-data-setup` exactly, so results are directly comparable.
#
# NOT RUN by the manuscript. Runtime: each M2 refit ~1-3 h, each M3 refit
# ~3-8 h on 4 chains (hardware dependent) -> plan for an overnight run:
#   Rscript R/03_prior_sensitivity.R
# Fits are cached via brms `file =` under models/, so the script is safe to
# re-run/resume. A compact posterior summary is written to
# data/processed/prior_sensitivity_summary.rds for later inclusion in the
# manuscript (see notes/TODO.md).
# =============================================================================

library(here)
here::i_am("R/03_prior_sensitivity.R")

suppressPackageStartupMessages({
  library(tidyverse)
  library(brms)
  library(posterior)
})

source(here("R/01_preprocess.R"))

options(mc.cores = max(1L, parallel::detectCores() - 1L))
dir.create(here("models"), showWarnings = FALSE, recursive = TRUE)

M2_SCALES <- c(0.05, 0.2)   # manuscript uses 0.1
M3_SCALES <- c(0.15, 0.6)   # manuscript uses 0.3

# --- Replicates manuscript.qmd chunk `model-data` ----------------------------

survey <- load_survey_data()
genre_wave_long <- read_csv(here("data/processed/genre_wave_long.csv"), show_col_types = FALSE)
total_playtime  <- read_csv(here("data/processed/total_playtime.csv"),  show_col_types = FALSE)

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

analysis_data <- survey |>
  select(pid, wave, wemwbs) |>
  left_join(total_playtime |> select(pid, wave, total_hours_per_day),
            by = c("pid", "wave")) |>
  left_join(genre_hours_wide, by = c("pid", "wave")) |>
  mutate(
    total_hours_per_day = replace_na(total_hours_per_day, 0),
    across(all_of(gh_vars), ~ replace_na(.x, 0))
  ) |>
  group_by(pid) |>
  mutate(
    total_within  = total_hours_per_day - mean(total_hours_per_day, na.rm = TRUE),
    total_between = mean(total_hours_per_day, na.rm = TRUE),
    across(all_of(gh_vars),
           list(within  = ~ .x - mean(.x, na.rm = TRUE),
                between = ~ mean(.x, na.rm = TRUE)),
           .names = "{.col}_{.fn}")
  ) |>
  ungroup()

gh_within  <- paste0(gh_vars, "_within")
gh_between <- paste0(gh_vars, "_between")

# --- Replicates manuscript.qmd chunk `mm-data-setup` -------------------------

genre_cols_mm <- sort(gh_vars)
K <- length(genre_cols_mm)

mm_data <- analysis_data |>
  rowwise() |>
  mutate(gh_row_total = sum(c_across(all_of(gh_vars)))) |>
  ungroup()

for (i in seq_along(genre_cols_mm)) {
  w_col  <- paste0("w_", i)
  gh_col <- genre_cols_mm[i]
  mm_data[[w_col]] <- ifelse(mm_data$gh_row_total > 0,
                             mm_data[[gh_col]] / mm_data$gh_row_total, 1 / K)
}
for (i in seq_along(genre_cols_mm)) {
  mm_data[[paste0("g_", i)]] <- sub("^gh_", "", genre_cols_mm[i])
}
g_cols <- paste0("g_", seq_len(K))
w_cols <- paste0("w_", seq_len(K))

mm_term <- paste0("mm(", paste(g_cols, collapse = ", "),
                  ", weights = cbind(", paste(w_cols, collapse = ", "), "))")
h2_mm_formula <- bf(paste0(
  "wemwbs ~ total_within + total_between + ",
  "(1 + total_within | pid) + ",
  "(0 + total_within + total_between | ", mm_term, ")"
))

mm_groups <- get_prior(h2_mm_formula, data = mm_data |> filter(!is.na(wemwbs))) |>
  filter(grepl("^mm", group)) |>
  pull(group) |>
  unique()
stopifnot(length(mm_groups) >= 1)
mm_group_name <- mm_groups[1]

# --- M2 refits: tau ~ Half-Normal(0, s) --------------------------------------

sv_hier_scale <- function(s) {
  stanvar(scode = "real<lower=0> tau_genre_within;\nreal<lower=0> tau_genre_between;",
          block = "parameters") +
  stanvar(scode = paste(
    sprintf("target += normal_lpdf(tau_genre_within | 0, %s) - normal_lccdf(0 | 0, %s);", s, s),
    sprintf("target += normal_lpdf(tau_genre_between | 0, %s) - normal_lccdf(0 | 0, %s);", s, s),
    sep = "\n"), block = "model")
}

h2_hier_formula <- bf(paste(
  "wemwbs ~", paste(c(gh_within, gh_between), collapse = " + "), "+ (1 | pid)"
))

hier_priors <- c(
  set_prior("student_t(3, 0, 0.5)", class = "b"),
  set_prior("student_t(3, 3, 2)",   class = "Intercept"),
  do.call(c, lapply(gh_within,  \(g) set_prior("normal(0, tau_genre_within)",  class = "b", coef = g))),
  do.call(c, lapply(gh_between, \(g) set_prior("normal(0, tau_genre_between)", class = "b", coef = g)))
)

m2_fits <- list()
for (s in M2_SCALES) {
  tag <- gsub("\\.", "p", sprintf("%.2f", s))
  message(sprintf("=== M2 refit: tau ~ Half-Normal(0, %.2f) ===", s))
  m2_fits[[as.character(s)]] <- brm(
    formula  = h2_hier_formula,
    data     = analysis_data |> filter(!is.na(wemwbs)),
    prior    = hier_priors,
    stanvars = sv_hier_scale(s),
    family   = gaussian(),
    chains   = 4, iter = 8000, warmup = 4000, seed = 2025,
    control  = list(adapt_delta = 0.999, max_treedepth = 15),
    file     = here(sprintf("models/prior_sens_m2_tau%s", tag))
  )
}

# --- M3 refits: sigma_s ~ Half-Normal(0, s) ----------------------------------

m3_fits <- list()
for (s in M3_SCALES) {
  tag <- gsub("\\.", "p", sprintf("%.2f", s))
  message(sprintf("=== M3 refit: sigma_s ~ Half-Normal(0, %.2f) ===", s))
  m3_fits[[as.character(s)]] <- brm(
    formula = h2_mm_formula,
    data    = mm_data |> filter(!is.na(wemwbs)),
    prior   = c(
      set_prior("student_t(3, 0, 0.5)", class = "b"),
      set_prior("student_t(3, 3, 2)",   class = "Intercept"),
      set_prior(sprintf("normal(0, %s)", s), class = "sd", group = mm_group_name)
    ),
    family  = gaussian(),
    chains  = 4, iter = 8000, warmup = 4000, seed = 8675309,
    control = list(adapt_delta = 0.999, max_treedepth = 15),
    file    = here(sprintf("models/prior_sens_m3_sigma%s", tag))
  )
}

# --- Summaries ---------------------------------------------------------------

summarise_tau <- function(fit, par) {
  d <- as_draws_df(fit)[[par]]
  tibble(mean = mean(d), median = median(d),
         q2.5 = quantile(d, .025), q97.5 = quantile(d, .975),
         p_below_sesoi = mean(d < 0.06))
}

# NOTE: the imap() results are named lists of tibbles; they must be
# concatenated with c() into ONE list before bind_rows(), otherwise dplyr
# mis-handles the multiple named-list arguments and drops the columns.
summary_tbl <- bind_rows(c(
  imap(m2_fits, \(f, s) summarise_tau(f, "tau_genre_within") |>
         mutate(model = "M2", parameter = "tau_within", scale = as.numeric(s))),
  imap(m2_fits, \(f, s) summarise_tau(f, "tau_genre_between") |>
         mutate(model = "M2", parameter = "tau_between", scale = as.numeric(s))),
  imap(m3_fits, \(f, s) {
    dn <- names(as_draws_df(f))
    sw <- grep(paste0("sd_", mm_group_name, ".*total_within"),  dn, value = TRUE)[1]
    sb <- grep(paste0("sd_", mm_group_name, ".*total_between"), dn, value = TRUE)[1]
    bind_rows(
      summarise_tau(f, sw) |> mutate(parameter = "sigma_s_within"),
      summarise_tau(f, sb) |> mutate(parameter = "sigma_s_between")
    ) |> mutate(model = "M3", scale = as.numeric(s))
  })
)) |>
  relocate(model, parameter, scale)

dir.create(here("data/processed"), showWarnings = FALSE, recursive = TRUE)
saveRDS(summary_tbl, here("data/processed/prior_sensitivity_summary.rds"))
message("Saved summary to data/processed/prior_sensitivity_summary.rds")
print(as.data.frame(summary_tbl), digits = 3)
message("Done. Compare against the manuscript's base fits (scales 0.1 / 0.3).")
