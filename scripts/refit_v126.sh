#!/usr/bin/env bash
# =============================================================================
# Overnight refit for Open Play v1.2.6 (qualified-only analytic sample)
# =============================================================================
# Refits every cached model on the v1.2.6 data, precomputes LOO, and renders
# the Word copy once at the end. Resumable: every stage is skipped when its
# outputs exist, so after an interruption (guard kill, reboot, Ctrl-C) simply
# launch the same command again.
#
# Launch from anywhere (the script cds to the repo root):
#   nohup bash scripts/refit_v126.sh > ~/open-play-render-logs/refit_v126_driver.log 2>&1 &
#   tail -f ~/open-play-render-logs/refit_v126_progress.log
# The script re-executes itself under `caffeinate -dimsu` so the Mac does not
# sleep. Total ~9-10 h. It can still be split, e.g. night 1 with
#   REFIT_STOP_AFTER=daily_mm nohup bash scripts/refit_v126.sh > ... &
# and night 2 without it; night 2 is now just render_docx (~20 min): the
# prior-sensitivity stage was dropped on 2026-10-13 when every model moved to
# the brms default priors (R/03_prior_sensitivity.R is superseded).
#
# Options (environment variables):
#   REFIT_DRYRUN=1          print the timetable and the stage plan; change nothing
#   REFIT_STOP_AFTER=<stage> stop cleanly after that stage
#   REFIT_GUARD_INTERVAL=30 memory sampling interval, seconds
#   REFIT_GUARD_MIN_FREE=8  kill the stage after 2 consecutive samples below this
#                           free-memory percentage (memory_pressure) ...
#   REFIT_GUARD_HARD_FREE=4 ... or after one sample below this
#
# Stages (dependency order): preflight, archive (once), preprocess (only if
# stale), prep_primary (only if stale: the primary-genre attribution file that
# the Appendix D chunk frequentist-registered reads, rebuilt whenever the main
# processed files are newer), daily_aggregate (only if stale), manifest,
# impute, main_m123,
# loo_h1, loo_h2_fe, loo_h2_hier, demographics, main_m4, loo_h2_mm,
# daily_rest, daily_m2, daily_dyn, daily_mm, render_docx.
#
# Logs (outside the session scratchpad, which a reboot wipes):
#   ~/open-play-render-logs/refit_v126_progress.log   one line per event
#   ~/open-play-render-logs/refit_v126_<stage>.log    full output per stage
#   ~/open-play-render-logs/refit_v126_memory.log     free %, swap, R RSS
#   ~/open-play-render-logs/refit_v126_GUARD_TRIPPED  present after a guard kill
#
# Safety:
#   - Every stage runs in a fresh process; the driver stops at the first
#     failure or guard kill and never continues to the next stage.
#   - The v1.2.1 fits are moved once to models/archive_v121/ and
#     models/daily/archive_v121/ (brms `file =` would otherwise silently
#     reload them). A file already in the archive is never overwritten.
#   - data/ inputs are fingerprinted (md5) on the first run; a resumed run
#     refuses to continue when they changed, so all fits share one data state.
#   - No all-format render: only `quarto render manuscript.qmd --to docx`, from
#     a cold cache (LOO is precomputed, so the cold cache is safe). Render the
#     other formats afterwards one at a time (CLAUDE.md).
# Supersedes scripts/run_refit.sh (wave-7 refit; do not run that script: it
# renders all formats at once).
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

DRYRUN="${REFIT_DRYRUN:-0}"
STOP_AFTER="${REFIT_STOP_AFTER:-}"
GUARD_INTERVAL="${REFIT_GUARD_INTERVAL:-30}"
GUARD_MIN_FREE="${REFIT_GUARD_MIN_FREE:-8}"
GUARD_HARD_FREE="${REFIT_GUARD_HARD_FREE:-4}"

