# =============================================================================
# Data Preprocessing: Multi-Genre Assignment
# =============================================================================
#
# DEVIATION FROM PRE-REGISTRATION:
#   The pre-registered analysis (R/01_preprocess_prereg.R) used only the
#   PRIMARY (first) IGDB genre per game. This script instead assigns ALL IGDB
#   genres listed in game_metadata.csv.gz (MAX_GENRES_PER_GAME = 20, set above
#   the maximum observed so all labels are retained in practice).
#
# Rationale:
#   Many games genuinely span multiple genres (e.g., action-RPGs, strategy-
#   adventure games). Using only the primary genre discards meaningful
#   classification information and may bias genre-wellbeing associations
#   depending on IGDB's ordering conventions.
#
# Consequences:
#   - Sessions for multi-genre games contribute playtime to each of their
#     genres (full, not fractional playtime per genre).
#   - Genre playtime columns are NOT mutually exclusive: summing across genres
#     will exceed actual total playtime.
#   - Total playtime (for H1) is computed from raw sessions before the genre
#     join, avoiding any double-counting.
#   - The output is long-format (pid, wave, genre, hours_per_day) rather than
#     wide, as the wide format is ambiguous with overlapping genre counts.
#
# Pre-registered analyses are preserved in R/01_preprocess_prereg.R and will
# appear in supplementary materials.
#
# This script:
#   1. Loads game_metadata.csv.gz and expands genres to long format
#   2. Loads telemetry (Xbox, Steam, Nintendo) and joins long-format metadata
#   3. Assigns waves from participant-specific ideal_baseline_day
#   4. Aggregates to (pid, wave, genre) long format
#   5. Computes total (unique, no double-counting) playtime per (pid, wave)
#   6. Saves processed outputs to data/processed/
# =============================================================================

library(here)
library(tidyverse)

here::i_am("R/01_preprocess.R")

# =============================================================================
# Constants
# =============================================================================

# Cap on number of IGDB genres per game. Set high enough to retain all genres
# in practice (max observed raw labels per game: 16). Originally 3 in early
# drafts but raised because ~25% of labelled games carry >3 raw IGDB labels
# and truncation discards meaningful classification information.
MAX_GENRES_PER_GAME <- 20L
WAVE_LENGTH_DAYS <- 14L
N_WAVES <- 6L
# +14 day shift so wave W covers the 14 days *ending* on the wave W survey date
WAVE_SHIFT_DAYS <- 14L

# =============================================================================
# Genre Standardization
# =============================================================================
# Collapsed taxonomy:
#   Indie → excluded (NA)
#   TBS, RTS, Tactical, MOBA → Strategy
#   Card & Board Game, Quiz/Trivia → Puzzle
#   Pinball, Music → Arcade
#   Action, Adventure, and all other genres kept as-is (Shooter, RPG, Sport, Racing, etc.)
#
# NOTE: Action and Adventure are kept as separate genres (not merged into
# "Action & Adventure"). Sub-genres like Hack and slash, Point-and-click, and
# Visual Novel retain their raw IGDB labels.

#' Collapse a single raw IGDB genre label to the study taxonomy
#' @param genre_raw Character scalar
#' @return Collapsed genre label, or NA_character_ if excluded
clean_genre <- function(genre_raw) {
  case_when(
    genre_raw == "Indie" ~ NA_character_,
    genre_raw %in%
      c(
        "Turn-based strategy (TBS)",
        "Real Time Strategy (RTS)",
        "Tactical",
        "MOBA"
      ) ~ "Strategy",
    genre_raw == "Card & Board Game" ~ "Puzzle",
    genre_raw == "Quiz/Trivia" ~ "Puzzle",
    genre_raw == "Pinball" ~ "Arcade",
    genre_raw == "Music" ~ "Arcade",
    TRUE ~ genre_raw
  )
}

