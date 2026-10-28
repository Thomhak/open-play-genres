# =============================================================================
# Precompute LOO for one main model (M1-M4) in its own R process
# =============================================================================
#
# The manuscript chunk `loo-comparison` reads models/loo_{h1,h2_fe,h2_mm,
# h2_hier}.rds when all four exist, and otherwise computes LOO with all four
# fits loaded, which builds draws x observations log-likelihood matrices on top
# of ~6 GB of fits (the memory problem noted in CLAUDE.md). This script loads
# ONE fit, computes loo(), saves it, and exits, so peak memory is one fit plus
# its log-likelihood matrix (about 2-3 GB for M1/M2, 4-5 GB for M3/M4).
#
# Usage (from the repo root; normally called by scripts/refit_v130.sh):
#   Rscript R/05_loo.R h1|h2_fe|h2_hier|h2_mm
#
# Contract with the manuscript chunk `loo-comparison`:
#   - file name   models/loo_<key>.rds
#   - attr(, "model_name") is the manuscript's object name (h1_model,
#     h2_model, h2_hier_model, h2_mm_model); loo_compare() row names and the
#     table labels (grepl("h2_model$"), ...) depend on it
#   - nrow(pointwise) equals nobs() of the fit
# The output is skipped when it is newer than the fit it was computed from,
# and recomputed otherwise (a refit makes an older LOO file stale).
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(brms)
  library(loo)
})
here::i_am("R/05_loo.R")
source(here("R/01_preprocess.R"))  # load_survey_data(), analytic_pids()

SPEC <- list(
  h1      = c(fit = "h1_rewb_model",    name = "h1_model"),
  h2_fe   = c(fit = "h2_genre_model",   name = "h2_model"),
  h2_hier = c(fit = "h2_hier_model_v4", name = "h2_hier_model"),  # non-centred M3 (2026-10-14)
  h2_mm   = c(fit = "h2_mm_model_full", name = "h2_mm_model")
)

key <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(key) || !key %in% names(SPEC)) {
  stop("Argument must be one of: ", paste(names(SPEC), collapse = ", "))
}
fit_path <- here("models", paste0(SPEC[[key]][["fit"]], ".rds"))
out_path <- here("models", paste0("loo_", key, ".rds"))
name     <- SPEC[[key]][["name"]]
say <- function(...) message(sprintf("[%s] %s", format(Sys.time(), "%H:%M:%S"),
                                     sprintf(...)))

if (!file.exists(fit_path)) stop("fit not found: ", fit_path)
if (file.exists(out_path) && file.mtime(out_path) > file.mtime(fit_path)) {
  say("%s is newer than %s; nothing to do", basename(out_path), basename(fit_path))
  quit(save = "no", status = 0)
}

# Expected sample: waves with an observed SWEMWBS in the current analytic
# sample (as in manuscript chunk model-data: n_analysis_obs, n_analysis_pids).
survey   <- load_survey_data()
exp_obs  <- sum(!is.na(survey$wemwbs))
exp_pids <- unique(survey$pid[!is.na(survey$wemwbs)])
exp_pid  <- length(exp_pids)
rm(survey)

say("loading %s", basename(fit_path))
fit <- readRDS(fit_path)
d   <- fit$data
say("%s: %d obs, %d participants (expected %d / %d)", name, nrow(d),
    length(unique(d$pid)), exp_obs, exp_pid)
if (nrow(d) != exp_obs || length(unique(d$pid)) != exp_pid ||
    !setequal(unique(d$pid), exp_pids)) {
  stop(sprintf("%s was not fitted on the current analytic sample; refit it before LOO.",
               basename(fit_path)))
}
rm(d)

options(mc.cores = 1L)  # memory over speed: one log-likelihood matrix at a time
t0 <- Sys.time()
l  <- loo(fit, model_names = name)
attr(l, "model_name") <- name
stopifnot(nrow(l$pointwise) == nobs(fit))
say("loo done in %.1f min", as.numeric(difftime(Sys.time(), t0, units = "mins")))
print(l)

tmp <- paste0(out_path, ".tmp")
saveRDS(l, tmp)
stopifnot(file.rename(tmp, out_path))  # atomic: never a half-written loo file
say("saved %s", out_path)
rm(fit, l)
invisible(gc())
