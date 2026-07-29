# =============================================================================
# Fit the demographic sensitivity models (H1 and H2 adjusted for age, gender,
# ethnicity) outside the manuscript render.
#
# The data construction below replicates the manuscript.qmd chunks
# `build-demographics` and `model-data` exactly, so that the brms `file =`
# caches written here (models/h1_demographics, models/h2_demographics) are
# valid when manuscript.qmd renders with the same data and priors.
#
# Runtime: ~30-90 minutes per model on 4 parallel chains.
# Usage:   Rscript R/fit_sensitivity_models.R
# =============================================================================

library(here)
here::i_am("R/fit_sensitivity_models.R")

suppressPackageStartupMessages({
  library(tidyverse)
  library(brms)
})

source(here("R/01_preprocess.R"))

options(mc.cores = max(1L, parallel::detectCores() - 1L))
dir.create(here("models"), showWarnings = FALSE, recursive = TRUE)

# --- Replicates manuscript.qmd chunk `build-demographics` -------------------

intake <- read_csv(here("data/clean/survey_intake.csv.gz"), show_col_types = FALSE)

# The analytic sample is defined by the models: all participants with at
# least one valid SWEMWBS response in the biweekly survey.
analysis_pids <- read_csv(here("data/clean/survey_biweekly.csv.gz"), show_col_types = FALSE) |>
  mutate(wemwbs = rowMeans(across(starts_with("wemwbs_")), na.rm = FALSE)) |>
  filter(!is.na(wemwbs)) |>
  distinct(pid) |>
  pull(pid)

demographics <- intake |>
  filter(qualified) |>
  mutate(
    pid = as.character(pid),
    age_group = cut(
      age,
      breaks = c(17, 24, 30, 35, 40),
      labels = c("18-24", "25-30", "31-35", "36-40")
    ),
    gender = case_when(
      gender %in% c("Man", "Male")     ~ "Man",
      gender %in% c("Woman", "Female") ~ "Woman",
      gender == "Prefer not to say"    ~ NA_character_,
      is.na(gender)                    ~ NA_character_,
      TRUE                             ~ "Non-binary/Other"
    ),
    ethnicity = case_when(
      ethnicity %in% c("White", "White alone")                                          ~ "White",
      ethnicity %in% c("Asian", "Asian alone", "Asian or Asian British")                ~ "Asian",
      ethnicity %in% c("Black", "Black or African American alone",
                       "Black, African, Caribbean or Black British")                    ~ "Black",
      ethnicity %in% c("Mixed", "Mixed or multiple ethnic groups", "Two or More Races") ~ "Mixed/Multiple",
      ethnicity == "Prefer not to say"                                                  ~ NA_character_,
      is.na(ethnicity)                                                                  ~ NA_character_,
      TRUE                                                                              ~ "Other"
    )
  ) |>
  select(pid, country, age, age_group, gender, ethnicity)

analytic_sample <- demographics |>
  filter(pid %in% analysis_pids, !is.na(age_group))

# --- Replicates manuscript.qmd chunk `model-data` ---------------------------

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
  left_join(
    total_playtime |> select(pid, wave, total_hours_per_day),
    by = c("pid", "wave")
  ) |>
  left_join(genre_hours_wide, by = c("pid", "wave")) |>
  mutate(
    total_hours_per_day = replace_na(total_hours_per_day, 0),
    across(all_of(gh_vars), ~ replace_na(.x, 0))
  ) |>
  group_by(pid) |>
  mutate(
    total_within  = total_hours_per_day -
                      mean(total_hours_per_day, na.rm = TRUE),
    total_between = mean(total_hours_per_day, na.rm = TRUE),
    across(
      all_of(gh_vars),
      list(
        within  = ~ .x - mean(.x, na.rm = TRUE),
        between = ~ mean(.x, na.rm = TRUE)
      ),
      .names = "{.col}_{.fn}"
    )
  ) |>
  ungroup()

gh_within  <- paste0(gh_vars, "_within")
gh_between <- paste0(gh_vars, "_between")

# --- Replicates manuscript.qmd chunk `sensitivity-demographics-bayes` -------

demo_data <- analysis_data |>
  left_join(analytic_sample |> select(pid, age, gender, ethnicity), by = "pid") |>
  filter(!is.na(age), !is.na(gender), !is.na(ethnicity), !is.na(wemwbs)) |>
  mutate(
    gender    = factor(gender, levels = c("Man", "Woman", "Non-binary/Other")),
    ethnicity = factor(ethnicity, levels = c("White", "Asian", "Black",
                                              "Mixed/Multiple", "Other"))
  )

message(sprintf(
  "Sensitivity data: %d observations from %d participants (%d genres)",
  nrow(demo_data), n_distinct(demo_data$pid), length(gh_vars)
))

message("Fitting H1 demographic sensitivity model ...")
h1_demo <- brm(
  bf(wemwbs ~ total_within + total_between + age + gender + ethnicity +
       (1 + total_within | pid)),
  data    = demo_data,
  prior   = prior(student_t(3, 0, 0.5), class = "b") +
            prior(student_t(3, 3, 2),   class = "Intercept"),
  family  = gaussian(),
  chains  = 4, iter = 4000, warmup = 2000, seed = 8675309,
  control = list(adapt_delta = 0.95),
  file    = here("models/h1_demographics")
)
message(sprintf("H1 demo model: max R-hat = %.4f, divergences = %d",
                max(brms::rhat(h1_demo), na.rm = TRUE),
                sum(subset(brms::nuts_params(h1_demo),
                           Parameter == "divergent__")$Value)))

message("Fitting H2 demographic sensitivity model ...")
h2_demo_formula <- bf(paste(
  "wemwbs ~ age + gender + ethnicity +",
  paste(c(gh_within, gh_between), collapse = " + "),
  "+ (1 | pid)"
))

h2_demo <- brm(
  formula = h2_demo_formula,
  data    = demo_data,
  prior   = prior(student_t(3, 0, 0.5), class = "b") +
            prior(student_t(3, 3, 2),   class = "Intercept"),
  family  = gaussian(),
  chains  = 4, iter = 4000, warmup = 2000, seed = 8675309,
  control = list(adapt_delta = 0.95),
  file    = here("models/h2_demographics")
)
message(sprintf("H2 demo model: max R-hat = %.4f, divergences = %d",
                max(brms::rhat(h2_demo), na.rm = TRUE),
                sum(subset(brms::nuts_params(h2_demo),
                           Parameter == "divergent__")$Value)))

message("Done. Caches written to models/h1_demographics.rds and models/h2_demographics.rds")