#' Extract raw genre labels from a comma-separated IGDB string in two steps:
#'   1. Extract ALL genres listed for the game as raw IGDB strings.
#'      No collapsing or filtering at this stage — that happens downstream
#'      in load_game_metadata_long() so the full raw list is available first.
#'   2. Truncate to MAX_GENRES_PER_GAME, preserving IGDB ordering.
#' @param igdb_genres Comma-separated IGDB genre string (may be NA)
#' @return Character vector of raw IGDB genre labels (length 0–MAX_GENRES_PER_GAME)
parse_all_genres <- function(igdb_genres) {
  if (is.na(igdb_genres) || igdb_genres == "") {
    return(character(0))
  }

  # Step 1: extract every raw IGDB genre label (no collapsing yet)
  all_genres <- str_split(igdb_genres, ",")[[1]] |>
    str_trim()

  # Step 2: keep at most MAX_GENRES_PER_GAME (preserving IGDB ordering)
  head(all_genres, MAX_GENRES_PER_GAME)
}

# =============================================================================
# Xbox Genre Rescue
# =============================================================================
# Xbox titles in the Open Play dataset use anonymized identifiers and cannot be
# matched against IGDB by name. The upstream open-play preprocessing
# (label_genres.R) attempts to map publisher genres to IGDB equivalents but
# fails for ~67% of Xbox playtime due to a string-formatting bug:
#   1. The mapping table assumes "Action + Adventure" format but the genres
#      column actually contains "Action & adventure", "ActionAndAdventure", etc.
#   2. The mapping does exact-string matching against multi-value strings.
#   3. Compound categories like "Action + Adventure" silently lose information
#      when collapsed to a single IGDB genre.
#
# We fix this in our local preprocessing using the cleaner publisher_primary_genre
# and publisher_subgenre fields, which are already in the "Action + Adventure"
# format expected by the mapping table.

#' Map an Xbox publisher genre string to one or more IGDB genre strings.
#'
#' Most categories map to a single IGDB genre. Microsoft's "Action + Adventure"
#' compound category maps to "Adventure" only (not both Action and Adventure),
#' because IGDB does not tag any Steam or Nintendo game as "Action" — its
#' taxonomy uses specific subgenres (Shooter, Hack and slash, Fighting, etc.)
#' instead. Expanding to "Action" would create an asymmetric Xbox-only
#' category that confounds genre with platform. This matches the behavior of
#' the upstream label_genres.R script.
#'
#' @param xbox_genre Character scalar (publisher_primary_genre or publisher_subgenre)
#' @return Character vector (length 0 if no mapping or excluded category)
xbox_to_igdb <- function(xbox_genre) {
  if (is.na(xbox_genre) || nchar(xbox_genre) == 0) {
    return(character(0))
  }
  switch(
    xbox_genre,
    "Action + Adventure"               = "Adventure",
    "Shooter"                          = "Shooter",
    "Role Playing"                     = "Role-playing (RPG)",
    "Puzzle + Trivia"                  = "Puzzle",
    "Sports"                           = "Sport",
    "Simulation"                       = "Simulator",
    "Racing + Flying"                  = "Racing",
    "Multi-Player Online Battle Arena" = "MOBA",
    "Platformer"                       = "Platform",
    "Fighting"                         = "Fighting",
    "Casino"                           = "Card & Board Game",
    "Strategy"                         = "Strategy",
    "Classics"                         = "Arcade",
    "Music"                            = "Music",
    "Card + Board"                     = "Card & Board Game",
    # Excluded categories: too vague to map meaningfully
    "Family + Kids"                    = character(0),
    "Other"                            = character(0),
    "Educational"                      = character(0),
    # Default: drop unknown categories rather than assigning incorrectly
    character(0)
  )
}

