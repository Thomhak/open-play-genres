# prep_daily_positive_control.R
#
# Shooter-gender positive control (pre-registered DQC3) evaluated in the
# daily-diary subsample, using the EXISTING biweekly pipeline outputs.
# No daily aggregation is built here.
#
# Diary pids      : unique pid in data/clean/survey_daily.csv.gz, restricted to
#                   analytic_pids() (R/01_preprocess.R: intake qualified ==
#                   TRUE AND >= 1 valid SWEMWBS in biweekly waves 1-6)
# Gender          : data/clean/survey_intake.csv.gz
# Shooter exposure: data/processed/genre_wave_long.csv, genre == "Shooter",
#                   hours_per_day summed within (pid, wave) over waves 1-6,
#                   then averaged per pid over that pid's observed waves.
# Base population : diary pids appearing in data/processed/total_playtime.csv
#
# Run from repo root: Rscript scripts/prep_daily_positive_control.R

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(here)
})

# Shared sample definition (analytic_pids()); sourcing does not run the
# biweekly pipeline (guarded by sys.nframe()).
source(here("R/01_preprocess.R"))

WAVES <- 1:6

rule <- function(txt) cat("\n", strrep("=", 70), "\n", txt, "\n", strrep("=", 70), "\n", sep = "")

# ---------------------------------------------------------------- load ----

daily <- read_csv(here("data/clean/survey_daily.csv.gz"),
                  col_types = cols(.default = col_guess()), progress = FALSE)
intake <- read_csv(here("data/clean/survey_intake.csv.gz"),
                   col_types = cols(.default = col_guess()), progress = FALSE)
genre_long <- read_csv(here("data/processed/genre_wave_long.csv"),
                       col_types = cols(.default = col_guess()), progress = FALSE)
total_pt <- read_csv(here("data/processed/total_playtime.csv"),
                     col_types = cols(.default = col_guess()), progress = FALSE)

diary_pids <- intersect(unique(as.character(daily$pid)), analytic_pids())

rule("SAMPLE FRAME")
cat(sprintf("Diary pids (survey_daily, analytic sample)       : %d\n", length(diary_pids)))
cat(sprintf("Rows in survey_daily (all participants)          : %d\n", nrow(daily)))
cat(sprintf("Distinct pids in total_playtime.csv              : %d\n",
            n_distinct(total_pt$pid)))

# --------------------------------------------------------- base pop ------

pt_frame <- total_pt |>
  mutate(pid = as.character(pid)) |>
  filter(wave %in% WAVES, pid %in% diary_pids) |>
  distinct(pid, wave)

base_pids <- sort(unique(pt_frame$pid))
cat(sprintf("Base population (diary pids in total_playtime,\n  waves %d-%d)                                      : %d\n",
            min(WAVES), max(WAVES), length(base_pids)))
cat(sprintf("Diary pids NOT in total_playtime                 : %d\n",
            length(setdiff(diary_pids, base_pids))))

# ------------------------------------------------------------ genre ------

genre_labels <- sort(unique(genre_long$genre))
cat("\nGenre labels present in genre_wave_long.csv:\n")
cat(paste0("  ", genre_labels, collapse = "\n"), "\n")
stopifnot("Shooter" %in% genre_labels)

shooter_by_wave <- genre_long |>
  mutate(pid = as.character(pid)) |>
  filter(genre == "Shooter", wave %in% WAVES) |>
  group_by(pid, wave) |>
  summarise(shooter_hpd = sum(hours_per_day, na.rm = TRUE), .groups = "drop")

# Mean over each pid's OBSERVED waves in total_playtime; absent Shooter = 0.
shooter_by_pid <- pt_frame |>
  left_join(shooter_by_wave, by = c("pid", "wave")) |>
  mutate(shooter_hpd = coalesce(shooter_hpd, 0)) |>
  group_by(pid) |>
  summarise(shooter_time = mean(shooter_hpd),
            n_waves = n(),
            .groups = "drop")

# Alternative denominator: fixed /6 regardless of observed waves.
shooter_by_pid_fixed6 <- pt_frame |>
  left_join(shooter_by_wave, by = c("pid", "wave")) |>
  mutate(shooter_hpd = coalesce(shooter_hpd, 0)) |>
  group_by(pid) |>
  summarise(shooter_time_f6 = sum(shooter_hpd) / length(WAVES), .groups = "drop")

