# =============================================================================
# Baseline-day sidecar: data/reference/baseline_days.csv
# =============================================================================
#
# R/01_preprocess.R assigns telemetry sessions to the six 14-day study waves
# from each participant's `ideal_baseline_day` (the scheduled wave-1 day).
# Open Play releases >= v1.2.5 dropped that column (together with
# baseline_day, original_wave, derived_wave, n_valid and delta_days_final)
# from survey_biweekly.csv.gz. It cannot be reconstructed from the remaining
# columns: the offset from the intake date varies between 0 and 195 days, and
# the wave-1 survey date is 0 or 1 day off for 195 participants.
#
# This script therefore writes the per-participant value once, from the
# v1.2.1 biweekly file (Zenodo record 20119134), as a one-row-per-pid table
# (pid, ideal_baseline_day). The values are identical to those in v1.2.1, so
# wave assignment, and therefore data/processed/genre_wave_long.csv and
# total_playtime.csv, are unchanged for every retained participant.
#
# Input:  data/clean_v121/survey_biweekly.csv.gz (local copy of v1.2.1); if
#         absent, the v1.2.1 release is downloaded from Zenodo to a temp dir.
# Output: data/reference/baseline_days.csv
#
# Run once: Rscript R/00_baseline_days.R
# =============================================================================

library(here)
library(tidyverse)

here::i_am("R/00_baseline_days.R")

V121_BIWEEKLY <- here("data/clean_v121/survey_biweekly.csv.gz")
V121_URL <- paste0(
  "https://zenodo.org/api/records/20119134/files/",
  "digital-wellbeing/open-play-v1.2.1.zip/content"
)
OUT_PATH <- here("data/reference/baseline_days.csv")
EXPECTED_N_PIDS <- 1948L

#' Locate the v1.2.1 biweekly file, downloading the release if necessary.
#' @return Path to survey_biweekly.csv.gz from Open Play v1.2.1
v121_biweekly_path <- function() {
  if (file.exists(V121_BIWEEKLY)) {
    return(V121_BIWEEKLY)
  }
  message("data/clean_v121/ not found; downloading Open Play v1.2.1 (~197MB) from Zenodo...")
  tmp <- tempfile("openplay_v121_")
  dir.create(tmp)
  zip_path <- file.path(tmp, "open-play-v1.2.1.zip")
  old_timeout <- options(timeout = 3600)
  on.exit(options(old_timeout), add = TRUE)
  download.file(V121_URL, zip_path, mode = "wb", quiet = TRUE)
  members <- unzip(zip_path, list = TRUE)$Name
  member <- members[str_detect(members, "data/clean/survey_biweekly\\.csv\\.gz$")]
  stopifnot(length(member) == 1)
  unzip(zip_path, files = member, exdir = tmp)
  file.path(tmp, member)
}

src <- v121_biweekly_path()
message(sprintf("Reading %s", src))

biweekly <- read_csv(
  src,
  show_col_types = FALSE,
  col_select = c(pid, ideal_baseline_day),
  col_types = cols(pid = col_character(), ideal_baseline_day = col_date())
)

baseline_days <- biweekly |>
  distinct(pid, ideal_baseline_day) |>
  arrange(pid)

# One baseline per participant, none missing.
stopifnot(
  nrow(baseline_days) == n_distinct(baseline_days$pid),
  !anyNA(baseline_days$ideal_baseline_day),
  nrow(baseline_days) == EXPECTED_N_PIDS
)

dir.create(dirname(OUT_PATH), showWarnings = FALSE, recursive = TRUE)
write_csv(baseline_days, OUT_PATH)
message(sprintf(
  "Saved: data/reference/baseline_days.csv (%d participants, %s to %s)",
  nrow(baseline_days),
  format(min(baseline_days$ideal_baseline_day)),
  format(max(baseline_days$ideal_baseline_day))
))