#' Populate empty Xbox `genres` cells from publisher genre fields.
#'
#' For Xbox rows where `genres` is missing/empty, applies xbox_to_igdb() to
#' both publisher_primary_genre and publisher_subgenre, combines unique
#' results, and writes them back to the `genres` column as a comma-separated
#' string. Steam and Nintendo rows are unchanged.
#'
#' @param meta Tibble loaded from game_metadata.csv.gz
#' @return Same tibble with `genres` populated for previously-empty Xbox rows
populate_xbox_genres <- function(meta) {

  is_xbox <- meta$platform == "Xbox"
  is_empty <- is.na(meta$genres) | nchar(meta$genres) == 0
  to_fix <- is_xbox & is_empty

  n_before <- sum(!is.na(meta$genres) & nchar(meta$genres) > 0 & is_xbox)
  n_to_fix <- sum(to_fix)

  if (n_to_fix == 0) {
    message("populate_xbox_genres: no Xbox rows need fixing")
    return(meta)
  }

  # Map publisher_primary_genre and publisher_subgenre for each row that needs it
  rescued <- character(n_to_fix)
  fix_idx <- which(to_fix)

  for (k in seq_along(fix_idx)) {
    i <- fix_idx[k]
    primary <- meta$xbox_primary_genre[i]
    subgenre <- meta$xbox_subgenre[i]

    igdb_genres <- unique(c(xbox_to_igdb(primary), xbox_to_igdb(subgenre)))
    if (length(igdb_genres) == 0) {
      rescued[k] <- NA_character_
    } else {
      rescued[k] <- paste(igdb_genres, collapse = ", ")
    }
  }

  meta$genres[fix_idx] <- rescued

  n_rescued <- sum(!is.na(rescued))
  n_after <- sum(!is.na(meta$genres) & nchar(meta$genres) > 0 & is_xbox)
  message(sprintf(
    "populate_xbox_genres: rescued %d / %d Xbox rows (Xbox with genres: %d -> %d)",
    n_rescued, n_to_fix, n_before, n_after
  ))

  meta
}

# =============================================================================
# Data Loading
# =============================================================================

#' Load game metadata in long format: one row per (game, platform, genre).
#' Games with N valid genres produce N rows (up to MAX_GENRES_PER_GAME).
#'
#' Processing steps:
#'   1. parse_all_genres() extracts raw IGDB labels and caps at MAX_GENRES_PER_GAME.
#'   2. Unnest to one row per raw genre label.
#'   3. Apply clean_genre() to collapse to the study taxonomy (Indie → NA, etc.).
#'   4. Drop excluded genres (NA after collapsing) and deduplicate within each game
#'      (e.g. raw "Turn-based strategy (TBS)" + "Tactical" both collapse to
#'      "Strategy" → one row, so session counts are not inflated).
#'   5. Count n_genres_valid: distinct genres remaining after collapsing.
#'
#' @return tibble: original_name, platform, genre, n_genres_valid
load_game_metadata_long <- function() {
  meta <- read_csv(
    here("data/clean/game_metadata.csv.gz"),
    show_col_types = FALSE
  )

  # Phase 0 fix: rescue Xbox genres that the upstream pipeline failed to map.
  # Uses publisher_primary_genre + publisher_subgenre to populate empty Xbox
  # rows. See xbox_to_igdb() and populate_xbox_genres() above for details.
  meta <- populate_xbox_genres(meta)

  meta |>
    filter(!is.na(genres) & nchar(genres) > 0) |>
    select(original_name, platform, genres) |>
    # Step 1: extract raw IGDB genres (capped at MAX_GENRES_PER_GAME)
    mutate(genre_list = map(genres, parse_all_genres)) |>
    filter(map_int(genre_list, length) > 0) |>
    # Step 2: one row per raw genre label
    unnest(genre_list) |>
    rename(genre_raw = genre_list) |>
    # Step 3: collapse to study taxonomy
    mutate(genre = clean_genre(genre_raw)) |>
    # Step 4: drop excluded genres; deduplicate within game × platform on the
    #   collapsed genre (not genre_raw) so that two raw labels collapsing to the
    #   same study genre don't produce duplicate rows and inflate session counts.
    filter(!is.na(genre)) |>
    distinct(original_name, platform, genre) |>
    # Step 5: count valid genres per game after collapsing
    add_count(original_name, platform, name = "n_genres_valid") |>
    select(original_name, platform, genre, n_genres_valid)
}

