# =============================================================================
# Fit the four main brms models (M1-M4) outside the manuscript render
# =============================================================================
#
# The fits are produced by the manuscript's own chunk code: manuscript.qmd is
# purled to a temporary R file, split into chunks at the "## ----" markers that
# knitr::purl(documentation = 1) emits (each chunk keeps its "#| label:" line),
# and the selected chunks are evaluated in order in this fresh R session. The
# brms `file =` names are therefore exactly the manuscript's
# (models/h1_rewb_model, h2_genre_model, h2_hier_model_v4, h2_mm_model_full),
# and the render later reloads these fits instead of refitting. M3 is the
# non-centred multi-membership form since 2026-10-14 (h2_hier_model_v4; the
# centred h2_hier_model_v3 had 68 divergent transitions); its chunk
# h2-hier-fit also builds the gW_/gB_ genre-label columns and summed
# exposures it needs, so DEP_LABELS is unchanged.
#
# Usage (from the repo root; normally called by scripts/refit_v130.sh):
#   Rscript R/fit_main_models.R [last-label]      # default: h2-mm-fit
#
# Environment switches:
#   REFIT_CHUNKS=range    (default) evaluate every chunk from `setup` through
#                         [last-label], skipping only chunks whose label starts
#                         with "fig-" or "tbl-" (plots/tables are not needed to
#                         fit). Errors in the dependency chunks (DEP_LABELS)
#                         and in the fit chunks are fatal; errors in any other
#                         chunk (prose guards, data-quality checks, the
#                         diagnostics stop()s) are logged and skipped, because
#                         no fit chunk depends on them (checked below, and by
#                         the dry run). They are early warnings for the render.
#   REFIT_CHUNKS=minimal  evaluate only DEP_LABELS plus [last-label]. Used for
#                         M4 so that M1-M3 are not reloaded into memory while
#                         M4 samples for ~2.5 h.
#   REFIT_DRYRUN=1        stop right before the first chunk that calls brm()
#                         and print the dimensions (and hashes) of the model
#                         frames. No model is fitted or loaded.
#   REFIT_FAILURES_FILE   path to append the non-fatal chunk failures to.
#   REFIT_SKIP_LABELS     comma-separated extra labels to skip (never a
#                         dependency or fit chunk); for testing only.
#
# After every fit chunk the fitted data are checked against the current
# analytic sample (n observations, n participants, the same participant set),
# so a stale fit from an earlier data release reloaded through `file =` fails
# loudly.
# =============================================================================

suppressPackageStartupMessages(library(here))
here::i_am("R/fit_main_models.R")
setwd(here())  # knitr evaluates manuscript chunks with the repo root as wd

args   <- commandArgs(trailingOnly = TRUE)
target <- if (length(args) >= 1) args[1] else "h2-mm-fit"
mode   <- Sys.getenv("REFIT_CHUNKS", "range")
dryrun <- identical(Sys.getenv("REFIT_DRYRUN"), "1")
failures_file <- Sys.getenv("REFIT_FAILURES_FILE", "")
extra_skip <- trimws(strsplit(Sys.getenv("REFIT_SKIP_LABELS", ""), ",")[[1]])
stopifnot(mode %in% c("range", "minimal"))

# Chunks every fit needs, in document order (verified against the chunk list
# below): packages/helpers, processed playtime, the analytic survey, the
# within/between model frame, and the M4 multi-membership frame and formula.
DEP_LABELS <- c("setup", "load-data", "load-mobile", "model-data",
                "mm-data-setup", "mm-formula-setup")
FIT_OBJECTS <- c("h1-fit" = "h1_model", "h2-fit" = "h2_model",
                 "h2-hier-fit" = "h2_hier_model", "h2-mm-fit" = "h2_mm_model")
stopifnot(target %in% names(FIT_OBJECTS))

ts  <- function() format(Sys.time(), "%Y-%m-%d %H:%M:%S")
say <- function(...) message(sprintf("[%s] %s", ts(), sprintf(...)))

say("fit_main_models.R: target=%s mode=%s dryrun=%s", target, mode, dryrun)
say("manuscript.qmd md5 %s", unname(tools::md5sum(here("manuscript.qmd"))))

# --- Purl and split into chunks ----------------------------------------------
# documentation = 1 is needed: with documentation = 0 purl writes no chunk
# markers at all. With 1 it writes a "## ----" line before each chunk and keeps
# the "#| " option lines; the narrative text is not included.
purl_file <- tempfile("manuscript_purled_", fileext = ".R")
invisible(knitr::purl(here("manuscript.qmd"), output = purl_file,
                      documentation = 1, quiet = TRUE))
