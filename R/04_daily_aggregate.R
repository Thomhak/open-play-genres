# =============================================================================
# Daily Diary Aggregation: Same-Day Exposure Windows
# =============================================================================
#
# Companion to R/01_preprocess.R. Where 01_preprocess.R aggregates telemetry to
# biweekly waves (14-day windows anchored on participant-specific baseline
# dates), this script aggregates the SAME exposures to each diary response's
# own day.
#
# Exposure windows (two per response):
#   ANALYSIS ("today"): [4 a.m. local of the response's waking day, completion].
#     Matches the outcome item's reference frame ("I was satisfied with my
#     life today"). Local time is inferred per participant from the survey's
#     2 p.m.-3 a.m. local availability window (see infer_utc_offsets).
#     Window length therefore varies with response time (about 10-23 h).
#   CONTROL (24 h): [completion - 24h, completion]. Retained ONLY for the
#     played24hr positive control, whose self-report item asks about the past
#     24 hours. Consecutive 24 h windows may overlap; today windows of
#     consecutive responses never overlap (they share at most the 4 a.m.
#     boundary instant).
#   Every console/PC session is clipped to the window and only the clipped
#   portion is counted.
#
# Clipping rules:
#   Nintendo, Xbox: overlap_minutes = max(0, min(session_end, win_end) -
#     max(session_start, win_start)). In these files duration equals
#     (session_end - session_start) exactly, so clipping the interval and
#     clipping the duration are the same operation.
#   Steam: sessions are reconstructed from hourly playtime snapshots, so the
#     approximate interval is a bracket rather than a measured span and
#     `minutes` may be smaller than the span. The row's `minutes` is therefore
#     scaled by the clipped share of the approximate span. If the span is zero
#     or missing, `minutes` is counted in full when the session start falls
#     inside the window.
#
# Genre attribution:
#   FULL attribution, as in 01_preprocess.R. A game carrying k genre labels
#   contributes its full clipped minutes to each of the k genres, so genre
#   hours are NOT mutually exclusive and do not sum to total_hours_24h.
#   Genres come from data/processed/game_metadata_long.csv, joined on
#   (title_id == original_name, platform), the same key 01_preprocess.R uses.
#
# Coverage flags:
#   A zero in total_hours_24h can mean three different things, so both output
#   frames carry two flags, appended as the last two columns:
#     has_telemetry  participant-level; TRUE when the participant has at least
#                    one session row on any of the three platforms
#     covered        response-level; TRUE when the 24-hour window overlaps the
#                    participant's pooled telemetry span (FALSE whenever
#                    has_telemetry is FALSE)
#   Only zeros with covered == TRUE are behavioural no-play days.
#
# Outputs (data/processed/daily/):
#   diary_analysis.csv     one row per diary response, with total_hours_24h
#   genre_day_long.csv     (pid, day, genre, hours), positive rows only
#   daily_model_frame.csv  diary_analysis widened with one gh_{genre} column
#   marginals_report.txt   marginal descriptives (Deliverable 2)
#
# Prespecification note: this script computes marginal distributions only. It
# deliberately does NOT cross any exposure with any wellbeing outcome.
# =============================================================================

library(here)
library(tidyverse)
library(data.table)

here::i_am("R/04_daily_aggregate.R")

# =============================================================================
# Constants
# =============================================================================

WINDOW_HOURS <- 24
WINDOW_SECONDS <- WINDOW_HOURS * 3600
N_DIARY_DAYS <- 30L
N_WAVES <- 6L
# Tolerance for floating-point comparisons on minute-scale quantities
EPS_MINUTES <- 1e-6

# Analysis window ("today"): from 4:00 a.m. LOCAL time of the response's
# waking day to the completion timestamp, matching the outcome item's
# same-day reference frame ("I was satisfied with my life today"). The 4 a.m.
# boundary is the dataset's own day convention (the LOTUD time-use diary) and
# assigns responses completed between midnight and 3 a.m. to the waking day
# that began the previous morning. The 24-hour window is retained ONLY for
# the played24hr positive control, whose self-report item asks about the
# past 24 hours.
DAY_START_SECONDS <- 4L * 3600L
# Candidate UTC offsets: US zones (with DST variants) and UK for the handful
# of UK-flagged diary participants. Offsets are inferred per participant from
# the survey's 2 p.m.-3 a.m. local availability window; a residual DST error
# of one hour moves the 4 a.m. boundary to 3 or 5 a.m., where play is rare.
OFFSET_CANDIDATES <- c(-4L, -5L, -6L, -7L, -8L, 0L, 1L)

OUT_DIR <- here("data/processed/daily")

# =============================================================================
# Helpers
# =============================================================================

#' Sanitise a genre label into a wide-format column name.
#' Matches the manuscript's genre_to_col() slug rule (lowercase, runs of
#' non-alphanumerics collapsed to "_", leading/trailing "_" trimmed) but uses
#' the gh_ prefix for "genre hours" in the 24-hour window.
#' @param g Character vector of genre labels
#' @return Character vector of column names
genre_to_gh_col <- function(g) {
  col <- gsub("[^a-z0-9]+", "_", tolower(g))
  col <- gsub("^_+|_+$", "", col)
  paste0("gh_", col)
}

#' Format a numeric vector for the marginals report.
fmt <- function(x, digits = 3) {
  formatC(x, format = "f", digits = digits)
}

# =============================================================================
# Data Loading
# =============================================================================

