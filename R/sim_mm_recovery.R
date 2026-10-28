# =============================================================================
# Parameter-recovery simulation for the multi-membership model M4
# =============================================================================
#
# Engine behind R/sim_mm_recovery_report.qmd (2026-10-14). It replaces the
# pre-2026-10-13 simulation, which fitted a within-person genre slope only
# under the old priors (student_t(3, 0, 0.5) on b, student_t(3, 3, 2) on the
# Intercept, normal(0, 0.1) on the mm sd).
#
# Identical model code. The synthetic data are fitted with the manuscript's own
# chunk code: manuscript.qmd is purled at run time (the pattern of
# R/fit_main_models.R) and four chunks are evaluated on simulated input in the
# same shape as the real input:
#   model-data        builds analysis_data (person-mean centring) from
#                     `survey`, `total_playtime` and `genre_wave_long`
#   mm-data-setup     builds the constant genre columns g_1..g_K and the
#                     weights w_1..w_K (genre share of the wave's summed
#                     genre exposure; 1/K for waves without genre-labelled play)
#   mm-formula-setup  builds h2_mm_formula: within- AND between-person genre
#                     slope adjustments, drawn jointly (LKJ(1) correlation)
#   h2-mm-fit         the brm() call (no prior argument, so brms defaults;
#                     same family, chains and control). Only `iter`/`warmup`
#                     (SIM_ITER), `seed` (per replication) and `file` (no fit
#                     is written to models/) are overridden.
# Outcome values are generated after mm-data-setup because the
# data-generating process needs the centred predictors and the weights; the
# chunks do not use the outcome except to drop missing waves.
#
# Usage (from the repo root):
#   Rscript R/sim_mm_recovery.R
#   SIM_RENDER=1 Rscript R/sim_mm_recovery.R      # also renders the report (html)
# Two processes can share the replications (about 20 min each at 8000
# iterations), e.g. in two terminals:
#   SIM_REPS=20 SIM_ITER=8000 SIM_REP_RANGE=1:10  SIM_RENDER=1 Rscript R/sim_mm_recovery.R
#   SIM_REPS=20 SIM_ITER=8000 SIM_REP_RANGE=11:20 SIM_RENDER=1 Rscript R/sim_mm_recovery.R
# Whichever process finds all SIM_REPS replications on disk writes the
# summary files and renders the report; the other exits with status 0.
#
# Environment switches:
#   SIM_REPS           number of replications (default 1, as in the
#                      pre-2026-10-13 report). Replications already on disk
#                      with the same settings are skipped (resumable).
#   SIM_ITER           iterations per chain (default 4000, warmup = SIM_ITER/2;
#                      the manuscript fit uses 8000/4000). Reduced for speed.
#   SIM_SEED           base seed for the data (default 42); replication r uses
#                      SIM_SEED * 1000 + r, and brm() uses the chunk seed + r.
#   SIM_OUT_DIR        output directory (default data/processed/sim_recovery)
#   SIM_STANCODE_ONLY  1 = build replication 1, write its Stan code and default
#                      priors, and stop before any sampling.
#   SIM_RENDER         1 = render R/sim_mm_recovery_report.qmd to html at the end.
#   SIM_REP_RANGE      "a:b" = fit only replications a..b (1 <= a <= b <=
#                      SIM_REPS), so that several processes can share the
#                      replications. The summary files and the report are
#                      written only when all SIM_REPS replication files exist;
#                      otherwise the run says which are missing and exits 0.
#                      Default: all replications.
#
# Outputs (SIM_OUT_DIR):
#   reps/rep_NNN.rds        per replication: summaries, genre-level estimates,
#                           draws of the three genre hyperparameters, diagnostics
#   recovery_summary.csv    one row per parameter (true, mean, ci_lo, ci_hi,
#                           covered, n_reps, n_covered, coverage, bias, rmse)
#   recovery_by_rep.csv     one row per replication x parameter
#   genre_recovery.csv      one row per replication x genre x slope type
#   diagnostics.csv         one row per replication
#   run_info.rds            settings, true values, manuscript md5, chunk code
#   stancode_sim_m4.stan, default_prior_sim_m4.csv, chunks_used.R
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(brms)
  library(tidyverse)
})
here::i_am("R/sim_mm_recovery.R")
setwd(here())

