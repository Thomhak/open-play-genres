# =============================================================================
# Baseline-day sidecar: data/reference/baseline_days.csv
# =============================================================================
#
# R/01_preprocess.R assigns telemetry sessions to the six 14-day study waves
# from each participant's `ideal_baseline_day` (the scheduled wave-1 day).
# Open Play releases >= v1.2.5 no longer ship that column in
# survey_biweekly.csv.gz, but it is a deterministic function of the raw
# biweekly survey timestamps, computed in the release's data-process.qmd
# (chunk `preprocess-biweekly-survey`):
#
#   1. a response's day runs from 4 am to 4 am (a response before 4 am counts
#      for the previous day);
#   2. the candidate baselines are the participant's observed days; each is
#      scored by the number of distinct waves it yields on a 14-day grid
#      (waves 1-30), a response counting when it lies within 7 days of a grid
#      point, one response per wave;
#   3. the candidate with the most valid waves is the baseline, ties going to
#      the earliest day.
#
# This script applies that rule to the raw biweekly file shipped in the same
# release (data/raw/survey_biweekly_raw.csv.gz, extracted by `make data`) and
# stops unless the derived waves reproduce the release's clean
# survey_biweekly.csv.gz row for row, so the sidecar is exactly the baseline the
# release itself used. Timestamps are read as UTC, as in data-process.qmd.
#
# Input:  data/raw/survey_biweekly_raw.csv.gz, data/clean/survey_biweekly.csv.gz
# Output: data/reference/baseline_days.csv (pid, ideal_baseline_day)
#
# Run once per data release: Rscript R/00_baseline_days.R
# =============================================================================

library(here)
library(tidyverse)

here::i_am("R/00_baseline_days.R")

RAW_PATH   <- here("data/raw/survey_biweekly_raw.csv.gz")
CLEAN_PATH <- here("data/clean/survey_biweekly.csv.gz")
OUT_PATH   <- here("data/reference/baseline_days.csv")

for (p in c(RAW_PATH, CLEAN_PATH)) {
  if (!file.exists(p)) stop("Missing ", p, "; run `make data` first.")
}

raw <- read_csv(RAW_PATH, show_col_types = FALSE, guess_max = Inf, progress = FALSE)
stopifnot(all(c("pid", "wave", "date", "bangs_failed_att_check") %in% names(raw)),
          inherits(raw$date, "POSIXct"))

# --- data-process.qmd, chunk preprocess-biweekly-survey ----------------------
base <- raw |>
  filter(!bangs_failed_att_check) |>
  mutate(baseline_day = as.Date(date) - if_else(hour(date) < 4, 1L, 0L))

best <- base |>
  distinct(pid, ideal_baseline_day = baseline_day) |>
  inner_join(base |> select(pid, baseline_day, date), by = "pid",
             relationship = "many-to-many") |>
  mutate(
    delta_days = as.integer(baseline_day - ideal_baseline_day),
    dpw = 1L + as.integer(round(delta_days / 14))
  ) |>
  filter(between(dpw, 1L, 30L), abs(delta_days - 14L * (dpw - 1L)) <= 7L) |>
  group_by(pid, ideal_baseline_day, dpw) |>
  slice_min(date, n = 1, with_ties = FALSE) |>
  ungroup() |>
  count(pid, ideal_baseline_day, name = "n_valid") |>
  group_by(pid) |>
  arrange(desc(n_valid), ideal_baseline_day) |>
  slice(1) |>
  ungroup()

derived <- base |>
  left_join(best, by = "pid") |>
  mutate(
    delta_days_final = as.integer(baseline_day - ideal_baseline_day),
    wave = 1L + as.integer(round(delta_days_final / 14))
  ) |>
  filter(between(wave, 1L, 30L), abs(delta_days_final - 14L * (wave - 1L)) <= 7L) |>
  group_by(pid, wave) |>
  slice_min(date, n = 1, with_ties = FALSE) |>
  ungroup() |>
  select(pid, wave, date) |>
  arrange(pid, wave)

# --- check: the rule reproduces the release's clean file ----------------------
clean <- read_csv(CLEAN_PATH, show_col_types = FALSE, guess_max = Inf, progress = FALSE) |>
  select(pid, wave, date) |>
  arrange(pid, wave)
stopifnot(
  nrow(derived) == nrow(clean),
  identical(derived$pid, clean$pid),
  identical(derived$wave, as.integer(clean$wave)),
  all(abs(as.numeric(derived$date) - as.numeric(clean$date)) < 1)
)
stopifnot(all(clean$pid %in% best$pid))

out <- best |>
  select(pid, ideal_baseline_day) |>
  arrange(pid)
stopifnot(nrow(out) == n_distinct(out$pid), !anyNA(out$ideal_baseline_day))

dir.create(dirname(OUT_PATH), showWarnings = FALSE, recursive = TRUE)
write_csv(out, OUT_PATH)
message(sprintf(
  "Wrote %s: %d participants; derived waves reproduce %d clean rows for %d participants.",
  OUT_PATH, nrow(out), nrow(clean), n_distinct(clean$pid)
))