LOG_DIR="${REFIT_LOG_DIR:-$HOME/open-play-render-logs}"
PREFIX="$LOG_DIR/refit_v126"
PROGRESS="${PREFIX}_progress.log"
MEMLOG="${PREFIX}_memory.log"
GUARD_FLAG="${PREFIX}_GUARD_TRIPPED"
FAILURES="${PREFIX}_chunk_failures.txt"
RENDER_DONE="${PREFIX}_render_docx.done"
LOCK="${PREFIX}.lock"
MANIFEST="models/refit_v126_manifest.md5"
ARCHIVE_DONE="models/archive_v121/.done"
mkdir -p "$LOG_DIR"

# Keep the Mac awake for the whole run (not needed for a dry run).
if [ "$DRYRUN" != 1 ] && [ -z "${REFIT_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null; then
  export REFIT_CAFFEINATED=1
  exec caffeinate -dimsu bash "$REPO/scripts/refit_v126.sh" "$@"
fi

# --- helpers -----------------------------------------------------------------
now()      { date '+%Y-%m-%d %H:%M:%S'; }
progress() { echo "$(now) $*" | tee -a "$PROGRESS"; }
die()      { progress "STOP: $*"; exit 1; }

free_pct() {
  memory_pressure 2>/dev/null |
    awk -F': ' '/free percentage/ {gsub(/%/, "", $2); print $2 + 0}'
}
swap_used() { sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}'; }
r_rss_gb() {
  ps -axo rss=,comm= |
    awk '$2 ~ /exec\/R$/ || $2 ~ /Rscript$/ {s += $1} END {printf "%.1f", s / 1048576}'
}

# All descendants of a pid (depth first), then the pid itself.
descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do descendants "$c"; echo "$c"; done
}
kill_tree() {
  local root=$1 pids
  pids="$(descendants "$root") $root"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  # rstan/future PSOCK chain workers can be reparented to launchd and so be
  # missed by pgrep -P. NOTE: this also stops PSOCK workers of any other R
  # session on the machine; acceptable in a memory emergency.
  pkill -TERM -f 'workRSOCK' 2>/dev/null
  sleep 10
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  pkill -KILL -f 'workRSOCK' 2>/dev/null
}

# Memory guard for one stage: samples every GUARD_INTERVAL s while the stage
# runs; kills the stage tree after 2 consecutive samples below GUARD_MIN_FREE %
# (or 1 below GUARD_HARD_FREE %) and writes the GUARD_TRIPPED marker.
guard_loop() {
  local pid=$1 name=$2 low=0 free
  while kill -0 "$pid" 2>/dev/null; do
    free="$(free_pct)"
    echo "$(date +%T) $name free=${free:-NA}% swap_used=$(swap_used) R_rss=$(r_rss_gb)GB" >> "$MEMLOG"
    if [[ "$free" =~ ^[0-9]+$ ]]; then
      if   [ "$free" -lt "$GUARD_HARD_FREE" ]; then low=2
      elif [ "$free" -lt "$GUARD_MIN_FREE" ];  then low=$((low + 1))
      else low=0
      fi
      if [ "$low" -ge 2 ]; then
        echo "$(date +%T) GUARD KILL stage=$name free=${free}%" >> "$MEMLOG"
        echo "$(now) stage=$name free=${free}% swap_used=$(swap_used) R_rss=$(r_rss_gb)GB" > "$GUARD_FLAG"
        kill_tree "$pid"
        return 0
      fi
    fi
    sleep "$GUARD_INTERVAL"
  done
}