# Stan backend, as in the manuscript's setup chunk (which this script does not
# evaluate): CmdStan through cmdstanr with 3 threads per chain. Computation
# time only; the h2-mm-fit chunk code is used unchanged.
stopifnot(requireNamespace("cmdstanr", quietly = TRUE))
options(brms.backend = "cmdstanr", brms.threads = brms::threading(3))

ts  <- function() format(Sys.time(), "%Y-%m-%d %H:%M:%S")
say <- function(...) message(sprintf("[%s] %s", ts(), sprintf(...)))

env_int <- function(name, default) {
  v <- Sys.getenv(name, "")
  if (nzchar(v)) as.integer(v) else as.integer(default)
}
n_reps        <- env_int("SIM_REPS", 1)
sim_iter      <- env_int("SIM_ITER", 4000)
sim_warmup    <- sim_iter %/% 2L
seed_base     <- env_int("SIM_SEED", 42)
out_dir       <- Sys.getenv("SIM_OUT_DIR", here("data/processed/sim_recovery"))
stancode_only <- identical(Sys.getenv("SIM_STANCODE_ONLY"), "1")
do_render     <- identical(Sys.getenv("SIM_RENDER"), "1")
stopifnot(n_reps >= 1, sim_iter >= 1000)
rep_range_env <- trimws(Sys.getenv("SIM_REP_RANGE", ""))
if (nzchar(rep_range_env)) {
  m <- regmatches(rep_range_env,
                  regexec("^([0-9]+)[[:space:]]*:[[:space:]]*([0-9]+)$", rep_range_env))[[1]]
  if (length(m) != 3) stop("SIM_REP_RANGE must look like 1:10, got '", rep_range_env, "'")
  rep_from <- as.integer(m[2])
  rep_to   <- as.integer(m[3])
  if (!(rep_from >= 1L && rep_from <= rep_to && rep_to <= n_reps)) {
    stop(sprintf("SIM_REP_RANGE=%s must satisfy 1 <= a <= b <= SIM_REPS (%d)",
                 rep_range_env, n_reps))
  }
  rep_range <- seq(rep_from, rep_to)
} else {
  rep_range <- seq_len(n_reps)
}
dir.create(file.path(out_dir, "reps"), recursive = TRUE, showWarnings = FALSE)

# Write through a temporary file and rename it into place, so that a process
# sharing out_dir (SIM_REP_RANGE) or a resumed run never reads a half-written
# file.
write_atomic <- function(path, writer) {
  tmp <- sprintf("%s.tmp-%d", path, Sys.getpid())
  writer(tmp)
  if (!file.rename(tmp, path)) stop("could not move ", tmp, " to ", path)
  invisible(path)
}

# --- True values ---------------------------------------------------------------
# Scale: SWEMWBS item mean (1-5). Values carried over from the pre-2026-10-13
# report where they exist; sigma_s_between, rho_s and rho_u are new.
n_persons <- 200L
n_waves   <- 6L
truth <- list(
  intercept       = 3.32,   # real-data mean SWEMWBS (v1.3.0: 3.322; was 3, the scale midpoint)
  beta_within     = 0,
  beta_between    = -0.015,
  sigma_u0        = 0.6,    # person intercept SD
  sigma_u1        = 0.02,   # person slope SD
  rho_u           = 0,      # person intercept-slope correlation
  sigma_s_within  = 0.04,   # SD of genre adjustments to the within-person slope
  sigma_s_between = 0.04,   # SD of genre adjustments to the between-person slope
  rho_s           = 0.3,    # correlation of the two genre adjustments
  sigma           = 0.7     # residual SD
)