#' Load sessions for a single platform, normalising column names.
#' @param file Path to CSV (relative to project root)
#' @param platform Platform label ("Xbox", "Steam", "Nintendo")
#' @param date_col Name of the column containing session start timestamps
#' @param duration_col Name of the column containing session duration in minutes
#' @return tibble: pid, platform, title_id, date, duration
load_platform_sessions <- function(file, platform, date_col,
                                   duration_col = "duration") {
  read_csv(here(file), show_col_types = FALSE) |>
    mutate(
      platform = platform,
      date = as.Date(.data[[date_col]]),
      duration = .data[[duration_col]]
    ) |>
    select(pid, platform, title_id, date, duration)
}

#' Load raw sessions for all platforms, without any genre join.
#' Used to compute total playtime free of multi-genre double-counting.
#' @return tibble: pid, platform, title_id, date, duration
load_raw_sessions <- function() {
  bind_rows(
    load_platform_sessions(
      "data/clean/xbox.csv.gz", "Xbox", "session_start"
    ),
    load_platform_sessions(
      "data/clean/steam.csv.gz", "Steam", "approximate_session_start",
      duration_col = "minutes"
    ),
    load_platform_sessions(
      "data/clean/nintendo.csv.gz", "Nintendo", "session_start"
    )
  )
}

#' Load telemetry joined to long-format metadata.
#' Sessions for multi-genre games appear once per genre (many-to-many join).
#' @param meta_long Long-format metadata from load_game_metadata_long()
#' @return tibble: pid, platform, title_id, date, duration, genre, n_genres_valid
load_genre_sessions <- function(meta_long) {
  join_genres <- function(sessions, platform_name) {
    sessions |>
      left_join(
        meta_long |> filter(platform == platform_name),
        join_by(title_id == original_name, platform),
        relationship = "many-to-many"
      ) |>
      filter(!is.na(genre)) |>
      select(pid, platform, title_id, date, duration, genre, n_genres_valid)
  }

  bind_rows(
    load_platform_sessions(
      "data/clean/xbox.csv.gz", "Xbox", "session_start"
    ) |> join_genres("Xbox"),
    load_platform_sessions(
      "data/clean/steam.csv.gz", "Steam", "approximate_session_start",
      duration_col = "minutes"
    ) |> join_genres("Steam"),
    load_platform_sessions(
      "data/clean/nintendo.csv.gz", "Nintendo", "session_start"
    ) |> join_genres("Nintendo")
  )
}

#' Load biweekly survey data and compute SWEMWBS score
#'
#' Outcome is the item-mean on the 1-5 scale (NOT the 7-35 summed score).
#' This matches the scale Ballou, Sewall et al. (2024) and the present
#' pre-registration use to define the SESOI of 0.06 per hour/day of playtime.
#' The previous implementation used rowSums (7-35 scale), which produced
#' coefficients 7x larger than the scale the SESOI is defined in. See plan
#' document for the SESOI scale correction.
load_survey_data <- function() {
  read_csv(here("data/clean/survey_biweekly.csv.gz"), show_col_types = FALSE) |>
    mutate(
      wemwbs = rowMeans(across(starts_with("wemwbs_")), na.rm = FALSE),
      baseline_date = as.Date(ideal_baseline_day)
    ) |>
    # The clean file contains a handful of rows with wave == 7, outside the
    # six-wave design; they would otherwise enter models with playtime
    # structurally zero-coded (telemetry wave assignment caps at N_WAVES).
    filter(wave >= 1, wave <= N_WAVES) |>
    select(
      pid,
      wave,
      date,
      baseline_date,
      wemwbs,
      affective_valence,
      life_sat,
      self_reported_biweekly_play
    )
}

# =============================================================================
# Wave Assignment
# =============================================================================

