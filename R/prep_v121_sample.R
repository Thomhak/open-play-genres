# =============================================================================
# Earlier analytic sample (Open Play v1.2.1, Deviation D7): processed playtime
# =============================================================================
#
# Regenerates data/processed_v121/genre_wave_long.csv and
# data/processed_v121/total_playtime.csv, the processed telemetry of the
# earlier sample that the manuscript's chunk frequentist-registered reads for
# the earlier-sample rows of Appendix D (@tbl-frequentist-registered).
#
# It runs the main pipeline's functions (R/01_preprocess.R) on the v1.2.1
# release files in data/clean_v121/ (when any needed file is missing, the
# v1.2.1 release, Zenodo record 20119134, ~197MB, is downloaded and its
# data/clean/ files are copied there; the same folder is read by
# R/00_revoked_pids.R and the manuscript):
#   - sample: analytic_pids("data/clean_v121", require_qualified = FALSE),
#     i.e. everyone with at least one valid SWEMWBS in waves 1-6, as before the
#     qualification rule of D7;
#   - waves: the v1.2.1 biweekly file's own ideal_baseline_day
#     (load_survey_data(..., baseline_days = NULL));
#   - metadata and sessions: the v1.2.1 game_metadata, Xbox, Steam and
#     Nintendo files.
#
# If the archived files already exist (they are the outputs of the pipeline
# as run on v1.2.1), the regenerated tables must be identical to them after
# sorting, and the archived files are left untouched. Otherwise the
# regenerated tables are written. The archived files also hold rows for about
# 60 participants with a baseline day but no valid SWEMWBS (61 in
# genre_wave_long.csv, 62 in total_playtime.csv), whom the pipeline of the
# time did not filter out; they are outside the earlier sample and never
# enter the analysis frame (which is built on the survey rows of the sample),
# so the comparison is made on the earlier-sample participants.
#
# Usage (from the repo root): Rscript R/prep_v121_sample.R
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tidyverse)
})
here::i_am("R/prep_v121_sample.R")
source(here("R/01_preprocess.R"))  # functions only; its main block does not run

CLEAN_DIR <- "data/clean_v121"
OUT_DIR   <- "data/processed_v121"
OUT_FILES <- c(genre_wave_long = "genre_wave_long.csv",
               total_playtime  = "total_playtime.csv")

V121_URL <- paste0(
  "https://zenodo.org/api/records/20119134/files/",
  "digital-wellbeing/open-play-v1.2.1.zip/content"
)
needed <- c("survey_biweekly.csv.gz", "survey_intake.csv.gz", "game_metadata.csv.gz",
            "xbox.csv.gz", "steam.csv.gz", "nintendo.csv.gz")
missing <- needed[!file.exists(here(CLEAN_DIR, needed))]
if (length(missing) > 0) {
  message(sprintf("%s lacks %s; downloading Open Play v1.2.1 (~197MB) from Zenodo...",
                  CLEAN_DIR, paste(missing, collapse = ", ")))
  tmp <- tempfile("openplay_v121_")
  dir.create(tmp)
  zip_path <- file.path(tmp, "open-play-v1.2.1.zip")
  old_timeout <- options(timeout = 3600)
  download.file(V121_URL, zip_path, mode = "wb", quiet = TRUE)
  options(old_timeout)
  members <- unzip(zip_path, list = TRUE)$Name
  clean_members <- members[grepl("data/clean/[^/]+\\.csv\\.gz$", members)]
  stopifnot(all(missing %in% basename(clean_members)))
  unzip(zip_path, files = clean_members, exdir = tmp)
  dir.create(here(CLEAN_DIR), showWarnings = FALSE, recursive = TRUE)
  # Copy only the files that are absent; existing local copies are kept.
  for (m in clean_members[!file.exists(here(CLEAN_DIR, basename(clean_members)))]) {
    file.copy(file.path(tmp, m), here(CLEAN_DIR, basename(m)))
  }
  stopifnot(all(file.exists(here(CLEAN_DIR, needed))))
}

# --- Earlier sample, waves from the v1.2.1 file's own baseline days ----------
pids_v121   <- analytic_pids(CLEAN_DIR, require_qualified = FALSE)
survey_v121 <- load_survey_data(pids_v121, clean_dir = CLEAN_DIR, baseline_days = NULL)
message(sprintf("Earlier sample: %d participants, %d survey rows",
                length(pids_v121), nrow(survey_v121)))

# --- Telemetry: the main pipeline's steps on the v1.2.1 files -----------------
meta_long_v121 <- load_game_metadata_long(CLEAN_DIR)
genre_sessions <- add_waves(load_genre_sessions(meta_long_v121, clean_dir = CLEAN_DIR),
                            survey_v121)
raw_sessions   <- add_waves(load_raw_sessions(clean_dir = CLEAN_DIR), survey_v121)
out <- list(
  genre_wave_long = aggregate_by_genre_wave(genre_sessions),
  total_playtime  = aggregate_total_playtime(raw_sessions)
)
stopifnot(all(out$total_playtime$pid %in% pids_v121),
          all(out$genre_wave_long$pid %in% pids_v121))

# --- Compare with the archived files, or write them --------------------------
# Compare as the files would be read back: write to a temporary CSV first, so
# that column types match a read_csv() of the archived file.
read_back <- function(d) {
  f <- tempfile(fileext = ".csv")
  write_csv(d, f)
  read_csv(f, show_col_types = FALSE)
}
sort_rows <- function(d) {
  keys <- intersect(c("pid", "wave", "genre"), names(d))
  as.data.frame(arrange(d, across(all_of(keys))))
}

dir.create(here(OUT_DIR), showWarnings = FALSE, recursive = TRUE)
for (nm in names(OUT_FILES)) {
  path <- here(OUT_DIR, OUT_FILES[[nm]])
  if (file.exists(path)) {
    archived_all <- read_csv(path, show_col_types = FALSE)
    archived <- archived_all |> filter(pid %in% pids_v121)
    regenerated <- read_back(out[[nm]])
    same <- identical(names(archived), names(regenerated)) &&
      isTRUE(all.equal(sort_rows(archived), sort_rows(regenerated),
                       check.attributes = FALSE))
    if (!same) {
      stop(sprintf("%s: regenerated table differs from the archived file (%d vs %d rows); not overwritten",
                   OUT_FILES[[nm]], nrow(regenerated), nrow(archived)))
    }
    message(sprintf(paste0("%s: archived file reproduced exactly for the earlier sample ",
                           "(%d rows; %d further rows of %d participants outside it); left unchanged"),
                    OUT_FILES[[nm]], nrow(archived), nrow(archived_all) - nrow(archived),
                    n_distinct(archived_all$pid[!archived_all$pid %in% pids_v121])))
  } else {
    write_csv(out[[nm]], path)
    message(sprintf("Saved: %s/%s (%d rows)", OUT_DIR, OUT_FILES[[nm]], nrow(out[[nm]])))
  }
}