# The 14 genre slugs of the real data (chunk model-data), with the share of
# real fitted person-waves (v1.3.0, N = 6,518) that include play in each genre.
# The constants below were computed on 2026-10-17 from the analytic sample, as
# in chunks model-data and mm-data-setup; the v1.2.6 values (N = 6,293) are in
# data/archive/processed_v126/sim_recovery/run_info.rds.
genre_share <- c(
  adventure = 0.579, arcade = 0.151, fighting = 0.085,
  hack_and_slash_beat_em_up = 0.100, platform = 0.171, point_and_click = 0.026,
  puzzle = 0.249, racing = 0.101, role_playing_rpg = 0.508, shooter = 0.447,
  simulator = 0.448, sport = 0.117, strategy = 0.521, visual_novel = 0.039
)
p_labelled   <- 0.835  # real share of person-waves with genre-labelled play
p_unlabelled <- 0.008  # play without any genre label (real: 0.013 of waves,
                       # 0.015 of waves with play); half the latter rate, so
                       # the chunk guard (< 10% of uniform-weight waves with
                       # play) rarely fails. It still fails for 5 of the
                       # first 150 input draws (4 with the v1.2.6 constants,
                       # e.g. replication 10), so build_replication() redraws
                       # such inputs.
p_missing_y  <- 0      # waves with an incomplete SWEMWBS (real: none of the
                       # 6,518 in v1.3.0, which ships no unanswered SWEMWBS;
                       # 0.0055 in v1.2.6)

# --- Manuscript chunks -------------------------------------------------------
ms_path   <- here("manuscript.qmd")
ms_md5    <- unname(tools::md5sum(ms_path))
purl_file <- tempfile("manuscript_purled_", fileext = ".R")
invisible(knitr::purl(ms_path, output = purl_file, documentation = 1, quiet = TRUE))
lines  <- readLines(purl_file, warn = FALSE)
starts <- grep("^## ----", lines)
ends   <- c(starts[-1] - 1L, length(lines))
chunks <- Map(function(s, e) lines[(s + 1L):e], starts, ends)
labels <- vapply(chunks, function(code) {
  hit <- grep("^#\\|\\s*label:", code, value = TRUE)
  if (length(hit) == 0) NA_character_ else trimws(sub("^#\\|\\s*label:\\s*", "", hit[1]))
}, character(1))
names(chunks) <- labels
use_labels <- c("model-data", "mm-data-setup", "mm-formula-setup", "h2-mm-fit")
stopifnot(all(use_labels %in% labels))
chunks_txt <- unlist(lapply(use_labels, function(l) c(sprintf("## ---- %s", l), chunks[[l]], "")))
write_atomic(file.path(out_dir, "chunks_used.R"), function(p) writeLines(chunks_txt, p))
chunk_md5 <- unname(tools::md5sum(file.path(out_dir, "chunks_used.R")))
say("manuscript.qmd md5 %s; chunks %s md5 %s", ms_md5, paste(use_labels, collapse = ", "),
    chunk_md5)

# The brm() call of h2-mm-fit, taken apart so that only iter/warmup/seed/file
# change. The chunk must hold exactly `h2_mm_model <- brm(...)` without a prior
# argument (the report states that brms defaults are used).
fit_expr <- parse(text = chunks[["h2-mm-fit"]], keep.source = FALSE)
stopifnot(length(fit_expr) == 1, identical(fit_expr[[1]][[1]], as.name("<-")))
brm_call <- fit_expr[[1]][[3]]
stopifnot(identical(brm_call[[1]], as.name("brm")), is.null(brm_call$prior),
          all(c("formula", "data", "family", "chains", "iter", "warmup", "seed", "control")
              %in% names(brm_call)))
ms_sampler <- list(chains = eval(brm_call$chains), iter = eval(brm_call$iter),
                   warmup = eval(brm_call$warmup), seed = eval(brm_call$seed),
                   control = eval(brm_call$control))

settings <- list(
  n_persons = n_persons, n_waves = n_waves, truth = truth, genre_share = genre_share,
  p_labelled = p_labelled, p_unlabelled = p_unlabelled, p_missing_y = p_missing_y,
  sim_iter = sim_iter, sim_warmup = sim_warmup, seed_base = seed_base,
  chunk_md5 = chunk_md5, guard_redraw = "seed + 100000 * attempt, max 20"
)
settings_key <- rlang::hash(settings)