#' Load the daily diary survey and define the 24-hour exposure window.
#'
#' `wave` in survey_daily.csv.gz is the diary day index (1-30), not a biweekly
#' wave; it is renamed `day` to avoid confusion with the wave variable used by
#' 01_preprocess.R. `date` is the completion timestamp (UTC).
#'
#' Rows with missing outcomes are KEPT: models filter them at fitting time, and
#' dropping them here would distort the compliance and exposure marginals.
#'
#' @return list(diary = tibble, n_att_failed = integer)
load_daily_survey <- function() {
  raw <- read_csv(here("data/clean/survey_daily.csv.gz"), show_col_types = FALSE)

  # Attention check: the Open Play data paper states failures were already
  # removed upstream. Filter only if any survivors are present.
  n_att_failed <- 0L
  if ("bpnsfs_failed_att_check" %in% names(raw)) {
    n_att_failed <- sum(raw$bpnsfs_failed_att_check %in% TRUE)
    if (n_att_failed > 0L) {
      message(sprintf(
        "  Attention check: removing %d row(s) with bpnsfs_failed_att_check == TRUE",
        n_att_failed
      ))
      raw <- raw |> filter(!(bpnsfs_failed_att_check %in% TRUE))
    } else {
      message("  Attention check: 0 rows with bpnsfs_failed_att_check == TRUE (nothing removed)")
    }
  }

  diary <- raw |>
    transmute(
      pid,
      day = as.integer(wave),
      completion = date,
      life_sat,
      affective_valence,
      played24hr
    ) |>
    filter(!is.na(completion), !is.na(day))

  list(diary = diary, n_att_failed = n_att_failed)
}

#' Infer each participant's UTC offset from the survey availability window.
#'
#' Daily survey links opened at 2 p.m. local time and closed at 3 a.m., so a
#' response's LOCAL clock time should fall in [14:00, 24:00) or [00:00, 03:00).
#' Candidate offsets are restricted by intake country (US: UTC-4..-8;
#' UK: UTC+0/+1; unknown: all), which prevents the availability constraint
#' from assigning US participants to UTC+0. Among candidates the fewest
#' availability violations wins; ties are broken by placing the participant's
#' MEDIAN local completion hour closest to 19:30, the evening norm of
#' decisively identified participants, which is far more stable for sparse
#' responders than any single-response anchor. Participants whose best
#' assignment still violates more than 20% of their responses are flagged
#' tz_unreliable (their timestamps are inconsistent with the availability
#' window under every candidate; a sensitivity refit excludes them). DST is
#' not modelled; a one-hour residual error moves the 4 a.m. boundary to 3 or
#' 5 a.m., where play is rare.
#'
#' @param diary tibble with pid and completion (UTC POSIXct)
#' @return tibble: pid, utc_offset, n_viol, n_resp, tz_unreliable
infer_utc_offsets <- function(diary) {
  countries <- read_csv(here("data/clean/survey_intake.csv.gz"),
                        show_col_types = FALSE) |>
    select(pid, country)

  hrs <- diary |>
    mutate(utc_frac = as.numeric(completion) %% 86400 / 3600) |>
    select(pid, utc_frac) |>
    left_join(countries, join_by(pid))

  per_offset <- map_dfr(OFFSET_CANDIDATES, function(off) {
    hrs |>
      mutate(
        local_frac = (utc_frac + off) %% 24,
        viol = !(local_frac >= 14 | local_frac < 3),
        # hours after 14:00 local, so the median is not wrapped at midnight
        since14 = (local_frac - 14) %% 24
      ) |>
      group_by(pid, country) |>
      summarise(
        utc_offset = off,
        n_viol = sum(viol),
        n_resp = n(),
        med_since14 = median(since14),
        .groups = "drop"
      )
  }) |>
    filter(
      case_when(
        country %in% "US" ~ utc_offset <= -4,
        country %in% "UK" ~ utc_offset >= 0,
        TRUE ~ TRUE
      )
    )

  per_offset |>
    group_by(pid) |>
    mutate(best = n_viol == min(n_viol)) |>
    summarise(
      # 19:30 local is 5.5 h after the 14:00 link arrival
      utc_offset = utc_offset[best][which.min(abs(med_since14[best] - 5.5))],
      n_viol = min(n_viol),
      n_resp = first(n_resp),
      tz_unreliable = n_viol / n_resp > 0.2,
      .groups = "drop"
    )
}

#' Attach both exposure windows to the diary.
#'
#' Analysis window ("today"): [4 a.m. local of the waking day, completion].
#' Control window: [completion - 24 h, completion], for played24hr only.
#' The waking-day anchor is computed in epoch arithmetic: shift to local
#' time, floor to the most recent 4 a.m., shift back to UTC.
#'
#' @return diary with utc_offset, tz_unreliable, win_start, win_end,
#'   window_hours, win24_start, win24_end
add_windows <- function(diary, offsets) {
  diary |>
    left_join(offsets, join_by(pid)) |>
    mutate(
      local_epoch = as.numeric(completion) + utc_offset * 3600,
      day_anchor_local =
        floor((local_epoch - DAY_START_SECONDS) / 86400) * 86400 +
        DAY_START_SECONDS,
      win_start = as.POSIXct(day_anchor_local - utc_offset * 3600,
                             origin = "1970-01-01", tz = "UTC"),
      win_end = completion,
      window_hours = as.numeric(difftime(win_end, win_start, units = "hours")),
      win24_start = completion - WINDOW_SECONDS,
      win24_end = completion
    ) |>
    select(-local_epoch, -day_anchor_local)
}