cat(sprintf("\nPids in base pop with >=1 Shooter row (waves %d-%d): %d (%.1f%%)\n",
            min(WAVES), max(WAVES),
            sum(shooter_by_pid$shooter_time > 0),
            100 * mean(shooter_by_pid$shooter_time > 0)))
cat(sprintf("Median observed waves per pid                     : %.1f (range %d-%d)\n",
            median(shooter_by_pid$n_waves),
            min(shooter_by_pid$n_waves), max(shooter_by_pid$n_waves)))

# ----------------------------------------------------------- gender ------

rule("GENDER VARIABLE")
cat("Column name in survey_intake: 'gender'\n")

intake_slim <- intake |>
  mutate(pid = as.character(pid)) |>
  select(pid, gender, country, qualified)

gender_raw_diary <- intake_slim |>
  filter(pid %in% diary_pids) |>
  count(gender, name = "n") |>
  arrange(desc(n))

cat("\nRaw gender levels among diary pids (intake, unfiltered):\n")
print(as.data.frame(gender_raw_diary))

cat("\nCountry among diary pids (intake):\n")
print(as.data.frame(intake_slim |> filter(pid %in% diary_pids) |>
                      count(country, name = "n") |> arrange(desc(n))))

# Recode to match manuscript.qmd (lines ~292-297).
intake_recode <- intake_slim |>
  mutate(gender_r = case_when(
    gender %in% c("Man", "Male")     ~ "Man",
    gender %in% c("Woman", "Female") ~ "Woman",
    gender == "Prefer not to say"    ~ NA_character_,
    is.na(gender)                    ~ NA_character_,
    TRUE                             ~ "Non-binary/Other"
  ))

cat("\nRecoded gender levels among BASE POPULATION pids:\n")
print(as.data.frame(intake_recode |> filter(pid %in% base_pids) |>
                      count(gender_r, name = "n") |> arrange(desc(n))))

# ------------------------------------------------------------- test ------

dat <- shooter_by_pid |>
  left_join(shooter_by_pid_fixed6, by = "pid") |>
  left_join(intake_recode |> select(pid, gender_r, country), by = "pid") |>
  filter(gender_r %in% c("Man", "Woman"))

cat(sprintf("\nAnalysed n (base pop with gender Man/Woman)      : %d\n", nrow(dat)))

cohens_d <- function(x, g) {
  m <- x[g == "Man"]; w <- x[g == "Woman"]
  nm <- length(m); nw <- length(w)
  pooled_var <- ((nm - 1) * var(m) + (nw - 1) * var(w)) / (nm + nw - 2)
  list(n_men = nm, n_women = nw,
       mean_men = mean(m), mean_women = mean(w),
       sd_men = sd(m), sd_women = sd(w),
       pooled_sd = sqrt(pooled_var),
       d = (mean(m) - mean(w)) / sqrt(pooled_var))
}

report <- function(label, x, g) {
  r <- cohens_d(x, g)
  tt <- t.test(x ~ g)  # Welch; g factor levels Man, Woman -> Man - Woman
  cat(sprintf("\n--- %s ---\n", label))
  cat(sprintf("  n men   = %d   mean = %.4f   SD = %.4f\n", r$n_men, r$mean_men, r$sd_men))
  cat(sprintf("  n women = %d   mean = %.4f   SD = %.4f\n", r$n_women, r$mean_women, r$sd_women))
  cat(sprintf("  pooled SD = %.4f\n", r$pooled_sd))
  cat(sprintf("  Cohen's d (men - women) = %.4f\n", r$d))
  cat(sprintf("  Welch t(%.1f) = %.3f, p = %.3g\n", tt$parameter, tt$statistic, tt$p.value))
  invisible(r)
}

rule("POSITIVE CONTROL: SHOOTER x GENDER (diary subsample)")

dat <- dat |> mutate(gender_r = factor(gender_r, levels = c("Man", "Woman")))

report("RAW mean daily Shooter hours (observed-wave denominator)",
       dat$shooter_time, dat$gender_r)

report("LOG(x + 0.01) of mean daily Shooter hours",
       log(dat$shooter_time + 0.01), dat$gender_r)

report("RAW, fixed /6 denominator (robustness on wave denominator)",
       dat$shooter_time_f6, dat$gender_r)

cat("\nDistributional note (raw scale):\n")
cat(sprintf("  overall median = %.4f, mean = %.4f, max = %.4f, %% exact zero = %.1f%%\n",
            median(dat$shooter_time), mean(dat$shooter_time),
            max(dat$shooter_time), 100 * mean(dat$shooter_time == 0)))

cat("\nDone.\n")