#' Assign study wave (1–6) from session dates and participant baseline dates.
#' Vectorized: accepts Date vectors and returns an integer vector.
#'
#' ALIGNMENT WITH SWEMWBS RETROSPECTIVE WINDOW:
#'   SWEMWBS asks "over the past 2 weeks", and wave 1 is completed on the
#'   baseline day (day 0). To pair each telemetry window with the SWEMWBS that
#'   covers it, we shift by +WAVE_SHIFT_DAYS so that wave W playtime = the
#'   14-day period *ending* on the day wave W was completed:
#'
#'     Wave 1 playtime: days -14 to -1  (2 weeks before baseline)
#'     Wave 2 playtime: days   0 to 13
#'     Wave 3 playtime: days  14 to 27
#'     Wave 4 playtime: days  28 to 41
#'     Wave 5 playtime: days  42 to 55
#'     Wave 6 playtime: days  56 to 69
#'
#'   Without this shift, wave 1 playtime (days 0-13) would follow wave 1
#'   SWEMWBS in time rather than precede it, misaligning the predictors with
#'   what participants were actually reporting on.
#'
#' @param obs_date Date vector of session dates
#' @param baseline_date Date vector of participant baseline dates
#' @return Integer vector of wave assignments (1–N_WAVES), or NA
assign_wave_vec <- function(obs_date, baseline_date) {
  days <- as.integer(obs_date - baseline_date) + WAVE_SHIFT_DAYS
  wave <- (days %/% WAVE_LENGTH_DAYS) + 1L
  if_else(
    is.na(obs_date) | is.na(baseline_date) | days < 0L | wave > N_WAVES,
    NA_integer_,
    wave
  )
}

add_waves <- function(sessions, survey) {
  baselines <- survey |> distinct(pid, baseline_date)
  sessions |>
    left_join(baselines, join_by(pid)) |>
    filter(!is.na(baseline_date)) |>
    mutate(wave = assign_wave_vec(date, baseline_date)) |>
    filter(!is.na(wave), wave >= 1L, wave <= N_WAVES)
}

# =============================================================================
# Aggregation
# =============================================================================

#' Aggregate genre sessions to (pid, wave, genre) level.
#'
#' NOTE ON DOUBLE-COUNTING: sessions for multi-genre games appear once per
#' genre. hours_per_day here means "hours/day spent playing games classified
#' as this genre", not "hours/day spent on this genre exclusively". Summing
#' across genres will exceed total playtime for participants with multi-genre
#' games.
#'
#' @return Long tibble: pid, wave, genre, total_minutes, n_sessions, hours_per_day
aggregate_by_genre_wave <- function(genre_sessions_with_waves) {
  genre_sessions_with_waves |>
    group_by(pid, wave, genre) |>
    summarise(
      total_minutes = sum(duration, na.rm = TRUE),
      n_sessions = n(),
      .groups = "drop"
    ) |>
    mutate(hours_per_day = total_minutes / 60 / WAVE_LENGTH_DAYS)
}

#' Compute total unique playtime per (pid, wave) from raw sessions.
#' No double-counting: each session counted once regardless of genre count.
#'
#' @return tibble: pid, wave, total_minutes, total_hours_per_day
aggregate_total_playtime <- function(raw_sessions_with_waves) {
  raw_sessions_with_waves |>
    group_by(pid, wave) |>
    summarise(
      total_minutes = sum(duration, na.rm = TRUE),
      total_hours_per_day = total_minutes / 60 / WAVE_LENGTH_DAYS,
      n_sessions = n(),
      .groups = "drop"
    )
}

# =============================================================================
# Main Preprocessing Pipeline
# =============================================================================

