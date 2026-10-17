# =============================================================================
# Sample-change reference files for the v1.2.1 -> v1.2.6 migration
# =============================================================================
#
# Open Play v1.2.4 corrected the intake `qualified` flag: participants who had
# entered the surveys without passing the account-linking and telemetry
# validation lost it. From v1.2.6 on, this study's analytic sample is the set
# of participants with qualified == TRUE in data/clean/survey_intake.csv.gz
# and at least one valid SWEMWBS in biweekly waves 1-6 (analytic_pids() in
# R/01_preprocess.R).
#
# This script documents which participants of the earlier (v1.2.1) analytic
# sample that rule removes, so the manuscript can report the counts inline
# (Data Source and Participants; Appendix A, Deviation D7):
#
#   data/reference/revoked_qualified_pids.csv
#       pid, in_v121_analytic_sample, linked_any, any_telemetry
#       every pid whose intake was qualified in v1.2.1 and is not in v1.2.6;
#       linked_any = had linked at least one platform at intake (v1.2.1);
#       any_telemetry = appears in any console/PC telemetry file
#   data/reference/no_intake_record_pids.csv
#       pid, any_telemetry
#       v1.2.1 analytic-sample pids without an intake record in either release
#
# Input:  data/clean_v121/{survey_intake,survey_biweekly}.csv.gz (v1.2.1)
#         data/clean/survey_intake.csv.gz (v1.2.6)
# Run once: Rscript R/00_revoked_pids.R
# =============================================================================

library(here)
library(tidyverse)

here::i_am("R/00_revoked_pids.R")

V121_DIR <- here("data/clean_v121")
OUT_DIR <- here("data/reference")
EXPECTED_REVOKED_IN_SAMPLE <- 133L
EXPECTED_V121_SAMPLE <- 1838L

for (f in c("survey_intake.csv.gz", "survey_biweekly.csv.gz")) {
  if (!file.exists(file.path(V121_DIR, f))) {
    stop("Missing data/clean_v121/", f, ": keep a copy of the Open Play v1.2.1 ",
         "clean files there (Zenodo record 20119134) to run this script.")
  }
}

read_intake <- function(path) {
  read_csv(path, show_col_types = FALSE, col_select = c(pid, qualified)) |>
    mutate(pid = as.character(pid))
}

intake_v121 <- read_intake(file.path(V121_DIR, "survey_intake.csv.gz"))
intake_v126 <- read_intake(here("data/clean/survey_intake.csv.gz"))

qualified_v121 <- intake_v121 |> filter(qualified %in% TRUE) |> distinct(pid) |> pull(pid)
qualified_v126 <- intake_v126 |> filter(qualified %in% TRUE) |> distinct(pid) |> pull(pid)

# v1.2.1 analytic sample: >= 1 valid SWEMWBS in waves 1-6 (no intake condition)
sample_v121 <- read_csv(file.path(V121_DIR, "survey_biweekly.csv.gz"),
                        show_col_types = FALSE) |>
  filter(wave >= 1, wave <= 6) |>
  mutate(
    pid = as.character(pid),
    wemwbs = rowMeans(across(starts_with("wemwbs_")), na.rm = FALSE)
  ) |>
  filter(!is.na(wemwbs)) |>
  distinct(pid) |>
  pull(pid)
stopifnot(length(sample_v121) == EXPECTED_V121_SAMPLE)

# Per-pid context for the D7 disclosure: did the participant ever link an
# account (v1.2.1 intake linked_platforms), and does any console/PC telemetry
# file hold sessions for them (the telemetry files are byte-identical across
# releases, so data/clean/ is used)?
linked_v121 <- read_csv(file.path(V121_DIR, "survey_intake.csv.gz"),
                        show_col_types = FALSE,
                        col_select = c(pid, linked_platforms)) |>
  mutate(pid = as.character(pid), linked_any = !is.na(linked_platforms)) |>
  select(pid, linked_any)
telemetry_pids <- unique(c(
  read_csv(here("data/clean/xbox.csv.gz"), show_col_types = FALSE, col_select = c(pid))$pid,
  read_csv(here("data/clean/steam.csv.gz"), show_col_types = FALSE, col_select = c(pid))$pid,
  read_csv(here("data/clean/nintendo.csv.gz"), show_col_types = FALSE, col_select = c(pid))$pid
)) |> as.character()

revoked <- tibble(pid = sort(setdiff(qualified_v121, qualified_v126))) |>
  mutate(in_v121_analytic_sample = pid %in% sample_v121) |>
  left_join(linked_v121, by = "pid") |>
  mutate(any_telemetry = pid %in% telemetry_pids)
n_revoked_in_sample <- sum(revoked$in_v121_analytic_sample)
stopifnot(n_revoked_in_sample == EXPECTED_REVOKED_IN_SAMPLE)
# The correction only revoked the flag; no pid gained it.
stopifnot(length(setdiff(qualified_v126, qualified_v121)) == 0)

no_intake <- tibble(
  pid = sort(setdiff(sample_v121, union(intake_v121$pid, intake_v126$pid)))
) |>
  mutate(any_telemetry = pid %in% telemetry_pids)

dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)
write_csv(revoked, file.path(OUT_DIR, "revoked_qualified_pids.csv"))
write_csv(no_intake, file.path(OUT_DIR, "no_intake_record_pids.csv"))

message(sprintf(
  "Revoked qualified flag: %d pids (%d in the v1.2.1 analytic sample of %d).",
  nrow(revoked), n_revoked_in_sample, length(sample_v121)
))
message(sprintf(
  "v1.2.1 analytic-sample pids without an intake record in either release: %d.",
  nrow(no_intake)
))
message(sprintf(
  "Of the %d revoked in-sample pids: %d never linked an account, %d have no telemetry.",
  n_revoked_in_sample,
  sum(revoked$in_v121_analytic_sample & !revoked$linked_any),
  sum(revoked$in_v121_analytic_sample & !revoked$any_telemetry)
))
message(sprintf(
  "No-intake pids with any telemetry: %d of %d.", sum(no_intake$any_telemetry), nrow(no_intake)
))
message(sprintf(
  "v1.2.1 sample minus both groups: %d.",
  length(sample_v121) - n_revoked_in_sample - nrow(no_intake)
))