#' Load session-level telemetry for the three game-level platforms.
#'
#' Column names are normalised to (pid, platform, title_id, session_start,
#' session_end, minutes, span_minutes). `minutes` is the platform's own
#' duration measure; `span_minutes` is the wall-clock span of the session
#' interval, used only by the Steam scaling rule.
#'
#' @param keep_pids Character vector of participant ids to retain
#' @return tibble of sessions
load_daily_sessions <- function(keep_pids) {
  read_platform <- function(file, platform, start_col, end_col, minutes_col) {
    d <- read_csv(here(file), show_col_types = FALSE)
    d |>
      filter(pid %in% keep_pids) |>
      transmute(
        pid,
        platform = platform,
        title_id,
        session_start = .data[[start_col]],
        session_end = .data[[end_col]],
        minutes = .data[[minutes_col]]
      ) |>
      filter(!is.na(session_start), !is.na(session_end), !is.na(minutes)) |>
      mutate(
        span_minutes = as.numeric(difftime(session_end, session_start, units = "mins"))
      )
  }

  bind_rows(
    read_platform(
      "data/clean/nintendo.csv.gz", "Nintendo",
      "session_start", "session_end", "duration"
    ),
    read_platform(
      "data/clean/xbox.csv.gz", "Xbox",
      "session_start", "session_end", "duration"
    ),
    read_platform(
      "data/clean/steam.csv.gz", "Steam",
      "approximate_session_start", "approximate_session_end", "minutes"
    )
  )
}

#' Load the genre lookup produced by 01_preprocess.R.
#' @return tibble: original_name, platform, genre, n_genres_valid
load_meta_long <- function() {
  path <- here("data/processed/game_metadata_long.csv")
  if (!file.exists(path)) {
    stop(
      "Missing data/processed/game_metadata_long.csv. ",
      "Run `Rscript R/01_preprocess.R` first."
    )
  }
  read_csv(path, show_col_types = FALSE)
}

#' Load the biweekly survey and compute SWEMWBS as the 1-5 item mean.
#' Mirrors load_survey_data() in 01_preprocess.R.
#' @return tibble: pid, wave, wemwbs
load_biweekly_wemwbs <- function() {
  read_csv(here("data/clean/survey_biweekly.csv.gz"), show_col_types = FALSE) |>
    mutate(wemwbs = rowMeans(across(starts_with("wemwbs_")), na.rm = FALSE)) |>
    filter(wave >= 1, wave <= N_WAVES) |>
    select(pid, wave, wemwbs)
}

# =============================================================================
# Telemetry Coverage Flags
# =============================================================================
# Zeros in total_hours_24h are of three kinds and must not be pooled: a
# participant with no linked console/PC account at all, a window falling
# outside the period their telemetry covers, and a genuine no-play day inside
# coverage. These two flags let a model separate them.

#' Participant-level telemetry availability and pooled observation span.
#'
#' has_telemetry is TRUE when the participant has at least one session row on
#' any of Nintendo, Xbox or Steam in the raw clean files. The span pools all
#' three platforms, using approximate_session_start/end for Steam.
#'
#' @param sessions tibble from load_daily_sessions()
#' @return tibble: pid, has_telemetry, t_first, t_last
compute_telemetry_span <- function(sessions) {
  sessions |>
    group_by(pid) |>
    summarise(
      t_first = min(session_start),
      t_last = max(session_end),
      .groups = "drop"
    ) |>
    mutate(has_telemetry = TRUE)
}

#' Response-level coverage flags.
#'
#' The flag is TRUE when the response's window overlaps the participant's
#' pooled telemetry span. Participants with no telemetry get
#' has_telemetry = FALSE and a FALSE flag. The window columns are taken from
#' win_start/win_end, so the caller chooses which window is being flagged;
#' flag_name names the output column (covered for the analysis window,
#' covered24 for the control window).
#'
#' @param diary tibble with pid, day, win_start, win_end
#' @param span tibble from compute_telemetry_span()
#' @return tibble: pid, day, has_telemetry, <flag_name>
build_coverage_flags <- function(diary, span, flag_name = "covered") {
  out <- diary |>
    select(pid, day, win_start, win_end) |>
    left_join(span, join_by(pid)) |>
    mutate(
      has_telemetry = replace_na(has_telemetry, FALSE),
      flag = has_telemetry &
        !is.na(t_first) & !is.na(t_last) &
        win_end >= t_first & win_start <= t_last
    ) |>
    select(pid, day, has_telemetry, flag)
  names(out)[names(out) == "flag"] <- flag_name
  out
}

# =============================================================================
# Interval Clipping
# =============================================================================

#' Clip every session to every diary window it overlaps.
#'
#' Uses a data.table interval join (foverlaps) so the full telemetry can be
#' processed without materialising a pid-level cartesian product.
#'
#' clipped_minutes is defined per the platform rules documented in the header:
#' the intersected wall-clock minutes for Nintendo and Xbox, and `minutes`
#' rescaled by the intersected share of the approximate span for Steam.
#'
#' @param sessions tibble from load_daily_sessions()
#' @param diary tibble from load_daily_survey()
#' @return tibble: pid, day, platform, title_id, session_start, session_end,
#'   win_start, win_end, minutes, span_minutes, overlap_minutes, clipped_minutes
clip_sessions_to_windows <- function(sessions, diary) {
  win_dt <- as.data.table(diary)[, .(pid, day, win_start, win_end)]
  setkey(win_dt, pid, win_start, win_end)

  ses_dt <- as.data.table(sessions)

  hits <- foverlaps(
    ses_dt,
    win_dt,
    by.x = c("pid", "session_start", "session_end"),
    type = "any",
    nomatch = NULL
  )

  hits[, overlap_minutes := pmax(
    0,
    as.numeric(difftime(
      pmin(session_end, win_end),
      pmax(session_start, win_start),
      units = "mins"
    ))
  )]

  # Steam: rescale `minutes` by the clipped share of the approximate span.
  # Degenerate spans (zero or missing) fall back to counting `minutes` in full
  # when the session start lies inside the window.
  hits[, clipped_minutes := fifelse(
    platform != "Steam",
    overlap_minutes,
    fifelse(
      is.na(span_minutes) | span_minutes <= 0,
      fifelse(
        !is.na(session_start) & session_start >= win_start & session_start <= win_end,
        minutes,
        0
      ),
      minutes * (overlap_minutes / span_minutes)
    )
  )]

  hits <- hits[clipped_minutes > EPS_MINUTES]

  as_tibble(hits) |>
    select(
      pid, day, platform, title_id,
      session_start, session_end, win_start, win_end,
      minutes, span_minutes, overlap_minutes, clipped_minutes
    )
}