# --- Data-generating process ---------------------------------------------------
# Simulated input in the shape of the real input to chunk model-data:
#   survey          (pid, wave, wemwbs)  wemwbs = 0 placeholder, NA if missing
#   total_playtime  (pid, wave, total_hours_per_day), waves with play only
#   genre_wave_long (pid, wave, genre, hours_per_day), genre exposure > 0 only
# Genre exposure is non-exclusive as in the real data (a game carries several
# labels), so the summed genre hours of a wave exceed its playtime (about 2x).
simulate_inputs <- function(seed) {
  set.seed(seed)
  K <- length(genre_share)
  persons <- tibble(
    pid    = seq_len(n_persons),
    m      = rlnorm(n_persons, log(1.25), 0.8),   # habitual hours/day
    p_play = rbeta(n_persons, 5, 0.8)             # share of waves with play
  )
  # Person-specific genre propensities around the real inclusion rates
  base_logit <- qlogis(pmin(genre_share / p_labelled, 0.95))
  q <- plogis(matrix(base_logit, n_persons, K, byrow = TRUE) +
                matrix(rnorm(n_persons * K, 0, 1.5), n_persons, K))
  waves <- expand_grid(pid = seq_len(n_persons), wave = seq_len(n_waves)) |>
    left_join(persons, by = "pid") |>
    mutate(
      play  = rbinom(n(), 1, p_play) == 1,
      hours = ifelse(play, m * exp(rnorm(n(), -0.125, 0.5)), 0),
      unlabelled = play & rbinom(n(), 1, p_unlabelled / p_labelled) == 1
    )
  gh <- matrix(0, nrow(waves), K, dimnames = list(NULL, names(genre_share)))
  for (r in which(waves$play & !waves$unlabelled)) {
    qi  <- q[waves$pid[r], ]
    inc <- rbinom(K, 1, qi) == 1
    if (!any(inc)) inc[sample.int(K, 1, prob = qi)] <- TRUE
    gh[r, inc] <- waves$hours[r] * rbeta(sum(inc), 2, 2)
  }
  survey <- waves |>
    transmute(pid, wave, wemwbs = ifelse(rbinom(n(), 1, p_missing_y) == 1, NA_real_, 0))
  total_playtime <- waves |>
    filter(play) |>
    transmute(pid, wave, total_hours_per_day = hours)
  genre_wave_long <- bind_cols(waves |> select(pid, wave), as_tibble(gh)) |>
    pivot_longer(-c(pid, wave), names_to = "genre", values_to = "hours_per_day") |>
    filter(hours_per_day > 0)
  list(survey = survey, total_playtime = total_playtime, genre_wave_long = genre_wave_long)
}

# Run the manuscript chunks on one simulated input, then generate the outcome.
# An input that fails the guard of mm-data-setup (stopifnot on
# n_mm_uniform_play / n_mm_uniform < 0.1) is redrawn with the seed
# seed_base * 1000 + rep + 100000 * attempt; any other error stops the run.
build_replication <- function(rep, max_attempts = 20L) {
  for (attempt in seq_len(max_attempts) - 1L) {
    inp <- simulate_inputs(seed_base * 1000L + rep + 100000L * attempt)
    env <- new.env(parent = globalenv())
    for (nm in names(inp)) assign(nm, inp[[nm]], envir = env)
    ok <- tryCatch({
      for (lab in c("model-data", "mm-data-setup", "mm-formula-setup")) {
        suppressMessages(eval(parse(text = chunks[[lab]], keep.source = FALSE), envir = env))
      }
      TRUE
    }, error = function(e) {
      if (grepl("n_mm_uniform_play", conditionMessage(e), fixed = TRUE)) FALSE else stop(e)
    })
    if (ok) break
    say("replication %d: input draw %d fails the mm-data-setup guard; redrawn", rep, attempt + 1L)
  }
  if (!ok) stop(sprintf("replication %d: no input passed the mm-data-setup guard in %d draws",
                        rep, max_attempts))
  mm_data <- env$mm_data
  g_cols  <- env$g_cols
  w_cols  <- env$w_cols
  stopifnot(env$K == length(genre_share))
  genres <- vapply(g_cols, function(g) unique(mm_data[[g]]), character(1))
  stopifnot(setequal(genres, names(genre_share)))

  # Genre slope adjustments: bivariate normal (within, between)
  S <- matrix(c(truth$sigma_s_within^2,
                truth$rho_s * truth$sigma_s_within * truth$sigma_s_between,
                truth$rho_s * truth$sigma_s_within * truth$sigma_s_between,
                truth$sigma_s_between^2), 2, 2)
  s <- MASS::mvrnorm(length(genres), c(0, 0), S)
  genre_true <- tibble(genre = genres, total_within = s[, 1], total_between = s[, 2])
  # Person intercepts and within-person slopes
  U <- matrix(c(truth$sigma_u0^2, truth$rho_u * truth$sigma_u0 * truth$sigma_u1,
                truth$rho_u * truth$sigma_u0 * truth$sigma_u1, truth$sigma_u1^2), 2, 2)
  u <- MASS::mvrnorm(n_persons, c(0, 0), U)

  W  <- as.matrix(mm_data[, w_cols])
  tw <- mm_data$total_within
  tb <- mm_data$total_between
  pidx <- match(mm_data$pid, seq_len(n_persons))
  y  <- truth$intercept + truth$beta_within * tw + truth$beta_between * tb +
    u[pidx, 1] + u[pidx, 2] * tw +
    drop(W %*% genre_true$total_within) * tw +
    drop(W %*% genre_true$total_between) * tb +
    rnorm(nrow(mm_data), 0, truth$sigma)
  obs <- !is.na(mm_data$wemwbs)
  mm_data$wemwbs <- ifelse(obs, y, NA_real_)
  assign("mm_data", mm_data, envir = env)
  list(env = env, genre_true = genre_true,
       n_obs = sum(obs), n_uniform = env$n_mm_uniform,
       n_uniform_play = env$n_mm_uniform_play, n_input_draws = attempt + 1L)
}

