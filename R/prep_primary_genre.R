# =============================================================================
# Primary-genre attribution (preregistered genre rule, current taxonomy)
# =============================================================================
#
# Writes data/processed/genre_wave_long_primary.csv with the same columns as
# data/processed/genre_wave_long.csv (pid, wave, genre, total_minutes,
# n_sessions, hours_per_day), but with PRIMARY attribution as preregistered:
# each game contributes its full session time to its first IGDB genre only.
#
# Everything else is the main pipeline (R/01_preprocess.R), reused by
# sourcing it: the Xbox genre rescue, clean_genre() collapsing to the 14
# study genres (Appendix B, Deviation D2), the analytic sample
# (analytic_pids()), the baseline-day wave assignment, and the aggregation.
# It deliberately does NOT use R/01_preprocess_prereg.R, whose taxonomy
# differs.
#
# "First genre" is the first label in the game's IGDB order that survives
# clean_genre() collapsing. A game whose first raw label is "Indie" (dropped
# from the taxonomy as a non-substantive label, D2) is therefore attributed
# to its next listed label, so the rule changes how playtime is attributed,
# not how much genre-matched playtime there is. The script reports how many
# games and minutes that affects.
#
# Used by the manuscript's Appendix D table of the registered frequentist
# analyses (chunk frequentist-registered, H2 under primary attribution).
#
# Usage (from the repo root): Rscript R/prep_primary_genre.R
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tidyverse)
})
here::i_am("R/prep_primary_genre.R")
source(here("R/01_preprocess.R"))  # functions only; its main block does not run

OUT_PATH <- "data/processed/genre_wave_long_primary.csv"

# --- Metadata: full-attribution long table, then the first valid label -------
# load_game_metadata_long() keeps IGDB label order within a game (unnest,
# filter and distinct preserve row order), so the first row per game is its
# first label that survives collapsing.
meta_long <- load_game_metadata_long()
meta_primary <- meta_long |>
  group_by(original_name, platform) |>
  slice(1) |>
  ungroup() |>
  mutate(n_genres_valid = 1L)

stopifnot(
  nrow(meta_primary) == nrow(distinct(meta_long, original_name, platform)),
  setequal(unique(meta_primary$genre), unique(meta_long$genre))
)

# Order check against the raw metadata: the primary label must be the first
# raw label after collapsing whenever that first raw label is not excluded.
meta_raw <- read_csv(here("data/clean/game_metadata.csv.gz"),
                     show_col_types = FALSE) |>
  populate_xbox_genres() |>
  filter(!is.na(genres) & nchar(genres) > 0) |>
  mutate(first_raw = map_chr(genres, \(g) parse_all_genres(g)[1]),
         first_clean = clean_genre(first_raw)) |>
  distinct(original_name, platform, first_raw, first_clean)
order_check <- meta_primary |>
  inner_join(meta_raw, by = c("original_name", "platform"),
             relationship = "one-to-many") |>
  filter(!is.na(first_clean))
stopifnot(nrow(order_check) > 0, all(order_check$genre == order_check$first_clean))
n_first_indie <- meta_raw |>
  filter(is.na(first_clean)) |>
  semi_join(meta_primary, by = c("original_name", "platform")) |>
  distinct(original_name, platform) |>
  nrow()

message(sprintf("Game-platform pairs with a study genre: %d", nrow(meta_primary)))
message(sprintf("  of which first raw label excluded (Indie), next label used: %d",
                n_first_indie))
message(sprintf("  full-attribution game-genre rows: %d; primary rows: %d",
                nrow(meta_long), nrow(meta_primary)))

# --- Sessions, waves, aggregation (main-pipeline functions) -----------------
survey <- load_survey_data()
genre_sessions <- load_genre_sessions(meta_primary)
genre_sessions_w <- add_waves(genre_sessions, survey)
genre_wave_long_primary <- aggregate_by_genre_wave(genre_sessions_w)

# Minutes attributed to games whose first raw label was Indie (informational)
indie_first_games <- meta_raw |>
  filter(is.na(first_clean)) |>
  distinct(original_name, platform)
min_indie_first <- genre_sessions_w |>
  semi_join(indie_first_games, by = c("title_id" = "original_name", "platform")) |>
  pull(duration) |>
  sum(na.rm = TRUE)
message(sprintf("  in-study minutes on those games: %.0f of %.0f (%.1f%%)",
                min_indie_first, sum(genre_sessions_w$duration, na.rm = TRUE),
                100 * min_indie_first / sum(genre_sessions_w$duration, na.rm = TRUE)))

# --- Guards -----------------------------------------------------------------
# 1. Same columns as the full-attribution file.
full <- read_csv(here("data/processed/genre_wave_long.csv"), show_col_types = FALSE)
stopifnot(identical(names(genre_wave_long_primary), names(full)))

# 2. Each session counts once, so the genre exposures of a person-wave sum to
#    at most its total console/PC playtime (equal when every played game has a
#    study genre).
total <- read_csv(here("data/processed/total_playtime.csv"), show_col_types = FALSE)
pw_check <- genre_wave_long_primary |>
  group_by(pid, wave) |>
  summarise(genre_sum = sum(hours_per_day), .groups = "drop") |>
  left_join(total |> select(pid, wave, total_hours_per_day), by = c("pid", "wave"))
stopifnot(!anyNA(pw_check$total_hours_per_day),
          all(pw_check$genre_sum <= pw_check$total_hours_per_day + 1e-9))

# 3. Same genres, same sample and same person-waves with genre-matched play as
#    the full-attribution file (only the split across genres differs).
stopifnot(
  setequal(unique(genre_wave_long_primary$genre), unique(full$genre)),
  all(genre_wave_long_primary$pid %in% analytic_pids()),
  nrow(distinct(genre_wave_long_primary, pid, wave)) ==
    nrow(distinct(full, pid, wave))
)

# 4. Each session is counted exactly once: per person-wave, the primary genre
#    exposures sum to the playtime of the raw sessions (loaded without any
#    genre join, as for total playtime) on games that carry at least one study
#    genre. This is independent of the primary join above, so a session lost
#    or duplicated by the attribution would fail it.
games_with_genre <- distinct(meta_long, original_name, platform)
matched_total <- load_raw_sessions() |>
  semi_join(games_with_genre, by = c("title_id" = "original_name", "platform")) |>
  add_waves(survey) |>
  group_by(pid, wave) |>
  summarise(h = sum(duration, na.rm = TRUE) / 60 / WAVE_LENGTH_DAYS, .groups = "drop")
matched_check <- full_join(pw_check |> select(pid, wave, genre_sum), matched_total,
                           by = c("pid", "wave"))
stopifnot(!anyNA(matched_check$genre_sum), !anyNA(matched_check$h),
          isTRUE(all.equal(matched_check$genre_sum, matched_check$h)))

message(sprintf("Person-waves with genre-matched play: %d (full attribution: %d)",
                nrow(pw_check), nrow(distinct(full, pid, wave))))
message(sprintf("Rows: primary %d, full attribution %d",
                nrow(genre_wave_long_primary), nrow(full)))
message(sprintf("Max genre sum / total ratio: %.4f",
                max(pw_check$genre_sum / pw_check$total_hours_per_day)))

write_csv(genre_wave_long_primary, here(OUT_PATH))
message(sprintf("Saved: %s (%d rows, %d participants, %d genres)",
                OUT_PATH, nrow(genre_wave_long_primary),
                n_distinct(genre_wave_long_primary$pid),
                n_distinct(genre_wave_long_primary$genre)))
