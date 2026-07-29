# =============================================================================
# Helper functions for demographics table formatting
# Adapted from demographics paper (Ballou) R/helpers.R
# =============================================================================

library(glue)
library(tidyverse)

#' Format mean and standard deviation
#' @param x Numeric vector
#' @return Character string "M (SD)" or em-dash if empty
format_mean_sd <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return("\u2014")
  glue("{round(mean(x), 1)} ({round(sd(x), 1)})")
}

#' Format count and percentage
#' @param n Count
#' @param total Denominator for percentage
#' @return Character string "n (pct%)" with LaTeX-escaped percent sign
format_n_pct <- function(n, total) {
  if (n == 0) return("0 (0.0%)")
  glue("{n} ({round(100 * n / total, 1)}%)")
}

#' Create a table row with Total/US/UK columns
#' @param char Characteristic name
#' @param val_total Value for Total column
#' @param val_us Value for US column
#' @param val_uk Value for UK column
#' @return Single-row tibble
make_table_row <- function(char, val_total, val_us, val_uk) {
  tibble(
    Characteristic = char,
    Total = val_total,
    US = val_us,
    UK = val_uk
  )
}

#' Create categorical rows for demographics table
#' @param data Data frame with demographic data
#' @param var Variable name to tabulate
#' @param label Header label for the variable
#' @param levels Character vector of category levels
#' @param n_total Total sample size
#' @param n_us US sample size
#' @param n_uk UK sample size
#' @return Tibble with header and category rows
make_demo_rows <- function(data, var, label, levels, n_total, n_us, n_uk) {
  header <- make_table_row(glue("**{label}**"), "", "", "")

  rows <- map(levels, \(lvl) {
    n_tot    <- sum(data[[var]] == lvl, na.rm = TRUE)
    n_us_val <- sum(data[[var]] == lvl & data$country == "US", na.rm = TRUE)
    n_uk_val <- sum(data[[var]] == lvl & data$country == "UK", na.rm = TRUE)

    make_table_row(
      glue("    {lvl}"),
      format_n_pct(n_tot,    n_total),
      format_n_pct(n_us_val, n_us),
      format_n_pct(n_uk_val, n_uk)
    )
  }) |> list_rbind()

  bind_rows(header, rows)
}

#' Format genre variable names for display
#' Converts e.g. "time_role_playing_rpg_within" to "Role Playing Game (RPG)"
#' @param x Character vector of genre variable names
#' @return Character vector of display-ready genre labels
format_genre_display <- function(x) {
  x |>
    str_remove("^time_") |>
    str_remove("_within$") |>
    str_remove("_between$") |>
    str_replace_all("_", " ") |>
    str_to_title() |>
    str_replace("^Role Playing Rpg$", "Role Playing Game (RPG)")
}