sim_call <- function(rep) {
  cl <- brm_call
  cl[[1]]   <- quote(brms::brm)
  cl$iter   <- sim_iter
  cl$warmup <- sim_warmup
  cl$seed   <- ms_sampler$seed + rep
  cl$file   <- NULL
  cl
}

# Parameters judged for recovery (brms names depend on the mm group name)
param_table <- function(mm_group) {
  tibble(
    parameter = c("b_Intercept", "b_total_within", "b_total_between",
                  "sd_pid__Intercept", "sd_pid__total_within",
                  "cor_pid__Intercept__total_within",
                  sprintf("sd_%s__total_within", mm_group),
                  sprintf("sd_%s__total_between", mm_group),
                  sprintf("cor_%s__total_within__total_between", mm_group),
                  "sigma"),
    label = c("Intercept", "beta_within", "beta_between", "sigma_u0", "sigma_u1",
              "rho_u", "sigma_s_within", "sigma_s_between", "rho_s", "sigma"),
    true  = unlist(truth[c("intercept", "beta_within", "beta_between", "sigma_u0",
                           "sigma_u1", "rho_u", "sigma_s_within", "sigma_s_between",
                           "rho_s", "sigma")])
  )
}

# --- Stan code of replication 1 (no sampling) ----------------------------------
b1 <- build_replication(1L)
sc_call <- as.call(c(quote(brms::make_stancode),
                     as.list(brm_call)[c("formula", "data", "family")]))
stancode <- eval(sc_call, envir = b1$env)
write_atomic(file.path(out_dir, "stancode_sim_m4.stan"), function(p) writeLines(stancode, p))
dp_call <- sc_call
dp_call[[1]] <- quote(brms::default_prior)
names(dp_call)[names(dp_call) == "formula"] <- "object"  # default_prior()'s first argument
dp <- eval(dp_call, envir = b1$env)
write_atomic(file.path(out_dir, "default_prior_sim_m4.csv"),
             function(p) write_csv(as_tibble(as.data.frame(dp)), p))
say("replication 1: %d fitted rows, %d uniform-weight waves (%d with play); mm group %s",
    b1$n_obs, b1$n_uniform, b1$n_uniform_play, b1$env$mm_group_name)

run_info <- c(settings, list(
  date = as.character(Sys.Date()), manuscript_md5 = ms_md5, chunk_labels = use_labels,
  ms_sampler = ms_sampler, mm_group_name = b1$env$mm_group_name,
  formula = paste(deparse(b1$env$h2_mm_formula$formula, width.cutoff = 500), collapse = ""),
  brms_version = as.character(packageVersion("brms")), n_reps_requested = n_reps,
  settings_key = settings_key
))
write_atomic(file.path(out_dir, "run_info.rds"), function(p) saveRDS(run_info, p))

