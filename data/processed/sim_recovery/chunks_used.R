## ---- model-data
#| label: model-data
#| include: false
#| cache: false   # options(mc.cores) side effect; cheap

options(mc.cores = max(1L, parallel::detectCores() - 1L))
dir.create(here("models"), showWarnings = FALSE, recursive = TRUE)

# --- Genre hours per (pid, wave) from full-attribution long file ---
# Since R/01_preprocess.R now produces genre_wave_long.csv with full
# attribution (each genre on a multi-genre game gets the full session
# duration, not 1/n_genres splitting), we read that file directly and
# pivot to wide format. The gh_* columns no longer sum to total playtime;
# instead, each gh_genre column represents "hours of exposure to games
# carrying that genre label." Total playtime is tracked separately via
# total_playtime.csv (no double-counting).

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

# Build (pid, wave) analysis frame
# Both H1 and H2 use Nintendo/Xbox/Steam only (total_hours_per_day, not total_time_all_platforms).  Mobile platforms provide only daily aggregates without game-level data; including them for H1 but not H2 would make "total playtime" mean different things across hypotheses.  The preregistered all-platform H1 model is fitted in chunk frequentist-registered (Appendix D).
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
    # H1: total playtime (console/PC only, consistent with H2 scope)
    total_within  = total_hours_per_day -
                      mean(total_hours_per_day, na.rm = TRUE),
    total_between = mean(total_hours_per_day, na.rm = TRUE),
    # H2: genre-specific hours (same platforms)
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

n_analysis_obs  <- nrow(analysis_data |> filter(!is.na(wemwbs)))
n_analysis_pids <- n_distinct(analysis_data$pid[!is.na(analysis_data$wemwbs)])
n_genres        <- length(gh_vars)



## ---- mm-data-setup
#| label: mm-data-setup
#| include: false

# --- Multi-membership data setup ---
# Transform genre hours into the format brms::mm() needs:
#   K constant genre-label columns (g_1 ... g_K)
#   K weight columns (w_1 ... w_K) = proportion of this wave's genre hours

genre_labels <- sort(gh_vars)
K <- length(genre_labels)

mm_data <- analysis_data |>
  rowwise() |>
  mutate(gh_row_total = sum(c_across(all_of(gh_vars)))) |>
  ungroup()

# Weights: proportion of playtime in each genre.
# For zero-playtime waves, use uniform 1/K (mm() needs nonzero weights).
for (i in seq_along(genre_labels)) {
  w_col <- paste0("w_", i)
  gh_col <- genre_labels[i]
  mm_data[[w_col]] <- ifelse(
    mm_data$gh_row_total > 0,
    mm_data[[gh_col]] / mm_data$gh_row_total,
    1 / K
  )
}

# Constant genre-label columns (strip "gh_" prefix)
for (i in seq_along(genre_labels)) {
  g_col <- paste0("g_", i)
  mm_data[[g_col]] <- sub("^gh_", "", genre_labels[i])
}

g_cols <- paste0("g_", seq_len(K))
w_cols <- paste0("w_", seq_len(K))

# Verify weights sum to ~1
w_sums <- mm_data |>
  rowwise() |>
  mutate(w_sum = sum(c_across(all_of(w_cols)))) |>
  pull(w_sum)
stopifnot(all(abs(w_sums - 1) < 0.001))

# Verify genre labels are constant across rows
for (col in g_cols) {
  stopifnot(n_distinct(mm_data[[col]]) == 1)
}

message(sprintf("mm() setup: %d genres, %d observations", K, nrow(mm_data)))

# Guard for the fixed Appendix F prose (M4): waves without genre-labelled play
# get uniform 1/K weights, and most of them have no recorded play at all.
mm_obs            <- !is.na(mm_data$wemwbs)
n_mm_uniform      <- sum(mm_data$gh_row_total == 0 & mm_obs)
n_mm_uniform_play <- sum(mm_data$gh_row_total == 0 & mm_data$total_hours_per_day > 0 & mm_obs)
stopifnot(n_mm_uniform_play / n_mm_uniform < 0.1)



## ---- mm-formula-setup
#| label: mm-formula-setup
#| include: false

# Build mm() formula
mm_term <- paste0(
  "mm(", paste(g_cols, collapse = ", "),
  ", weights = cbind(", paste(w_cols, collapse = ", "), "))"
)

# Full mm() formula: BOTH within and between genre random slopes (28 random effects).
# Computationally demanding: requires adapt_delta = 0.999 and iter = 8000.
# The fit is cached in models/h2_mm_model_full.rds via brms's file argument.
h2_mm_formula <- bf(paste0(
  "wemwbs ~ total_within + total_between + ",
  "(1 + total_within | pid) + ",
  "(0 + total_within + total_between | ", mm_term, ")"
))

# Discover auto-generated mm group name
mm_priors_check <- get_prior(
  h2_mm_formula,
  data = mm_data |> filter(!is.na(wemwbs))
)

mm_groups <- mm_priors_check |>
  filter(grepl("^mm", group)) |>
  pull(group) |>
  unique()

if (length(mm_groups) == 0) stop("No mm() group found in get_prior() output.")
mm_group_name <- mm_groups[1]
message(sprintf("mm() group name: %s", mm_group_name))

# Priors: brms defaults (since 2026-10-13, following co-author review), so
# sigma_s (the sd of the mm group) takes the default half-Student-t(3, 0, S)
# of all SDs. Until then: student_t(3, 0, 0.5) on b, student_t(3, 3, 2) on
# the Intercept and normal(0, 0.3) on the mm sd. mm_group_name is still
# needed to extract sigma_s (chunk h2-mm-sigma).

# Readable genre display names (column slug → label)
genre_display <- c(
  "adventure"                 = "Adventure",
  "arcade"                    = "Arcade",
  "fighting"                  = "Fighting",
  "hack_and_slash_beat_em_up" = "Hack & Slash / Beat 'em Up",
  "platform"                  = "Platform",
  "point_and_click"           = "Point-and-Click",
  "puzzle"                    = "Puzzle",
  "racing"                    = "Racing",
  "role_playing_rpg"          = "Role-playing",
  "shooter"                   = "Shooter",
  "simulator"                 = "Simulator",
  "sport"                     = "Sport",
  "strategy"                  = "Strategy",
  "visual_novel"              = "Visual Novel"
)

prettify_genre <- function(slug) {
  out <- genre_display[slug]
  # Fallback for any unrecognised slugs
  out[is.na(out)] <- str_replace_all(slug[is.na(out)], "_", " ") |> str_to_title()
  unname(out)
}



## ---- h2-mm-fit
#| label: h2-mm-fit
#| cache: false   # loads brms fits from models/*.rds; caching would serialise GBs
#| eval: true

h2_mm_model <- brm(
  formula = h2_mm_formula,
  data    = mm_data |> filter(!is.na(wemwbs)),
  # brms default priors (see mm-formula-setup).
  family  = gaussian(),
  chains  = 4,
  iter    = 8000,
  warmup  = 4000,
  seed    = 8675309,
  control = list(adapt_delta = 0.999, max_treedepth = 15),
  file    = here("models/h2_mm_model_full")
)