# =============================================================================
# Aggregation
# =============================================================================

#' Total clipped playtime per diary response, all three platforms pooled.
#' No genre join, so no multi-genre double-counting. out_col names the
#' resulting column (total_hours_today for the analysis window,
#' total_hours_24h for the control window).
#' @return tibble: pid, day, <out_col>
aggregate_total <- function(clipped, out_col) {
  out <- clipped |>
    group_by(pid, day) |>
    summarise(
      total_hours = sum(clipped_minutes, na.rm = TRUE) / 60,
      .groups = "drop"
    )
  names(out)[names(out) == "total_hours"] <- out_col
  out
}

#' Per-genre clipped playtime per diary response (analysis window).
#' Full attribution: a k-genre game's clipped minutes count fully toward each
#' of its k genres, exactly as aggregate_by_genre_wave() does for waves.
#' @return tibble: pid, day, genre, hours
aggregate_genre <- function(clipped, meta_long) {
  clipped |>
    select(pid, day, platform, title_id, clipped_minutes) |>
    inner_join(
      meta_long |> select(original_name, platform, genre),
      join_by(title_id == original_name, platform),
      relationship = "many-to-many"
    ) |>
    filter(!is.na(genre)) |>
    group_by(pid, day, genre) |>
    summarise(hours = sum(clipped_minutes, na.rm = TRUE) / 60, .groups = "drop") |>
    filter(hours > 0)
}

#' Widen genre hours onto the diary frame, filling unplayed genres with 0.
#' @return tibble: diary_analysis columns + one gh_{genre} column per genre
build_model_frame <- function(diary_analysis, genre_day_long, all_genres) {
  gh_cols <- genre_to_gh_col(all_genres)

  wide <- genre_day_long |>
    mutate(col = genre_to_gh_col(genre)) |>
    select(pid, day, col, hours) |>
    pivot_wider(names_from = col, values_from = hours, values_fill = 0)

  out <- diary_analysis |>
    left_join(wide, join_by(pid, day))

  # Genres absent from the long file entirely would otherwise be missing;
  # responses with no play get 0 rather than NA.
  for (cl in gh_cols) {
    if (!cl %in% names(out)) out[[cl]] <- 0
    out[[cl]] <- replace_na(out[[cl]], 0)
  }

  out |> select(all_of(names(diary_analysis)), all_of(sort(gh_cols)))
}

# =============================================================================
# Marginals Report (Deliverable 2)
# =============================================================================
# NOTE: marginal distributions only. No exposure x outcome crossing anywhere in
# this section, by prespecification-integrity rule.

#' Variance decomposition of a single outcome.
#' Within-person SD is the SD of person-demeaned values over participants with
#' at least 2 non-missing observations. Between-person SD is the SD of person
#' means over all participants with at least 1 non-missing observation.
#' @return one-row tibble
decompose_variance <- function(d, id_col, value_col, label) {
  x <- d |>
    transmute(pid = .data[[id_col]], value = .data[[value_col]]) |>
    filter(!is.na(value))

  person_means <- x |>
    group_by(pid) |>
    summarise(m = mean(value), n_obs = n(), .groups = "drop")

  within_vals <- x |>
    group_by(pid) |>
    filter(n() >= 2) |>
    mutate(dev = value - mean(value)) |>
    ungroup()

  sd_within <- sd(within_vals$dev)
  sd_between <- sd(person_means$m)

  tibble(
    outcome = label,
    n_obs = nrow(x),
    n_pids = nrow(person_means),
    n_pids_ge2 = sum(person_means$n_obs >= 2),
    grand_mean = mean(x$value),
    sd_total = sd(x$value),
    sd_within = sd_within,
    sd_between = sd_between,
    icc = sd_between^2 / (sd_between^2 + sd_within^2)
  )
}

#' Phi coefficient for a 2x2 contingency table (matrix with rows/cols ordered
#' consistently). Returns NA if any margin is zero.
phi_coefficient <- function(tab) {
  # as.numeric guards against integer overflow in the margin products
  n11 <- as.numeric(tab[1, 1]); n12 <- as.numeric(tab[1, 2])
  n21 <- as.numeric(tab[2, 1]); n22 <- as.numeric(tab[2, 2])
  denom <- sqrt((n11 + n12) * (n21 + n22) * (n11 + n21) * (n12 + n22))
  if (!is.finite(denom) || denom == 0) return(NA_real_)
  (n11 * n22 - n12 * n21) / denom
}