if (stancode_only) {
  say("SIM_STANCODE_ONLY=1: wrote Stan code and default priors to %s; no sampling", out_dir)
  quit(save = "no", status = 0)
}

# --- Replications --------------------------------------------------------------
rep_file <- function(rep) file.path(out_dir, "reps", sprintf("rep_%03d.rds", rep))

say("replications to run in this process: %d-%d of %d", min(rep_range), max(rep_range), n_reps)
for (rep in rep_range) {
  f <- rep_file(rep)
  if (file.exists(f)) {
    old <- readRDS(f)
    if (identical(old$settings_key, settings_key)) {
      say("replication %d: on disk with the same settings, skipped", rep)
      next
    }
    stop(sprintf(paste0("%s was written with other settings (or other manuscript chunks). ",
                        "Move %s/reps aside and re-run."), f, out_dir))
  }
  b <- if (rep == 1L) b1 else build_replication(rep)
  say("replication %d: fitting (%d rows, %d chains x %d iterations, %d warmup)",
      rep, b$n_obs, ms_sampler$chains, sim_iter, sim_warmup)
  t0  <- Sys.time()
  fit <- eval(sim_call(rep), envir = b$env)
  wall_min <- as.numeric(difftime(Sys.time(), t0, units = "mins"))

  mm_group <- b$env$mm_group_name
  pt <- param_table(mm_group)
  draws <- posterior::as_draws_df(fit)
  stopifnot(all(pt$parameter %in% names(draws)))
  summ <- posterior::summarise_draws(
    posterior::subset_draws(draws, variable = pt$parameter),
    mean, ~ quantile(.x, c(0.025, 0.975)), "rhat", "ess_bulk", "ess_tail"
  )
  rec <- pt |>
    left_join(summ |> rename(parameter = variable, ci_lo = `2.5%`, ci_hi = `97.5%`),
              by = "parameter") |>
    mutate(rep = rep, covered = true >= ci_lo & true <= ci_hi, .before = 1)

  re_all <- ranef(fit)
  re_key <- if (mm_group %in% names(re_all)) mm_group else grep("^mm", names(re_all), value = TRUE)[1]
  re <- re_all[[re_key]]
  stopifnot(!is.null(re), all(c("total_within", "total_between") %in% dimnames(re)[[3]]))
  genre_rec <- map_dfr(c("total_within", "total_between"), function(cf) {
    tibble(genre = dimnames(re)[[1]], slope = cf,
           mean = re[, "Estimate", cf], ci_lo = re[, "Q2.5", cf], ci_hi = re[, "Q97.5", cf])
  }) |>
    left_join(b$genre_true |> pivot_longer(-genre, names_to = "slope", values_to = "true"),
              by = c("genre", "slope")) |>
    mutate(rep = rep, covered = true >= ci_lo & true <= ci_hi, .before = 1)

  hyper <- pt$parameter[pt$label %in% c("sigma_s_within", "sigma_s_between", "rho_s")]
  hyper_draws <- as_tibble(as.data.frame(draws)[, hyper])
  names(hyper_draws) <- pt$label[match(hyper, pt$parameter)]

  diag <- tibble(
    rep = rep, n_obs = b$n_obs, n_uniform = b$n_uniform, n_uniform_play = b$n_uniform_play,
    n_input_draws = b$n_input_draws,
    max_rhat = max(brms::rhat(fit), na.rm = TRUE),
    n_divergent = sum(subset(brms::nuts_params(fit), Parameter == "divergent__")$Value),
    n_max_treedepth = sum(subset(brms::nuts_params(fit), Parameter == "treedepth__")$Value >=
                            ms_sampler$control$max_treedepth),
    min_ess_bulk = min(rec$ess_bulk), min_ess_tail = min(rec$ess_tail),
    chain_minutes_max = tryCatch(max(rowSums(rstan::get_elapsed_time(fit$fit))) / 60,
                                  error = function(e) NA_real_),
    wall_minutes = wall_min
  )
  write_atomic(f, function(p) saveRDS(list(settings_key = settings_key, recovery = rec,
                                            genre = genre_rec, hyper_draws = hyper_draws,
                                            diagnostics = diag), p))
  say("replication %d: done in %.1f min; %d of %d parameters covered; %d divergent; max R-hat %.3f",
      rep, wall_min, sum(rec$covered), nrow(rec), diag$n_divergent, diag$max_rhat)
  rm(fit, draws, re, re_all)
  invisible(gc())
}