lines   <- readLines(purl_file, warn = FALSE)
starts  <- grep("^## ----", lines)
stopifnot(length(starts) > 0)
ends    <- c(starts[-1] - 1L, length(lines))
chunks  <- Map(function(s, e) lines[(s + 1L):e], starts, ends)
get_opt <- function(code, opt) {
  hit <- grep(sprintf("^#\\|\\s*%s:", opt), code, value = TRUE)
  if (length(hit) == 0) return(NA_character_)
  trimws(sub("#.*$", "", sub(sprintf("^#\\|\\s*%s:\\s*", opt), "", hit[1])))
}
labels <- vapply(chunks, get_opt, character(1), opt = "label")
labels[is.na(labels)] <- sprintf("unlabelled-%d", which(is.na(labels)))
names(chunks) <- labels

# The purled chunk list must match the R fences in the .qmd one to one.
qmd <- readLines(here("manuscript.qmd"), warn = FALSE)
n_fences <- sum(grepl("^```\\{r", qmd))
stopifnot(length(chunks) == n_fences, !anyDuplicated(labels))
say("purled %d chunks to %s", length(chunks), purl_file)

i_setup  <- match("setup", labels)
i_target <- match(target, labels)
stopifnot(!is.na(i_setup), !is.na(i_target), i_setup < i_target,
          all(DEP_LABELS %in% labels))
range_idx <- seq(i_setup, i_target)
stopifnot(all(match(DEP_LABELS, labels) < match("h1-fit", labels)))

uses_brm <- function(code) any(grepl("\\bbrm\\(", code))
is_fit   <- function(lab) lab %in% names(FIT_OBJECTS)
eval_off <- function(code) identical(tolower(get_opt(code, "eval")), "false")

if (mode == "range") {
  run_idx <- range_idx[!grepl("^(fig|tbl)-", labels[range_idx]) &
                       !vapply(chunks[range_idx], eval_off, logical(1)) &
                       !labels[range_idx] %in% extra_skip]
} else {
  run_idx <- sort(match(c(DEP_LABELS, target), labels))
}
stopifnot(!any(extra_skip %in% c(DEP_LABELS, names(FIT_OBJECTS))))
required <- c(DEP_LABELS, labels[run_idx][is_fit(labels[run_idx])])
stopifnot(all(DEP_LABELS %in% labels[run_idx]), target %in% labels[run_idx])

# Every chunk in the range that calls brm() must be a known fit chunk (no
# unexpected model is fitted), and every known fit chunk must call brm().
brm_in_range <- labels[range_idx][vapply(chunks[range_idx], uses_brm, logical(1))]
stopifnot(all(brm_in_range %in% names(FIT_OBJECTS)),
          all(vapply(chunks[intersect(names(FIT_OBJECTS), labels[range_idx])],
                     uses_brm, logical(1))))

# --- Static dependency check -------------------------------------------------
# Symbols assigned at top level by each chunk; a required chunk must not use a
# symbol that only a skipped chunk in the range defines. This is a coarse,
# name-based check (column names used inside dplyr verbs can collide with
# variables), so hits are reported, not fatal; the dry run, which evaluates the
# selected chunks for real, is the decisive check.
assigned_in <- function(code) {
  ex <- tryCatch(parse(text = code, keep.source = FALSE),
                 error = function(e) expression())
  out <- character(0)
  for (e in ex) {
    if (is.call(e) && is.name(e[[1]]) &&
        as.character(e[[1]]) %in% c("<-", "=", "<<-") &&
        is.name(e[[2]])) out <- c(out, as.character(e[[2]]))
  }
  unique(out)
}
used_in <- function(code) {
  ex <- tryCatch(parse(text = code, keep.source = FALSE),
                 error = function(e) expression())
  unique(all.names(ex))
}
skipped_idx <- setdiff(range_idx, run_idx)
say("evaluating %d of %d chunks in setup..%s (%s mode); skipped: %s",
    length(run_idx), length(range_idx), target, mode,
    if (length(skipped_idx)) paste(labels[skipped_idx], collapse = ", ") else "none")
dep_hits <- character(0)
for (r in run_idx[labels[run_idx] %in% required]) {
  provided <- unique(unlist(lapply(chunks[run_idx[run_idx <= r]], assigned_in)))
  for (s in skipped_idx[skipped_idx < r]) {
    hit <- setdiff(intersect(assigned_in(chunks[[s]]), used_in(chunks[[r]])), provided)
    if (length(hit)) dep_hits <- c(dep_hits, sprintf("%s uses %s (assigned only in skipped %s)",
                                                     labels[r], paste(hit, collapse = ","), labels[s]))
  }
}
if (length(dep_hits)) {
  say("static check, possible dependencies on skipped chunks (name-based; verify):")
  for (h in dep_hits) message("    ", h)
} else {
  say("static check: no required chunk uses a symbol defined only in a skipped chunk")
}

# --- Evaluate ----------------------------------------------------------------
options(device = function(...) grDevices::pdf(file = NULL))  # no Rplots.pdf
nonfatal <- character(0)