#' Build the full marginals report as a character vector of lines.
build_marginals_report <- function(diary_analysis, genre_day_long, clipped,
                                   wemwbs_df, all_genres, n_att_failed) {
  L <- character(0)
  add <- function(...) L <<- c(L, sprintf(...))
  blank <- function() L <<- c(L, "")

  add("=============================================================================")
  add("DAILY DIARY MARGINALS REPORT")
  add("Generated: %s", format(Sys.time(), tz = "UTC", usetz = TRUE))
  add("Source: R/04_daily_aggregate.R")
  add("Marginal distributions only. No exposure x outcome crossing.")
  add("=============================================================================")
  blank()
  add("Attention check (bpnsfs_failed_att_check == TRUE) rows removed: %d", n_att_failed)
  blank()

  # --- (a) Outcome variance decomposition ------------------------------------
  add("-----------------------------------------------------------------------------")
  add("(a) OUTCOME VARIANCE DECOMPOSITION")
  add("-----------------------------------------------------------------------------")
  add("within-person SD = SD of person-demeaned values (pids with >=2 obs)")
  add("between-person SD = SD of person means (pids with >=1 obs)")
  add("ICC = sd_between^2 / (sd_between^2 + sd_within^2)")
  blank()

  vd <- bind_rows(
    decompose_variance(diary_analysis, "pid", "life_sat", "life_sat (daily, 0-100)"),
    decompose_variance(diary_analysis, "pid", "affective_valence",
                       "affective_valence (daily, 0-100)"),
    decompose_variance(wemwbs_df, "pid", "wemwbs", "SWEMWBS (biweekly, 1-5)")
  )

  add("%-32s %8s %7s %9s %10s %10s %10s %10s %8s",
      "outcome", "n_obs", "n_pids", "n_pid>=2", "grand_mean",
      "sd_total", "sd_within", "sd_between", "ICC")
  for (i in seq_len(nrow(vd))) {
    add("%-32s %8d %7d %9d %10s %10s %10s %10s %8s",
        vd$outcome[i], vd$n_obs[i], vd$n_pids[i], vd$n_pids_ge2[i],
        fmt(vd$grand_mean[i]), fmt(vd$sd_total[i]), fmt(vd$sd_within[i]),
        fmt(vd$sd_between[i]), fmt(vd$icc[i]))
  }
  blank()

  # --- (b) Exposure marginals ------------------------------------------------
  add("-----------------------------------------------------------------------------")
  add("(b) EXPOSURE MARGINALS")
  add("-----------------------------------------------------------------------------")
  n_resp <- nrow(diary_analysis)
  wh <- diary_analysis$window_hours
  add("Analysis window = same day (4 a.m. local of the waking day to completion).")
  add("Window length (h): min %s | median %s | p90 %s | max %s",
      fmt(min(wh), 2), fmt(median(wh), 2), fmt(quantile(wh, 0.9), 2),
      fmt(max(wh), 2))
  off_tab <- diary_analysis |> distinct(pid, utc_offset) |> count(utc_offset)
  add("Inferred UTC offsets (participants): %s",
      paste(sprintf("UTC%+d: %d", off_tab$utc_offset, off_tab$n), collapse = " | "))
  blank()
  n_zero <- sum(diary_analysis$total_hours_today == 0)
  add("Diary responses: %d", n_resp)
  add("Responses with total_hours_today == 0: %d (%s%%)",
      n_zero, fmt(100 * n_zero / n_resp, 2))
  blank()
  th <- diary_analysis$total_hours_today
  add("total_hours_today over ALL responses:")
  add("  mean %s | median %s | p90 %s | p99 %s | max %s",
      fmt(mean(th)), fmt(median(th)), fmt(quantile(th, 0.90)),
      fmt(quantile(th, 0.99)), fmt(max(th)))
  thp <- th[th > 0]
  add("total_hours_today over responses with play > 0 (n = %d):", length(thp))
  add("  mean %s | median %s | p90 %s | p99 %s | max %s",
      fmt(mean(thp)), fmt(median(thp)), fmt(quantile(thp, 0.90)),
      fmt(quantile(thp, 0.99)), fmt(max(thp)))
  blank()

  add("Per-genre person-day marginals (denominator = %d diary responses),", n_resp)
  add("ranked by total hours across all responses:")
  blank()
  genre_marg <- genre_day_long |>
    group_by(genre) |>
    summarise(
      n_pos = n(),
      total_hours = sum(hours),
      median_pos = median(hours),
      p90_pos = quantile(hours, 0.90),
      .groups = "drop"
    ) |>
    right_join(tibble(genre = all_genres), join_by(genre)) |>
    mutate(
      n_pos = replace_na(n_pos, 0L),
      total_hours = replace_na(total_hours, 0),
      pct_pos = 100 * n_pos / n_resp
    ) |>
    arrange(desc(total_hours))

  add("%-30s %8s %8s %12s %12s %12s",
      "genre", "n_pos", "pct_pos", "total_hours", "median_pos", "p90_pos")
  for (i in seq_len(nrow(genre_marg))) {
    add("%-30s %8d %8s %12s %12s %12s",
        genre_marg$genre[i], genre_marg$n_pos[i], fmt(genre_marg$pct_pos[i], 2),
        fmt(genre_marg$total_hours[i], 1),
        ifelse(genre_marg$n_pos[i] > 0, fmt(genre_marg$median_pos[i]), "NA"),
        ifelse(genre_marg$n_pos[i] > 0, fmt(genre_marg$p90_pos[i]), "NA"))
  }
  blank()

  # --- (c) Compliance --------------------------------------------------------
  add("-----------------------------------------------------------------------------")
  add("(c) COMPLIANCE")
  add("-----------------------------------------------------------------------------")
  per_day <- diary_analysis |> count(day, name = "n_responses") |> arrange(day)
  add("Responses per diary day index (1-%d):", N_DIARY_DAYS)
  add("%6s %12s", "day", "n_responses")
  for (i in seq_len(nrow(per_day))) {
    add("%6d %12d", per_day$day[i], per_day$n_responses[i])
  }
  blank()
  per_pid <- diary_analysis |> count(pid, name = "n_days")
  q <- quantile(per_pid$n_days, c(0, 0.25, 0.5, 0.75, 1))
  add("Days per participant (n = %d participants):", nrow(per_pid))
  add("  min %s | Q1 %s | median %s | Q3 %s | max %s | mean %s",
      fmt(q[1], 0), fmt(q[2], 1), fmt(q[3], 1), fmt(q[4], 1), fmt(q[5], 0),
      fmt(mean(per_pid$n_days), 2))
  add("  participants with >= 15 days: %d (%s%%)",
      sum(per_pid$n_days >= 15),
      fmt(100 * sum(per_pid$n_days >= 15) / nrow(per_pid), 2))
  blank()

  # --- (d) played24hr vs telemetry -------------------------------------------
  add("-----------------------------------------------------------------------------")
  add("(d) SELF-REPORTED played24hr vs TELEMETRY")
  add("-----------------------------------------------------------------------------")
  add("Positive-control input. No wellbeing outcome involved.")
  blank()

  crosstab_block <- function(threshold_min, label) {
    d <- diary_analysis |>
      filter(played24hr %in% c("Yes", "No")) |>
      mutate(
        self = factor(played24hr, levels = c("Yes", "No")),
        tele = factor(
          if_else(total_hours_24h * 60 >= threshold_min, "Yes", "No"),
          levels = c("Yes", "No")
        )
      )
    tab <- table(self = d$self, tele = d$tele)
    agree <- (tab[1, 1] + tab[2, 2]) / sum(tab)
    ph <- phi_coefficient(tab)

    add("%s (n = %d responses with played24hr in {Yes, No}):", label, sum(tab))
    add("%12s %10s %10s %10s", "", "tele=Yes", "tele=No", "row total")
    add("%12s %10d %10d %10d", "self=Yes", tab[1, 1], tab[1, 2], sum(tab[1, ]))
    add("%12s %10d %10d %10d", "self=No", tab[2, 1], tab[2, 2], sum(tab[2, ]))
    add("%12s %10d %10d %10d", "col total", sum(tab[, 1]), sum(tab[, 2]), sum(tab))
    add("  percent agreement: %s%%", fmt(100 * agree, 2))
    add("  phi coefficient:   %s", fmt(ph, 4))
    blank()
  }

  n_na_self <- sum(is.na(diary_analysis$played24hr))
  add("Responses with played24hr NA (excluded from both crosstabs): %d", n_na_self)
  blank()
  crosstab_block(0 + EPS_MINUTES, "Telemetry threshold: any play (> 0 min)")
  crosstab_block(5, "Telemetry threshold: >= 5 minutes")

  # --- (e) Sanity spot-check -------------------------------------------------
  add("-----------------------------------------------------------------------------")
  add("(e) SANITY SPOT-CHECK: CLIPPING ARITHMETIC")
  add("-----------------------------------------------------------------------------")
  add("Two diary responses with play. For each, every session overlapping the")
  add("window is listed with its raw and clipped minutes so the arithmetic can")
  add("be checked by eye. Spot-check 1 exercises the Nintendo/Xbox interval rule")
  add("(clip_min = intersected wall-clock minutes); spot-check 2 exercises the")
  add("Steam rule (clip_min = raw_min * intersected_share_of_span). In both, at")
  add("least one session is truncated by the window boundary.")
  blank()

  # Deterministic picks: the first (pid, day) meeting each criterion in sort
  # order. Both criteria require a boundary-truncated session so the clipping
  # arithmetic is actually exercised rather than passing through unchanged.
  pick_first <- function(platforms, n_min, n_max) {
    cand <- clipped |>
      group_by(pid, day) |>
      filter(
        all(platform %in% platforms),
        any(session_start < win_start | session_end > win_end),
        n() >= n_min, n() <= n_max
      ) |>
      ungroup() |>
      distinct(pid, day) |>
      arrange(pid, day)
    cand |> slice(1)
  }

  picks <- bind_rows(
    pick_first(c("Nintendo", "Xbox"), 2, 6),
    pick_first("Steam", 2, 6)
  ) |> distinct()

  for (i in seq_len(nrow(picks))) {
    p <- picks$pid[i]
    dd <- picks$day[i]
    rows <- clipped |>
      filter(pid == p, day == dd) |>
      arrange(session_start)
    tot <- diary_analysis |> filter(pid == p, day == dd)

    add("Spot-check %d: pid = %s, day = %d", i, p, dd)
    add("  window: [%s, %s]  (UTC)",
        format(rows$win_start[1], "%Y-%m-%d %H:%M:%S"),
        format(rows$win_end[1], "%Y-%m-%d %H:%M:%S"))
    add("%-10s %-28s %-21s %-21s %9s %9s %9s",
        "platform", "title_id", "session_start", "session_end",
        "raw_min", "span_min", "clip_min")
    for (j in seq_len(nrow(rows))) {
      add("%-10s %-28s %-21s %-21s %9s %9s %9s",
          rows$platform[j],
          substr(rows$title_id[j], 1, 28),
          format(rows$session_start[j], "%Y-%m-%d %H:%M:%S"),
          format(rows$session_end[j], "%Y-%m-%d %H:%M:%S"),
          fmt(rows$minutes[j], 2), fmt(rows$span_minutes[j], 2),
          fmt(rows$clipped_minutes[j], 2))
    }
    add("  sum(clip_min) = %s min = %s h ; diary_analysis total_hours_today = %s h",
        fmt(sum(rows$clipped_minutes), 2),
        fmt(sum(rows$clipped_minutes) / 60, 4),
        fmt(tot$total_hours_today[1], 4))
    gg <- genre_day_long |> filter(pid == p, day == dd) |> arrange(desc(hours))
    if (nrow(gg) > 0) {
      add("  genre hours (full attribution, not mutually exclusive):")
      for (j in seq_len(nrow(gg))) {
        add("    %-30s %s", gg$genre[j], fmt(gg$hours[j], 4))
      }
    } else {
      add("  genre hours: none (no title matched the genre lookup)")
    }
    blank()
  }

  add("=============================================================================")
  add("END OF REPORT")
  add("=============================================================================")

  L
}