# present FILE: exists. In a dry run before the archive step, the v1.2.1 fits
# under models/ count as absent, so the plan shows what a real run will do.
SIMULATE_ARCHIVE=0
present() {
  [ -e "$1" ] || return 1
  if [ "$SIMULATE_ARCHIVE" = 1 ]; then
    case "$1" in models/*.rds) return 1 ;; esac
  fi
  return 0
}

# fresh OUT... -- IN...: every OUT exists and is newer than every IN.
fresh() {
  local outs=() ins=() seen=0 a o i
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; continue; fi
    if [ "$seen" = 0 ]; then outs+=("$a"); else ins+=("$a"); fi
  done
  for o in "${outs[@]}"; do
    present "$o" || return 1
    for i in "${ins[@]}"; do [ "$o" -nt "$i" ] || return 1; done
  done
  return 0
}
all_exist() { local f; for f in "$@"; do present "$f" || return 1; done; return 0; }

CLEAN_INPUTS=(data/clean/*.csv.gz data/reference/baseline_days.csv)
PRE_OUT=(data/processed/genre_wave_long.csv data/processed/total_playtime.csv
         data/processed/game_metadata_long.csv)
DAILY_OUT=(data/processed/daily/diary_analysis.csv data/processed/daily/genre_day_long.csv
           data/processed/daily/daily_model_frame.csv)
DAILY_IN=(data/clean/survey_daily.csv.gz data/clean/survey_intake.csv.gz
          data/clean/survey_biweekly.csv.gz "${PRE_OUT[@]}")

# --- stage table (name | est. minutes | est. peak RAM | skip test | command) --
# Estimates from the Jul 23-31 runs at N = 1,838 (U2 inventory); the v1.2.6
# sample (1,608 participants, 6,293 waves) should be the same or faster.
# M3 and M3-D moved to the non-centred multi-membership form on 2026-10-14
# (new fit files h2_hier_model_v4 and daily/m3_daily_ls_v4; the centred _v3
# fits stay in models/ unused), so main_m123, loo_h2_hier, daily_rest and
# render_docx rerun while every other stage is skipped. loo_h2_hier also
# requires the v4 fit to exist: `fresh` alone would count the old LOO file as
# current while the fit is still missing ([ a -nt b ] is true when b is absent).
STAGES=(
  "preprocess|3|<2 GB|fresh ${PRE_OUT[*]} -- ${CLEAN_INPUTS[*]}|Rscript R/01_preprocess.R"
  "prep_primary|1|<2 GB|fresh data/processed/genre_wave_long_primary.csv -- data/processed/genre_wave_long.csv data/processed/total_playtime.csv|Rscript R/prep_primary_genre.R"
  "daily_aggregate|1|<2 GB|fresh ${DAILY_OUT[*]} -- ${DAILY_IN[*]}|Rscript R/04_daily_aggregate.R"
  "impute|15|~2 GB|all_exist data/processed/imputation/imp_wemwbs.rds data/processed/imputation/imputed_long.rds|Rscript R/02_impute_wemwbs.R"
  "main_m123|20|2-3 GB|all_exist models/h1_rewb_model.rds models/h2_genre_model.rds models/h2_hier_model_v4.rds|env REFIT_CHUNKS=range REFIT_FAILURES_FILE=$FAILURES Rscript R/fit_main_models.R h2-hier-fit"
  "loo_h1|5|2-3 GB|fresh models/loo_h1.rds -- models/h1_rewb_model.rds|Rscript R/05_loo.R h1"
  "loo_h2_fe|5|2-3 GB|fresh models/loo_h2_fe.rds -- models/h2_genre_model.rds|Rscript R/05_loo.R h2_fe"
  "loo_h2_hier|8|4-5 GB|all_exist models/h2_hier_model_v4.rds && fresh models/loo_h2_hier.rds -- models/h2_hier_model_v4.rds|Rscript R/05_loo.R h2_hier"
  "demographics|10|2-3 GB|all_exist models/h1_demographics.rds models/h2_demographics.rds|Rscript R/fit_sensitivity_models.R"
  "main_m4|155|4-6 GB|all_exist models/h2_mm_model_full.rds|env REFIT_CHUNKS=minimal REFIT_FAILURES_FILE=$FAILURES Rscript R/fit_main_models.R h2-mm-fit"
  "loo_h2_mm|10|4-5 GB|fresh models/loo_h2_mm.rds -- models/h2_mm_model_full.rds|Rscript R/05_loo.R h2_mm"
  "daily_rest|50|2-3 GB|all_exist models/daily/m1_daily_ls.rds models/daily/m1_daily_ls_full.rds models/daily/m1_daily_ls_xfl.rds models/daily/m3_daily_ls_v4.rds|Rscript R/fit_daily_models.R rest"
  "daily_m2|50|2-3 GB|all_exist models/daily/m2_daily_ls.rds|Rscript R/fit_daily_models.R m2"
  "daily_dyn|17|2-3 GB|all_exist models/daily/m1_daily_ls_ar.rds models/daily/m1_daily_ls_wh.rds|Rscript R/fit_daily_models.R dyn"
  "daily_mm|210|3-5 GB|all_exist models/daily/m4_daily_mm_ls.rds|Rscript R/fit_daily_models.R mm"
  "render_docx|20|~6 GB|fresh $RENDER_DONE -- models/h2_mm_model_full.rds models/daily/m4_daily_mm_ls.rds models/h2_hier_model_v4.rds models/daily/m3_daily_ls_v4.rds|ls models/loo_h1.rds models/loo_h2_fe.rds models/loo_h2_mm.rds models/loo_h2_hier.rds >/dev/null && rm -rf manuscript_cache && quarto render manuscript.qmd --to docx && touch $RENDER_DONE"
)
field() { echo "$1" | cut -d'|' -f"$2"; }

# --- run one stage under the memory guard ------------------------------------
STAGE_RC=0
run_stage() {
  local name=$1 skip=$2 cmd=$3 log="${PREFIX}_$1.log" t0 pid gpid rc
  STAGE_RC=0
  if eval "$skip"; then
    progress "SKIP  $name (outputs present and current)"
    return 0
  fi
  t0=$(date +%s)
  progress "START $name  [free $(free_pct)% | swap $(swap_used)]  $cmd"
  { echo "=== $(now) START $name"; echo "cmd: $cmd"; echo "git: $(git rev-parse --short HEAD 2>/dev/null) (+ uncommitted changes)"; } >> "$log"
  bash -c "$cmd" >> "$log" 2>&1 &
  pid=$!
  guard_loop "$pid" "$name" &
  gpid=$!
  wait "$pid"; rc=$?
  if [ -e "$GUARD_FLAG" ]; then
    # The guard is killing this stage: let kill_tree finish its TERM -> 10 s ->
    # KILL escalation (killing the guard here would skip the KILL step).
    wait "$gpid" 2>/dev/null
  else
    kill "$gpid" 2>/dev/null; wait "$gpid" 2>/dev/null
  fi
  echo "=== $(now) END $name rc=$rc" >> "$log"
  STAGE_RC=$rc
  local mins=$(( ($(date +%s) - t0 + 30) / 60 ))
  if [ -e "$GUARD_FLAG" ]; then
    progress "ABORT $name after ${mins} min: memory guard tripped ($(cat "$GUARD_FLAG")). Close other apps and re-run; finished stages are kept."
    exit 3
  fi
  if [ "$rc" -ne 0 ]; then
    progress "FAIL  $name rc=$rc after ${mins} min; last lines of $log:"
    tail -n 25 "$log" | sed 's/^/    | /' | tee -a "$PROGRESS"
    return "$rc"
  fi
  if ! eval "$skip"; then
    progress "FAIL  $name exited 0 after ${mins} min but its outputs are missing or stale ($skip)"
    STAGE_RC=1
    return 1
  fi
  progress "END   $name rc=0 (${mins} min)"
  return 0
}

maybe_stop_after() {
  if [ -n "$STOP_AFTER" ] && [ "$STOP_AFTER" = "$1" ]; then
    progress "STOP after $1 as requested (REFIT_STOP_AFTER). Re-run without it to continue."
    exit 0
  fi
}

# --- archive (once) ----------------------------------------------------------
# archive_one SRC DESTDIR: mv -n; if the archive already holds a file of that
# name, delete SRC only when it is byte-identical, otherwise stop.
archive_one() {
  local src=$1 dest=$2 base
  base=$(basename "$src")
  [ -e "$src" ] || return 0
  mkdir -p "$dest"
  if [ -e "$dest/$base" ]; then
    if cmp -s "$src" "$dest/$base"; then
      rm -f "$src"; progress "  $src: identical copy already in $dest; removed duplicate"
    else
      die "$src and $dest/$base both exist and differ; resolve by hand (which one is v1.2.1?)"
    fi
  else
    mv -n "$src" "$dest/" && progress "  archived $src -> $dest/"
    [ -e "$src" ] && die "could not move $src"
  fi
  return 0
}

archive_v121() {
  if [ -e "$ARCHIVE_DONE" ]; then
    progress "SKIP  archive (done $(cat "$ARCHIVE_DONE"))"
    return 0
  fi
  if [ "$DRYRUN" = 1 ]; then
    progress "WOULD archive: $(ls models/*.rds models/daily/*.rds 2>/dev/null | wc -l | tr -d ' ') rds files from models/ and models/daily/, plus any v1.2.1 imputation / prior-sensitivity summary left in data/processed/"
    return 0
  fi
  progress "START archive of the v1.2.1 fits"
  local f
  # Every top-level fit in models/ and models/daily/ predates v1.2.6 (including
  # unreferenced ones such as comparison_*.rds and any loo_*.rds).
  for f in models/*.rds;       do archive_one "$f" models/archive_v121; done
  for f in models/daily/*.rds; do archive_one "$f" models/daily/archive_v121; done
  # Derived v1.2.1 outputs (I1 already moved them to data/processed_v121/;
  # these lines only act if copies reappeared).
  archive_one data/processed/prior_sensitivity_summary.rds data/processed_v121
  for f in data/processed/imputation/*; do archive_one "$f" data/processed_v121/imputation; done
  # Daily aggregates: keep them when they were regenerated from the v1.2.6
  # files (newer than data/clean and the processed inputs), else move them
  # aside; the daily_aggregate stage then rebuilds them.
  if ! ls data/processed/daily/* >/dev/null 2>&1; then
    progress "  data/processed/daily/ is empty; the daily_aggregate stage builds it"
  elif ! fresh "${DAILY_OUT[@]}" -- "${DAILY_IN[@]}"; then
    local dd=data/processed_v121/daily
    if ls "$dd"/* >/dev/null 2>&1; then dd="data/processed_v121/daily_superseded_$(date +%Y%m%d_%H%M)"; fi
    for f in data/processed/daily/*; do archive_one "$f" "$dd"; done
  else
    progress "  data/processed/daily/ is current (regenerated from v1.2.6); kept"
  fi
  mkdir -p models/archive_v121
  now > "$ARCHIVE_DONE"
  progress "END   archive"
}

# --- data manifest -----------------------------------------------------------
manifest_files() {
  ls data/clean/*.csv.gz data/processed/*.csv data/processed/daily/*.csv \
     data/reference/*.csv 2>/dev/null | LC_ALL=C sort
}
manifest_now() { manifest_files | while read -r f; do md5 -r "$f"; done; }
check_manifest() {
  if [ "$DRYRUN" = 1 ]; then
    if [ -e "$MANIFEST" ]; then
      if diff -q <(manifest_now) "$MANIFEST" >/dev/null; then progress "manifest: data unchanged"
      else progress "manifest: DATA CHANGED since the first run (a real run would stop here)"; fi
    else progress "manifest: none yet (a real run writes $MANIFEST)"; fi
    return 0
  fi
  if [ -e "$MANIFEST" ]; then
    if ! diff <(manifest_now) "$MANIFEST" > "${PREFIX}_manifest_diff.txt"; then
      progress "data/ inputs changed since the first run (diff in ${PREFIX}_manifest_diff.txt):"
      sed 's/^/    | /' "${PREFIX}_manifest_diff.txt" | head -20 | tee -a "$PROGRESS"
      die "refusing to mix fits from two data states. If the change is intended, archive the new fits made so far, delete $MANIFEST and re-run."
    fi
    progress "manifest: data unchanged since $(stat -f '%Sm' "$MANIFEST")"
  else
    manifest_now > "$MANIFEST"
    progress "manifest: wrote $MANIFEST ($(wc -l < "$MANIFEST" | tr -d ' ') files)"
  fi
}

# --- preflight ---------------------------------------------------------------
preflight() {
  local ok=1 c f hdr
  for c in Rscript quarto memory_pressure md5 pgrep; do
    command -v "$c" >/dev/null || { progress "preflight: '$c' not on PATH"; ok=0; }
  done
  for f in manuscript.qmd R/01_preprocess.R R/02_impute_wemwbs.R R/03_prior_sensitivity.R \
           R/04_daily_aggregate.R R/05_loo.R R/fit_main_models.R R/fit_sensitivity_models.R \
           R/fit_daily_models.R R/prep_primary_genre.R R/prep_v121_sample.R \
           data/reference/baseline_days.csv \
           data/reference/revoked_qualified_pids.csv data/clean/survey_intake.csv.gz \
           data/clean/survey_biweekly.csv.gz; do
    [ -e "$f" ] || { progress "preflight: missing $f"; ok=0; }
  done
  # v1.2.5+ dropped ideal_baseline_day from the biweekly file; its presence
  # means data/clean still holds v1.2.1.
  hdr=$(gzip -dc data/clean/survey_biweekly.csv.gz 2>/dev/null | head -n 1 || true)
  if [[ "$hdr" == *ideal_baseline_day* ]]; then
    progress "preflight: data/clean/survey_biweekly.csv.gz has ideal_baseline_day: still v1.2.1? Run make data."
    ok=0
  fi
  if ! Rscript -e 'for (f in c("R/fit_main_models.R","R/05_loo.R","R/01_preprocess.R","R/02_impute_wemwbs.R","R/03_prior_sensitivity.R","R/04_daily_aggregate.R","R/fit_daily_models.R","R/fit_sensitivity_models.R","R/prep_primary_genre.R","R/prep_v121_sample.R")) invisible(parse(f))' >/dev/null 2>&1; then
    progress "preflight: an R script does not parse"; ok=0
  fi
  [ "$ok" = 1 ] || die "preflight failed"
  progress "preflight: ok (git $(git rev-parse --short HEAD 2>/dev/null); free $(free_pct)%; swap $(swap_used))"
  if [ "$DRYRUN" != 1 ]; then
    Rscript -e 'suppressPackageStartupMessages({library(brms); library(rstan); library(loo)}); print(sessionInfo())' \
      > "${PREFIX}_sessioninfo.log" 2>&1
    progress "preflight: sessionInfo in ${PREFIX}_sessioninfo.log"
  fi
}

# --- timetable ---------------------------------------------------------------
timetable() {
  local s name est ram skip t cum=0 line
  t=$(date +%s)
  echo
  echo "Estimated timetable (from the Jul 2026 runs; 'skip' = outputs already present now)"
  printf '  %-16s %8s  %-9s %s\n' "stage" "est." "peak RAM" "expected finish"
  for s in "${STAGES[@]}"; do
    name=$(field "$s" 1); est=$(field "$s" 2); ram=$(field "$s" 3); skip=$(field "$s" 4)
    if eval "$skip"; then
      printf '  %-16s %8s  %-9s %s\n' "$name" "skip" "" ""
    else
      cum=$((cum + est))
      line=$(date -r $((t + cum * 60)) '+%a %H:%M')
      printf '  %-16s %5d min  %-9s %s\n' "$name" "$est" "$ram" "$line"
    fi
  done
  printf '  %-16s %5d min  (%s h)\n' "total" "$cum" "$(awk -v m="$cum" 'BEGIN {printf "%.1f", m / 60}')"
  echo "  Guard: kill below ${GUARD_MIN_FREE}% free (2 samples, every ${GUARD_INTERVAL}s) or below ${GUARD_HARD_FREE}% (1 sample)."
  [ -n "$STOP_AFTER" ] && echo "  REFIT_STOP_AFTER=$STOP_AFTER: the run stops after that stage."
  echo
}

# --- stale-pin report after the render ---------------------------------------
report_render() {
  local log="${PREFIX}_render_docx.log"
  if [ "$STAGE_RC" -eq 0 ]; then
    progress "render_docx: rendered docs/manuscript.docx without errors (no stale pins hit)"
  else
    progress "render_docx: FAILED. Stale pins / guards (first failure stops knitr):"
    grep -n -A6 -E 'Quitting from|^Error|Error in|is not TRUE|are not all TRUE' "$log" |
      head -60 | sed 's/^/    | /' | tee -a "$PROGRESS"
    progress "Fix the pin, then re-run this script (only render_docx runs again)."
  fi
  if [ -s "$FAILURES" ]; then
    progress "Non-fatal chunk failures seen while fitting (expected: daily-setup and txt-daily-timescale-1 while models/daily/sesoi.rds was archived):"
    sed 's/^/    | /' "$FAILURES" | tee -a "$PROGRESS"
  fi
}

# --- main --------------------------------------------------------------------
if [ "$DRYRUN" != 1 ]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -e "$LOCK/pid" ] && kill -0 "$(cat "$LOCK/pid")" 2>/dev/null; then
      echo "another refit_v126.sh is running (pid $(cat "$LOCK/pid")); exiting"; exit 1
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" || exit 1
  fi
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
  trap 'progress "INTERRUPTED (signal); stopping current stage"; for p in $(jobs -p); do kill_tree "$p"; done; exit 130' INT TERM HUP
  if [ -e "$GUARD_FLAG" ]; then
    mv "$GUARD_FLAG" "${GUARD_FLAG}.$(date +%Y%m%d_%H%M%S)"
    progress "previous guard kill noted (marker renamed); resuming"
  fi
fi

progress "==== refit_v126.sh $( [ "$DRYRUN" = 1 ] && echo '(DRY RUN) ')start in $REPO"
if [ "$DRYRUN" = 1 ] && [ ! -e "$ARCHIVE_DONE" ]; then SIMULATE_ARCHIVE=1; fi
preflight
archive_v121
timetable | tee -a "$PROGRESS"

for s in "${STAGES[@]}"; do
  name=$(field "$s" 1); skip=$(field "$s" 4); cmd=$(field "$s" 5)
  if [ "$name" = "impute" ]; then check_manifest; fi   # after preprocessing
  if [ "$DRYRUN" = 1 ]; then
    if eval "$skip"; then progress "SKIP  $name"; else progress "WOULD RUN $name: $cmd"; fi
    if [ -n "$STOP_AFTER" ] && [ "$STOP_AFTER" = "$name" ]; then
      progress "WOULD STOP after $name (REFIT_STOP_AFTER)"; break
    fi
    continue
  fi
  run_stage "$name" "$skip" "$cmd"
  rc=$?
  if [ "$name" = "render_docx" ]; then
    report_render
    [ "$rc" -eq 0 ] || exit 2
  elif [ "$rc" -ne 0 ]; then
    die "stage $name failed; fix it and re-run (finished stages are kept)"
  fi
  maybe_stop_after "$name"
done

[ "$DRYRUN" = 1 ] && { progress "==== dry run finished; nothing was changed"; exit 0; }
progress "==== refit_v126.sh finished. Next: render --to preprint-typst and --to html one at a time (CLAUDE.md); resolve the post-refit checklist."