#' Run full multi-genre preprocessing pipeline.
#' @return Named list with:
#'   - genre_wave_long:  (pid, wave, genre, total_minutes, n_sessions, hours_per_day)
#'   - total_playtime:   (pid, wave, total_minutes, total_hours_per_day, n_sessions)
#'   - meta_long:        (original_name, platform, genre, n_genres_valid)
#'   - survey:           (pid, wave, date, baseline_date, wemwbs, ...)
preprocess_genre_data_multigene <- function() {
  message("=== Multi-Genre Preprocessing (Deviation from Pre-Registration) ===")
  message(sprintf("  Max genres per game: %d\n", MAX_GENRES_PER_GAME))

  # --- Metadata ---
  message("Loading game metadata (long format)...")
  meta_long <- load_game_metadata_long()

  n_games_total <- meta_long |> distinct(original_name, platform) |> nrow()
  message(sprintf(
    "  %d unique game-platform pairs → %d game-genre rows",
    n_games_total,
    nrow(meta_long)
  ))

  genre_dist <- meta_long |>
    distinct(original_name, platform, n_genres_valid) |>
    count(n_genres_valid, name = "n_games") |>
    mutate(pct = round(100 * n_games / n_games_total, 1))
  message("  Genres per game:")
  walk(seq_len(nrow(genre_dist)), function(i) {
    message(sprintf(
      "    %d genre(s): %d games (%.1f%%)",
      genre_dist$n_genres_valid[i],
      genre_dist$n_games[i],
      genre_dist$pct[i]
    ))
  })
  message(sprintf(
    "  Genres present: %s\n",
    paste(sort(unique(meta_long$genre)), collapse = ", ")
  ))

  # --- Survey ---
  message("Loading survey data...")
  survey <- load_survey_data()
  message(sprintf(
    "  %d observations, %d participants\n",
    nrow(survey),
    n_distinct(survey$pid)
  ))

  # --- Genre sessions (with multi-genre duplication) ---
  message("Loading genre sessions (many-to-many join)...")
  genre_sessions <- load_genre_sessions(meta_long)
  message(sprintf(
    "  %d session-genre rows, %d participants\n",
    nrow(genre_sessions),
    n_distinct(genre_sessions$pid)
  ))

  # --- Raw sessions (for total playtime, no duplication) ---
  message("Loading raw sessions (for total playtime)...")
  raw_sessions <- load_raw_sessions()
  message(sprintf(
    "  %d sessions, %d participants\n",
    nrow(raw_sessions),
    n_distinct(raw_sessions$pid)
  ))

  # --- Assign waves ---
  message("Assigning waves from participant-specific baseline dates...")
  genre_sessions_w <- add_waves(genre_sessions, survey)
  raw_sessions_w <- add_waves(raw_sessions, survey)
  message(sprintf(
    "  Genre sessions with valid wave: %d",
    nrow(genre_sessions_w)
  ))
  message(sprintf(
    "  Raw sessions with valid wave:   %d\n",
    nrow(raw_sessions_w)
  ))

  # --- Aggregate ---
  message("Aggregating...")
  genre_wave_long <- aggregate_by_genre_wave(genre_sessions_w)
  total_playtime <- aggregate_total_playtime(raw_sessions_w)
  message(sprintf(
    "  Genre-wave long:  %d rows (%d pid × wave × genre combinations)",
    nrow(genre_wave_long),
    nrow(genre_wave_long)
  ))
  message(sprintf(
    "  Total playtime:   %d pid-wave observations\n",
    nrow(total_playtime)
  ))

  list(
    genre_wave_long = genre_wave_long,
    total_playtime = total_playtime,
    meta_long = meta_long,
    survey = survey
  )
}

# =============================================================================
# Run if executed directly
# =============================================================================

if (sys.nframe() == 0) {
  result <- preprocess_genre_data_multigene()

  dir.create(here("data/processed"), showWarnings = FALSE, recursive = TRUE)

  write_csv(result$genre_wave_long, here("data/processed/genre_wave_long.csv"))
  message(sprintf(
    "Saved: data/processed/genre_wave_long.csv (%d rows)",
    nrow(result$genre_wave_long)
  ))

  write_csv(result$total_playtime, here("data/processed/total_playtime.csv"))
  message(sprintf(
    "Saved: data/processed/total_playtime.csv (%d rows)",
    nrow(result$total_playtime)
  ))

  write_csv(result$meta_long, here("data/processed/game_metadata_long.csv"))
  message(sprintf(
    "Saved: data/processed/game_metadata_long.csv (%d rows)",
    nrow(result$meta_long)
  ))
}