# =============================================================================
# Main Pipeline
# =============================================================================

daily_aggregate <- function() {
  message("=== Daily Diary Aggregation (same-day exposure windows) ===")

  # --- Diary survey ---
  message("Loading daily diary survey...")
  ds <- load_daily_survey()
  diary <- ds$diary
  message(sprintf(
    "  %d diary responses, %d participants, day index range %d-%d",
    nrow(diary), n_distinct(diary$pid), min(diary$day), max(diary$day)
  ))
  message(sprintf(
    "  completion timestamps: %s to %s (tz: %s)",
    format(min(diary$completion)), format(max(diary$completion)),
    attr(diary$completion, "tzone")
  ))
  message(sprintf(
    "  missing outcomes retained: life_sat %d NA, affective_valence %d NA\n",
    sum(is.na(diary$life_sat)), sum(is.na(diary$affective_valence))
  ))

  # --- Local-time inference and windows ---
  message("Inferring UTC offsets from the 2 p.m.-3 a.m. availability window...")
  offsets <- infer_utc_offsets(diary)
  off_tab <- offsets |> count(utc_offset) |> arrange(utc_offset)
  for (i in seq_len(nrow(off_tab))) {
    message(sprintf("  UTC%+d: %5d participants",
                    off_tab$utc_offset[i], off_tab$n[i]))
  }
  message(sprintf(
    "  tz_unreliable (>20%% violating responses): %d participants; any violation: %d\n",
    sum(offsets$tz_unreliable), sum(offsets$n_viol > 0)
  ))

  diary <- add_windows(diary, offsets |> select(pid, utc_offset, tz_unreliable))
  stopifnot(
    "window_hours out of range" =
      all(diary$window_hours > 0 & diary$window_hours <= 24 + 1e-9),
    "windows have NA" = !any(is.na(diary$win_start))
  )
  message(sprintf(
    "  today-window length (hours): min %.2f | median %.2f | p90 %.2f | max %.2f\n",
    min(diary$window_hours), median(diary$window_hours),
    quantile(diary$window_hours, 0.9), max(diary$window_hours)
  ))

  # --- Telemetry ---
  message("Loading telemetry for diary participants...")
  sessions <- load_daily_sessions(unique(diary$pid))
  plat_counts <- sessions |> count(platform)
  for (i in seq_len(nrow(plat_counts))) {
    message(sprintf("  %-9s %8d sessions", plat_counts$platform[i], plat_counts$n[i]))
  }
  message(sprintf(
    "  %d sessions total, %d participants with any telemetry\n",
    nrow(sessions), n_distinct(sessions$pid)
  ))

  # --- Clip to windows (analysis window: today; control window: 24 h) ---
  message("Clipping sessions to same-day diary windows (interval join)...")
  clipped <- clip_sessions_to_windows(sessions, diary)
  message(sprintf(
    "  %d session x response overlaps with clipped_minutes > 0",
    nrow(clipped)
  ))
  message(sprintf(
    "  %d diary responses have at least one overlapping session\n",
    nrow(distinct(clipped, pid, day))
  ))

  message("Clipping sessions to 24-hour control windows (played24hr check)...")
  diary24 <- diary |>
    select(pid, day, win_start = win24_start, win_end = win24_end)
  clipped24 <- clip_sessions_to_windows(sessions, diary24)
  message(sprintf(
    "  %d session x response overlaps in the control windows\n", nrow(clipped24)
  ))

  stopifnot(
    "negative overlap minutes" = all(clipped$overlap_minutes >= -EPS_MINUTES),
    "negative clipped minutes" = all(clipped$clipped_minutes >= -EPS_MINUTES),
    "clipped exceeds window length" =
      all(clipped$clipped_minutes <= WINDOW_HOURS * 60 + EPS_MINUTES)
  )

  # --- Totals ---
  message("Aggregating total playtime per response...")
  totals_today <- aggregate_total(clipped, "total_hours_today")
  totals_24h   <- aggregate_total(clipped24, "total_hours_24h")

  diary_analysis <- diary |>
    select(pid, day, completion, utc_offset, tz_unreliable, window_hours,
           life_sat, affective_valence, played24hr) |>
    left_join(totals_today, join_by(pid, day)) |>
    left_join(totals_24h, join_by(pid, day)) |>
    mutate(
      total_hours_today = replace_na(total_hours_today, 0),
      total_hours_24h = replace_na(total_hours_24h, 0)
    ) |>
    arrange(pid, day)

  # The today window is a subset of the 24-hour window ending at the same
  # instant only when the waking day began within the last 24 h, which is
  # always true (window_hours <= 24); today playtime can therefore never
  # exceed control playtime.
  stopifnot(
    "today exposure exceeds 24h exposure" =
      all(diary_analysis$total_hours_today <=
            diary_analysis$total_hours_24h + EPS_MINUTES / 60)
  )
  message(sprintf(
    "  max total_hours_today: %.4f h; max total_hours_24h: %.4f h (over %d responses)\n",
    max(diary_analysis$total_hours_today),
    max(diary_analysis$total_hours_24h), nrow(diary_analysis)
  ))

  # Per-platform totals cannot exceed the window; the pooled cross-platform
  # total can, because concurrent play on two platforms is possible.
  plat_totals <- clipped |>
    group_by(pid, day, platform) |>
    summarise(h = sum(clipped_minutes) / 60, .groups = "drop")
  plat_max <- plat_totals |>
    group_by(platform) |>
    summarise(max_h = max(h), .groups = "drop")
  for (i in seq_len(nrow(plat_max))) {
    message(sprintf(
      "  max within-platform hours in a window: %-9s %.4f h",
      plat_max$platform[i], plat_max$max_h[i]
    ))
  }
  n_over24 <- sum(diary_analysis$total_hours_24h > WINDOW_HOURS + EPS_MINUTES)
  message(sprintf("  responses with pooled 24h total > %d h: %d\n", WINDOW_HOURS, n_over24))

  stopifnot(
    "within-platform hours exceed window" =
      all(plat_totals$h <= WINDOW_HOURS + 1e-6)
  )

  # --- Genres ---
  message("Loading genre lookup and aggregating per-genre hours...")
  meta_long <- load_meta_long()
  genre_day_long <- aggregate_genre(clipped, meta_long)

  reference_genres <- read_csv(
    here("data/processed/genre_wave_long.csv"),
    show_col_types = FALSE
  ) |>
    pull(genre) |>
    unique() |>
    sort()

  observed_genres <- sort(unique(genre_day_long$genre))
  message(sprintf(
    "  %d distinct genres, %d (pid, day, genre) rows",
    length(observed_genres), nrow(genre_day_long)
  ))
  message(sprintf("  genres: %s\n", paste(observed_genres, collapse = ", ")))

  stopifnot(
    "daily genres do not match genre_wave_long genres" =
      setequal(observed_genres, reference_genres),
    "expected 14 genres" = length(reference_genres) == 14L,
    "genre hours exceed the window bound" =
      all(genre_day_long$hours <= WINDOW_HOURS + 1e-6),
    "negative genre hours" = all(genre_day_long$hours >= 0)
  )

  # --- Wide model frame ---
  message("Building wide model frame...")
  model_frame <- build_model_frame(diary_analysis, genre_day_long, reference_genres)
  message(sprintf(
    "  %d rows x %d columns (%d gh_ genre columns)\n",
    nrow(model_frame), ncol(model_frame), length(reference_genres)
  ))

  stopifnot(
    "model frame row count changed" = nrow(model_frame) == nrow(diary_analysis),
    "model frame has NA genre hours" =
      !any(is.na(model_frame[, grep("^gh_", names(model_frame))]))
  )

  # --- Telemetry coverage flags ---
  # Appended last in both frames so the exposure and outcome columns keep their
  # existing positions and values.
  message("Flagging telemetry coverage...")
  span <- compute_telemetry_span(sessions)
  coverage <- build_coverage_flags(diary, span, "covered")
  coverage24 <- build_coverage_flags(diary24, span, "covered24") |>
    select(pid, day, covered24)

  diary_analysis <- diary_analysis |>
    left_join(coverage, join_by(pid, day)) |>
    left_join(coverage24, join_by(pid, day))
  model_frame <- model_frame |>
    left_join(coverage, join_by(pid, day)) |>
    left_join(coverage24, join_by(pid, day))

  n_cov <- sum(coverage$covered)
  message(sprintf(
    "  has_telemetry: %d responses (%d participants)",
    sum(coverage$has_telemetry),
    n_distinct(coverage$pid[coverage$has_telemetry])
  ))
  message(sprintf(
    "  covered:       %d responses (%d participants)\n",
    n_cov, n_distinct(coverage$pid[coverage$covered])
  ))

  stopifnot(
    "coverage flags have NA" =
      !any(is.na(diary_analysis$has_telemetry)) &&
      !any(is.na(diary_analysis$covered)),
    "covered without telemetry" =
      all(!diary_analysis$covered | diary_analysis$has_telemetry),
    "coverage join changed row count" =
      nrow(diary_analysis) == nrow(model_frame),
    "every response with today play must be covered" =
      all(diary_analysis$total_hours_today == 0 | diary_analysis$covered),
    "every response with 24h play must be covered24" =
      all(diary_analysis$total_hours_24h == 0 | diary_analysis$covered24)
  )

  # --- Marginals report ---
  message("Building marginals report...")
  wemwbs_df <- load_biweekly_wemwbs()
  report <- build_marginals_report(
    diary_analysis, genre_day_long, clipped, wemwbs_df,
    reference_genres, ds$n_att_failed
  )

  list(
    diary_analysis = diary_analysis,
    genre_day_long = genre_day_long,
    model_frame = model_frame,
    report = report
  )
}

# =============================================================================
# Run if executed directly
# =============================================================================

if (sys.nframe() == 0) {
  result <- daily_aggregate()

  dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

  write_csv(result$diary_analysis, file.path(OUT_DIR, "diary_analysis.csv"))
  message(sprintf(
    "Saved: data/processed/daily/diary_analysis.csv (%d rows)",
    nrow(result$diary_analysis)
  ))

  write_csv(result$genre_day_long, file.path(OUT_DIR, "genre_day_long.csv"))
  message(sprintf(
    "Saved: data/processed/daily/genre_day_long.csv (%d rows)",
    nrow(result$genre_day_long)
  ))

  write_csv(result$model_frame, file.path(OUT_DIR, "daily_model_frame.csv"))
  message(sprintf(
    "Saved: data/processed/daily/daily_model_frame.csv (%d rows)",
    nrow(result$model_frame)
  ))

  writeLines(result$report, file.path(OUT_DIR, "marginals_report.txt"))
  message(sprintf(
    "Saved: data/processed/daily/marginals_report.txt (%d lines)\n",
    length(result$report)
  ))

  cat(paste(result$report, collapse = "\n"), "\n")
}