hash_obj <- function(x) if (requireNamespace("rlang", quietly = TRUE)) rlang::hash(x) else NA

report_frames <- function() {
  ad  <- get("analysis_data", envir = globalenv())
  fit <- ad[!is.na(ad$wemwbs), ]
  say("DRYRUN analysis_data: %d rows x %d cols; %d participants", nrow(ad), ncol(ad),
      length(unique(ad$pid)))
  say("DRYRUN fit frame (wemwbs observed): %d rows; %d participants; n_analysis_obs=%d, n_analysis_pids=%d",
      nrow(fit), length(unique(fit$pid)),
      get("n_analysis_obs", envir = globalenv()), get("n_analysis_pids", envir = globalenv()))
  if (exists("mm_data", envir = globalenv())) {
    mm <- get("mm_data", envir = globalenv())
    say("DRYRUN mm_data: %d rows x %d cols; fit rows %d; K=%d genres; uniform-weight waves %d",
        nrow(mm), ncol(mm), sum(!is.na(mm$wemwbs)), get("K", envir = globalenv()),
        get("n_mm_uniform", envir = globalenv()))
  }
  for (nm in c("analysis_data", "mm_data", "gh_within", "gh_between",
               "h2_mm_formula")) {
    if (exists(nm, envir = globalenv()))
      say("DRYRUN hash %-16s %s", nm, hash_obj(get(nm, envir = globalenv())))
  }
}

check_fit <- function(label) {
  obj <- FIT_OBJECTS[[label]]
  fit <- get(obj, envir = globalenv())
  d   <- fit$data
  n_obs  <- get("n_analysis_obs",  envir = globalenv())
  n_pids <- get("n_analysis_pids", envir = globalenv())
  ad     <- get("analysis_data",   envir = globalenv())
  pids   <- unique(ad$pid[!is.na(ad$wemwbs)])
  divs   <- sum(subset(brms::nuts_params(fit), Parameter == "divergent__")$Value)
  et     <- tryCatch(rowSums(rstan::get_elapsed_time(fit$fit)), error = function(e) NA)
  say("%s: %d obs, %d participants, %d divergent transitions, chain seconds %s",
      obj, nrow(d), length(unique(d$pid)), divs, paste(round(et), collapse = "/"))
  if (!(nrow(d) == n_obs && length(unique(d$pid)) == n_pids &&
        setequal(unique(d$pid), pids))) {
    stop(sprintf(paste0(
      "%s does not match the current analytic sample (fit: %d obs / %d pids; ",
      "expected %d / %d). A stale fit was probably reloaded through brms `file =`: ",
      "archive it and re-run."), obj, nrow(d), length(unique(d$pid)), n_obs, n_pids))
  }
}

for (i in run_idx) {
  lab  <- labels[i]
  code <- chunks[[i]]
  if (dryrun && uses_brm(code)) {
    say("DRYRUN: stopping before chunk '%s' (first brm() call)", lab)
    report_frames()
    quit(save = "no", status = 0)
  }
  fatal <- lab %in% required
  say("chunk %-34s start%s", lab, if (fatal) " (required)" else "")
  t0 <- Sys.time()
  ok <- tryCatch({
    withCallingHandlers(
      eval(parse(text = code, keep.source = FALSE), envir = globalenv()),
      warning = function(w) {
        message(sprintf("    warning in %s: %s", lab, conditionMessage(w)))
        invokeRestart("muffleWarning")
      }
    )
    TRUE
  }, error = function(e) {
    msg <- sprintf("%s: %s", lab, conditionMessage(e))
    if (fatal) {
      say("FATAL error in required chunk %s", msg)
      quit(save = "no", status = 1)
    }
    say("non-fatal error (chunk skipped) in %s", msg)
    nonfatal <<- c(nonfatal, msg)
    FALSE
  })
  say("chunk %-34s %s (%.1f min)", lab, if (ok) "done" else "FAILED",
      as.numeric(difftime(Sys.time(), t0, units = "mins")))
  if (ok && is_fit(lab)) {
    tryCatch(check_fit(lab), error = function(e) {
      say("FATAL: %s", conditionMessage(e))
      quit(save = "no", status = 1)
    })
  }
}

if (length(nonfatal)) {
  say("%d non-fatal chunk failure(s); the render will hit these too unless they depend on fits or files that later stages produce:",
      length(nonfatal))
  for (m in nonfatal) message("    ", m)
  if (nzchar(failures_file)) {
    write(c(sprintf("# fit_main_models.R %s target=%s mode=%s %s", ts(), target, mode,
                    "(non-fatal chunk failures)"), nonfatal),
          failures_file, append = TRUE)
  }
} else {
  say("no non-fatal chunk failures")
}
say("fit_main_models.R finished: %s", paste(FIT_OBJECTS[labels[run_idx][is_fit(labels[run_idx])]],
                                            collapse = ", "))