# --- Aggregate -----------------------------------------------------------------
# Only the run that finds every replication on disk writes the summaries and
# renders the report (with SIM_REP_RANGE, the process that finishes last).
missing_reps <- which(!file.exists(vapply(seq_len(n_reps), rep_file, character(1))))
if (length(missing_reps)) {
  say("%d of %d replications are not on disk yet (missing: %s); the summary and the report are left to the run that completes the last one",
      length(missing_reps), n_reps, paste(missing_reps, collapse = ", "))
  quit(save = "no", status = 0)
}
# One writer at a time: a lock directory holding the writer's pid (a lock left
# by a process that no longer runs is removed).
lock_dir <- file.path(out_dir, "aggregate.lock")
if (!dir.create(lock_dir, showWarnings = FALSE)) {
  holder <- suppressWarnings(as.integer(readLines(file.path(lock_dir, "pid"), warn = FALSE)[1]))
  if (!is.na(holder) && isTRUE(tools::pskill(holder, 0L))) {
    say("process %d is already writing the summary and the report; nothing left to do", holder)
    quit(save = "no", status = 0)
  }
  unlink(lock_dir, recursive = TRUE)
  if (!dir.create(lock_dir, showWarnings = FALSE)) stop("could not create ", lock_dir)
}
writeLines(as.character(Sys.getpid()), file.path(lock_dir, "pid"))

reps <- lapply(seq_len(n_reps), function(r) readRDS(rep_file(r)))
# Files outside this process's SIM_REP_RANGE were not checked in the loop.
other_settings <- which(!vapply(reps, function(x) identical(x$settings_key, settings_key),
                                logical(1)))
if (length(other_settings)) {
  unlink(lock_dir, recursive = TRUE)
  stop(sprintf(paste0("replication file(s) %s were written with other settings (or other ",
                      "manuscript chunks). Move %s/reps aside and re-run."),
               paste(other_settings, collapse = ", "), out_dir))
}
by_rep <- bind_rows(lapply(reps, `[[`, "recovery"))
write_csv(by_rep, file.path(out_dir, "recovery_by_rep.csv"))
write_csv(bind_rows(lapply(reps, `[[`, "genre")), file.path(out_dir, "genre_recovery.csv"))
write_csv(bind_rows(lapply(reps, `[[`, "diagnostics")), file.path(out_dir, "diagnostics.csv"))

# One row per parameter. With one replication, mean/ci_lo/ci_hi/covered are that
# fit's; with several, mean/ci_lo/ci_hi are averages over replications and
# covered is TRUE only if every replication covered the true value.
summary_tbl <- by_rep |>
  group_by(parameter, label, true) |>
  summarise(
    bias = mean(mean - true), rmse = sqrt(mean((mean - true)^2)),
    ci_lo = mean(ci_lo), ci_hi = mean(ci_hi),
    n_reps = n(), n_covered = sum(covered), coverage = mean(covered),
    covered = all(covered), mean = mean(mean),  # after the lines that use the per-rep values
    .groups = "drop"
  ) |>
  arrange(match(label, param_table("x")$label)) |>
  select(parameter, label, true, mean, ci_lo, ci_hi, covered, n_reps, n_covered,
         coverage, bias, rmse)
write_csv(summary_tbl, file.path(out_dir, "recovery_summary.csv"))
say("wrote %s (%d parameters, %d replications)", file.path(out_dir, "recovery_summary.csv"),
    nrow(summary_tbl), n_reps)

if (do_render) {
  say("rendering R/sim_mm_recovery_report.qmd (html)")
  status <- system2("quarto", c("render", "R/sim_mm_recovery_report.qmd", "--to", "html"))
  if (status != 0) {
    unlink(lock_dir, recursive = TRUE)
    stop("quarto render failed")
  }
}
unlink(lock_dir, recursive = TRUE)
say("sim_mm_recovery.R finished")
