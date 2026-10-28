#!/usr/bin/env bash
# =============================================================================
# Refit for Open Play v1.3.0 (Zenodo 23419571; qualified-only analytic sample)
# =============================================================================
# Refits every cached model on the v1.3.0 data, precomputes LOO, reruns the M4
# recovery simulation, and renders the Word copies of manuscript_v43.qmd and
# manuscript.qmd once at the end. Resumable: every stage is skipped when its
# outputs exist, so after an interruption (guard kill, reboot, Ctrl-C) simply
# launch the same command again.
#
# Launch from anywhere (the script cds to the repo root):
#   nohup bash scripts/refit_v130.sh > ~/open-play-render-logs/refit_v130_driver.log 2>&1 &
#   tail -f ~/open-play-render-logs/refit_v130_progress.log
# The script re-executes itself under `caffeinate -dimsu` so the Mac does not
# sleep. On one lane all stages take about 28 h (timetable in the dry run). The
# run can still be split over nights, e.g. night 1 with
#   REFIT_STOP_AFTER=daily_rest nohup bash scripts/refit_v130.sh > ... &
# and night 2 without it (sim_recovery and the two renders). Lanes (below) run
# independent stages side by side and shorten the wall time.
#
# Options (environment variables):
#   REFIT_DRYRUN=1            print the timetable and the stage plan; change nothing
#   REFIT_STOP_AFTER=<stage>  stop cleanly after that stage
#   REFIT_STAGES="a b ..."    run only these stages (always in the canonical order)
#   REFIT_LANE=<name>         run as a named lane beside the main lane (see Lanes)
#   REFIT_ARCHIVE_LANE=<name> the lane that archives and builds the data (default main)
#   REFIT_WAIT_FOR="x y ..."  before the first stage, wait until each x exists: a
#                             file, or stage:<name> for a stage that has finished
#   REFIT_GUARD_INTERVAL=30   memory sampling interval, seconds
#   REFIT_GUARD_MIN_FREE=8    kill the stage after 2 consecutive samples below this
#                             free-memory percentage (memory_pressure) ...
#   REFIT_GUARD_HARD_FREE=4   ... or after one sample below this
#
# Stages (canonical order): preflight, archive (once), preprocess (only if
# stale), prep_primary (only if stale: the primary-genre attribution file that
# the Appendix D chunk frequentist-registered reads, rebuilt whenever the main
# processed files are newer), daily_aggregate (only if stale), manifest,
# impute, main_m123, loo_h1, loo_h2_fe, loo_h2_hier, demographics, main_m4,
# loo_h2_mm, daily_m2, daily_dyn, daily_mm, daily_rest, sim_recovery (the M4
# recovery simulation, R/sim_mm_recovery.R: 20 replications at 8000
# iterations; it rewrites data/processed/sim_recovery/ and renders
# R/sim_mm_recovery_report.html), render_docx_v43 (manuscript_v43.qmd),
# render_docx (manuscript.qmd). daily_rest (M3-D, the longest stage) comes
# after the other daily stages: a lane that reaches a stage running in another
# lane waits for it, so with daily_rest in a helper lane the main lane fits
# daily_m2, daily_dyn and daily_mm in the meantime and then skips daily_rest.
#
# Lanes:
#   Without REFIT_LANE the driver is the main lane. A named lane (REFIT_LANE=x)
#   has its own lock, progress log, memory log and guard flag (suffix _x) and
#   tags its progress lines with [x], so it can run beside the main lane. Only
#   the archive lane (REFIT_ARCHIVE_LANE, default main) moves the v1.2.6
#   outputs, runs the data stages (preprocess, prep_primary, daily_aggregate)
#   and writes the data manifest. Every other lane polls every 60 s until the
#   archive (models/archive_v126/.done) and the manifest exist, checks the
#   manifest, waits for REFIT_WAIT_FOR, and then runs its stages.
#   A running stage holds a lock file (refit_v130_<stage>.running in the log
#   folder), so a stage never runs in two lanes at once: a lane that reaches a
#   stage that another lane is running waits, and then skips it because its
#   outputs are present. A stage that reads another stage's outputs (a LOO
#   reads its fit, the renders read everything) waits while that stage runs in
#   another lane, and stops with a message when that stage has neither
#   finished nor started. The simplest split is a main lane with all stages
#   plus helper lanes that take long independent stages off its plate, e.g.
#     nohup bash scripts/refit_v130.sh > ~/open-play-render-logs/refit_v130_driver.log 2>&1 &
#     REFIT_LANE=m3d REFIT_STAGES=daily_rest nohup bash scripts/refit_v130.sh \
#       > ~/open-play-render-logs/refit_v130_driver_m3d.log 2>&1 &
#     REFIT_LANE=sim REFIT_STAGES=sim_recovery nohup bash scripts/refit_v130.sh \
#       > ~/open-play-render-logs/refit_v130_driver_sim.log 2>&1 &
#   Every brms fit samples 4 chains on 4 cores. This Mac has 12 cores (6 of
#   them performance cores) and 18 GB, so three lanes use every core and memory
#   is the limit: each lane's guard watches the shared free memory, and a guard
#   kill stops that lane only (re-run it later; finished stages are kept).
#   sim_recovery can also be split between two lanes by exporting
#   SIM_REP_RANGE=1:10 in one and SIM_REP_RANGE=11:20 in the other: the two
#   ranges take separate locks, a lane's sim_recovery is done when its
#   replications are on disk, and the process that finishes the last
#   replication writes the summary and the report (a lane without
#   SIM_REP_RANGE waits for both and then skips sim_recovery).
#
# Logs (outside the session scratchpad, which a reboot wipes):
#   ~/open-play-render-logs/refit_v130_progress[_<lane>].log   one line per event
#   ~/open-play-render-logs/refit_v130_<stage>.log             full output per stage
#   ~/open-play-render-logs/refit_v130_memory[_<lane>].log     free %, swap, R RSS
#   ~/open-play-render-logs/refit_v130_GUARD_TRIPPED[_<lane>]  present after a guard kill
#
# Safety:
#   - Every stage runs in a fresh process; the driver stops at the first
#     failure or guard kill and never continues to the next stage (except that
#     a failed render does not stop the other render; the lane then exits 2).
#   - The v1.2.6 outputs are moved once (archive): models/*.rds to
#     models/archive_v126/ and models/daily/*.rds to models/daily/archive_v126/
#     (brms `file =` would otherwise silently reload them),
#     data/processed/imputation/* to data/archive/processed_v126/imputation/, and the
#     folder data/processed/sim_recovery to data/archive/processed_v126/ (its resumable
#     replication files are v1.2.6 runs, so the simulation starts afresh). A
#     file already in the archive is never overwritten; when the archive holds
#     an identical copy (data/archive/processed_v126/ was filled when v1.3.0 arrived),
#     the duplicate in data/processed/ is removed instead.
#   - data/ inputs are fingerprinted (md5) on the first run; a resumed run, and
#     every other lane, refuses to continue when they changed, so all fits
#     share one data state.
#   - The fits are made once, from the chunks of manuscript.qmd, and both
#     manuscripts load them: preflight stops unless manuscript.qmd and
#     manuscript_v43.qmd have the same chunk labels and identical chunk code
#     outside KNOWN_CHUNK_DIFFS.
#   - No all-format render: only `quarto render <file> --to docx`, one at a
#     time, from a cold cache (LOO is precomputed, so the cold cache is safe).
#     Render the other formats afterwards one at a time (CLAUDE.md).
# Supersedes scripts/run_refit.sh (wave-7 refit; do not run that script: it
# renders all formats at once). This file was scripts/refit_v126.sh until
# 2026-10-17; the logs of that run keep the refit_v126_ prefix.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

DRYRUN="${REFIT_DRYRUN:-0}"
STOP_AFTER="${REFIT_STOP_AFTER:-}"
GUARD_INTERVAL="${REFIT_GUARD_INTERVAL:-30}"
GUARD_MIN_FREE="${REFIT_GUARD_MIN_FREE:-8}"
GUARD_HARD_FREE="${REFIT_GUARD_HARD_FREE:-4}"
LANE_NAME="${REFIT_LANE:-main}"
ARCHIVE_LANE="${REFIT_ARCHIVE_LANE:-main}"
ONLY_STAGES="${REFIT_STAGES:-}"
WAIT_FOR="${REFIT_WAIT_FOR:-}"
POLL=60   # seconds between checks while a lane waits

if [[ ! "$LANE_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || [[ ! "$ARCHIVE_LANE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "REFIT_LANE and REFIT_ARCHIVE_LANE may only contain letters, digits, - and _" >&2
  exit 1
fi
if [ "$LANE_NAME" = main ]; then SFX=""; TAG=""; else SFX="_$LANE_NAME"; TAG=" [$LANE_NAME]"; fi

# SIM_REP_RANGE (read by R/sim_mm_recovery.R) splits sim_recovery between lanes.
SIM_RANGE="${SIM_REP_RANGE:-}"
SIM_RANGE_FROM=""; SIM_RANGE_TO=""; SIM_VARIANT=""
if [ -n "$SIM_RANGE" ]; then
  if [[ "$SIM_RANGE" =~ ^[[:space:]]*([0-9]+)[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
    SIM_RANGE_FROM=$((10#${BASH_REMATCH[1]}))
    SIM_RANGE_TO=$((10#${BASH_REMATCH[2]}))
    SIM_VARIANT="@${SIM_RANGE_FROM}-${SIM_RANGE_TO}"
    # The sim_recovery stage runs SIM_REPS=20 (stage table below).
    if [ "$SIM_RANGE_FROM" -lt 1 ] || [ "$SIM_RANGE_FROM" -gt "$SIM_RANGE_TO" ] || [ "$SIM_RANGE_TO" -gt 20 ]; then
      echo "SIM_REP_RANGE=$SIM_RANGE must satisfy 1 <= a <= b <= 20 (SIM_REPS of the sim_recovery stage)" >&2
      exit 1
    fi
  else
    echo "SIM_REP_RANGE must look like 1:10, got '$SIM_RANGE'" >&2
    exit 1
  fi
fi

LOG_DIR="${REFIT_LOG_DIR:-$HOME/open-play-render-logs}"
PREFIX="$LOG_DIR/refit_v130"
PROGRESS="${PREFIX}_progress${SFX}.log"
MEMLOG="${PREFIX}_memory${SFX}.log"
GUARD_FLAG="${PREFIX}_GUARD_TRIPPED${SFX}"
FAILURES="${PREFIX}_chunk_failures.txt"
RENDER_DONE="${PREFIX}_render_docx.done"
RENDER_V43_DONE="${PREFIX}_render_docx_v43.done"
RENDER_LOCK="${PREFIX}_render.running"
LOCK="${PREFIX}${SFX}.lock"
MANIFEST="models/refit_v130_manifest.md5"
ARCHIVE_DONE="models/archive_v126/.done"
SIM_DIR="data/processed/sim_recovery"
EXPECTED_N_PIDS=1668   # analytic_pids() on Open Play v1.3.0 (preflight)
mkdir -p "$LOG_DIR"

# Chunks whose code may differ between manuscript.qmd and manuscript_v43.qmd
# (prose and guard extras of the restructured candidate; none builds data or
# fits a model).
KNOWN_CHUNK_DIFFS="txt-measures-2 integrated-coefs-extract h2-hier-tau h2-mm-sigma h2-heterogeneity-extract daily-claims-guard abstract-claims-guard tbl-frequentist-registered tbl-hypothesis-summary"

# Keep the Mac awake for the whole run (not needed for a dry run).
if [ "$DRYRUN" != 1 ] && [ -z "${REFIT_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null; then
  export REFIT_CAFFEINATED=1
  exec caffeinate -dimsu bash "$REPO/scripts/refit_v130.sh" "$@"
fi

# --- helpers -----------------------------------------------------------------
now()      { date '+%Y-%m-%d %H:%M:%S'; }
progress() { echo "$(now)${TAG} $*" | tee -a "$PROGRESS"; }
die()      { progress "STOP: $*"; exit 1; }
in_list()  { local x=$1 y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

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
  # rstan/future PSOCK chain workers can be reparented to launchd (pid 1) when
  # their R master dies first, and are then missed by pgrep -P. Only such
  # orphans are stopped here, so the chains of a stage in another lane (whose
  # parent is still alive) are left alone.
  pkill -TERM -P 1 -f 'workRSOCK' 2>/dev/null
  sleep 10
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  pkill -KILL -P 1 -f 'workRSOCK' 2>/dev/null
}

# Memory guard for one stage: samples every GUARD_INTERVAL s while the stage
# runs; kills the stage tree after 2 consecutive samples below GUARD_MIN_FREE %
# (or 1 below GUARD_HARD_FREE %) and writes the GUARD_TRIPPED marker. Free
# memory is shared by all lanes, so the guards of several lanes can trip
# together; each stops only its own stage.
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

# present FILE: exists. In a dry run before the archive step, the v1.2.6
# outputs that the archive moves (models/**/*.rds, data/processed/imputation/,
# data/processed/sim_recovery/) count as absent, so the plan shows what a real
# run will do.
SIMULATE_ARCHIVE=0
present() {
  [ -e "$1" ] || return 1
  if [ "$SIMULATE_ARCHIVE" = 1 ]; then
    case "$1" in models/*.rds|data/processed/imputation/*|"$SIM_DIR"/*) return 1 ;; esac
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
  for o in ${outs[@]+"${outs[@]}"}; do
    present "$o" || return 1
    for i in ${ins[@]+"${ins[@]}"}; do [ "$o" -nt "$i" ] || return 1; done
  done
  return 0
}
all_exist() { local f; for f in "$@"; do present "$f" || return 1; done; return 0; }

# sim_done: the recovery simulation has finished (its summary files exist and
# the report was rendered after the summary: R/sim_mm_recovery.R writes the
# csv files before it renders, so a failed render leaves the stage undone).
# With SIM_REP_RANGE=a:b exported (sim_recovery split between two lanes), this
# lane's share is done as soon as replications a..b are on disk; the process
# that writes the last replication also writes the summary.
sim_done_strict() {
  all_exist "$SIM_DIR/recovery_summary.csv" "$SIM_DIR/diagnostics.csv" &&
    fresh R/sim_mm_recovery_report.html -- "$SIM_DIR/recovery_summary.csv"
}
sim_done() {
  sim_done_strict && return 0
  [ -n "$SIM_VARIANT" ] || return 1
  local r
  for r in $(seq "$SIM_RANGE_FROM" "$SIM_RANGE_TO"); do
    present "$(printf '%s/reps/rep_%03d.rds' "$SIM_DIR" "$r")" || return 1
  done
  return 0
}

CLEAN_INPUTS=(data/clean/*.csv.gz data/reference/baseline_days.csv)
PRE_OUT=(data/processed/genre_wave_long.csv data/processed/total_playtime.csv
         data/processed/game_metadata_long.csv)
DAILY_OUT=(data/processed/daily/diary_analysis.csv data/processed/daily/genre_day_long.csv
           data/processed/daily/daily_model_frame.csv)
DAILY_IN=(data/clean/survey_daily.csv.gz data/clean/survey_intake.csv.gz
          data/clean/survey_biweekly.csv.gz "${PRE_OUT[@]}")
LOO_FILES="models/loo_h1.rds models/loo_h2_fe.rds models/loo_h2_mm.rds models/loo_h2_hier.rds"
RENDER_IN="models/h2_mm_model_full.rds models/daily/m4_daily_mm_ls.rds models/h2_hier_model_v4.rds models/daily/m3_daily_ls_v4.rds $SIM_DIR/recovery_summary.csv"
DATA_STAGES="preprocess prep_primary daily_aggregate"

# --- stage table (name | est. minutes | est. peak RAM | skip test | command |
# needs: stages whose outputs this stage reads; ALL = every non-render stage)
# Fitting-stage estimates are the stage times of the v1.2.6 run of 13-14 Oct
# 2026 (6,293 person-waves; v1.3.0 has 6,518, about 4% more): main_m123 121
# min (the non-centred M3 dominates), main_m4 192, daily_rest 554 (M3-D),
# daily_mm 286, impute 7, demographics 5, each LOO about 1. daily_m2 and
# daily_dyn are rounded up from that run (4 and 8 min); sim_recovery is 20
# replications of about 20 min each (14 Oct 2026). loo_h2_hier also requires
# the v4 fit to exist: `fresh` alone would count an old LOO file as current
# while the fit is still missing ([ a -nt b ] is true when b is absent).
STAGES=(
  "preprocess|3|<2 GB|fresh ${PRE_OUT[*]} -- ${CLEAN_INPUTS[*]}|Rscript R/01_preprocess.R|"
  "prep_primary|1|<2 GB|fresh data/processed/genre_wave_long_primary.csv -- data/processed/genre_wave_long.csv data/processed/total_playtime.csv|Rscript R/prep_primary_genre.R|preprocess"
  "daily_aggregate|1|<2 GB|fresh ${DAILY_OUT[*]} -- ${DAILY_IN[*]}|Rscript R/04_daily_aggregate.R|preprocess"
  "impute|7|~2 GB|all_exist data/processed/imputation/imp_wemwbs.rds data/processed/imputation/imputed_long.rds|Rscript R/02_impute_wemwbs.R|$DATA_STAGES"
  "main_m123|125|2-3 GB|all_exist models/h1_rewb_model.rds models/h2_genre_model.rds models/h2_hier_model_v4.rds|env REFIT_CHUNKS=range REFIT_FAILURES_FILE=$FAILURES Rscript R/fit_main_models.R h2-hier-fit|$DATA_STAGES"
  "loo_h1|1|2-3 GB|fresh models/loo_h1.rds -- models/h1_rewb_model.rds|Rscript R/05_loo.R h1|main_m123"
  "loo_h2_fe|1|2-3 GB|fresh models/loo_h2_fe.rds -- models/h2_genre_model.rds|Rscript R/05_loo.R h2_fe|main_m123"
  "loo_h2_hier|1|4-5 GB|all_exist models/h2_hier_model_v4.rds && fresh models/loo_h2_hier.rds -- models/h2_hier_model_v4.rds|Rscript R/05_loo.R h2_hier|main_m123"
  "demographics|5|2-3 GB|all_exist models/h1_demographics.rds models/h2_demographics.rds|Rscript R/fit_sensitivity_models.R|$DATA_STAGES"
  "main_m4|190|4-6 GB|all_exist models/h2_mm_model_full.rds|env REFIT_CHUNKS=minimal REFIT_FAILURES_FILE=$FAILURES Rscript R/fit_main_models.R h2-mm-fit|$DATA_STAGES"
  "loo_h2_mm|1|4-5 GB|fresh models/loo_h2_mm.rds -- models/h2_mm_model_full.rds|Rscript R/05_loo.R h2_mm|main_m4"
  "daily_m2|25|2-3 GB|all_exist models/daily/m2_daily_ls.rds|Rscript R/fit_daily_models.R m2|$DATA_STAGES"
  "daily_dyn|10|2-3 GB|all_exist models/daily/m1_daily_ls_ar.rds models/daily/m1_daily_ls_wh.rds|Rscript R/fit_daily_models.R dyn|$DATA_STAGES"
  "daily_mm|285|3-5 GB|all_exist models/daily/m4_daily_mm_ls.rds|Rscript R/fit_daily_models.R mm|$DATA_STAGES"
  "daily_rest|555|2-3 GB|all_exist models/daily/m1_daily_ls.rds models/daily/m1_daily_ls_full.rds models/daily/m1_daily_ls_xfl.rds models/daily/m3_daily_ls_v4.rds|Rscript R/fit_daily_models.R rest|$DATA_STAGES"
  "sim_recovery|420|3-5 GB|sim_done|env SIM_REPS=20 SIM_ITER=8000 SIM_RENDER=1 Rscript R/sim_mm_recovery.R|"
  "render_docx_v43|20|~6 GB|[ ! -e manuscript_v43.qmd ] || fresh $RENDER_V43_DONE -- $RENDER_IN|ls $LOO_FILES >/dev/null && rm -rf manuscript_v43_cache && quarto render manuscript_v43.qmd --to docx && touch $RENDER_V43_DONE|ALL"
  "render_docx|20|~6 GB|fresh $RENDER_DONE -- $RENDER_IN|ls $LOO_FILES >/dev/null && rm -rf manuscript_cache && quarto render manuscript.qmd --to docx && touch $RENDER_DONE|ALL"
)
field() { echo "$1" | cut -d'|' -f"$2"; }
stage_line() {
  local s
  for s in "${STAGES[@]}"; do [ "$(field "$s" 1)" = "$1" ] && { echo "$s"; return 0; }; done
  return 1
}
is_render()     { case "$1" in render_*) return 0 ;; esac; return 1; }
is_data_stage() { in_list "$1" $DATA_STAGES; }
is_archive_lane() { [ "$LANE_NAME" = "$ARCHIVE_LANE" ]; }

# --- stages of this lane -----------------------------------------------------
ALL_NAMES=()
for s in "${STAGES[@]}"; do ALL_NAMES+=("$(field "$s" 1)"); done
for n in $ONLY_STAGES; do
  in_list "$n" "${ALL_NAMES[@]}" ||
    { echo "REFIT_STAGES: unknown stage '$n' (stages: ${ALL_NAMES[*]})" >&2; exit 1; }
done
LANE_STAGES=()
for s in "${STAGES[@]}"; do
  n=$(field "$s" 1)
  if [ -z "$ONLY_STAGES" ] || in_list "$n" $ONLY_STAGES; then LANE_STAGES+=("$s"); fi
done
LANE_NAMES=""
for s in "${LANE_STAGES[@]}"; do LANE_NAMES="$LANE_NAMES $(field "$s" 1)"; done
LANE_NAMES="${LANE_NAMES# }"
if ! is_archive_lane; then
  for n in $LANE_NAMES; do
    if is_data_stage "$n"; then
      echo "lane $LANE_NAME: data stage $n runs only in the archive lane ($ARCHIVE_LANE); drop it from REFIT_STAGES" >&2
      exit 1
    fi
  done
fi

# --- stage locks -------------------------------------------------------------
# A lock file holds "driver_pid stage_pid lane"; it is alive while either
# process runs. A file without a pid is being written and counts as alive for
# two minutes.
HELD_LOCKS=()
lock_alive() {
  local f=$1 p age
  [ -e "$f" ] || return 1
  for p in $(awk '{print $1, $2; exit}' "$f" 2>/dev/null); do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$p" 2>/dev/null && return 0
  done
  if [ -z "$(tr -d '[:space:]' < "$f" 2>/dev/null)" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || echo 0) ))
    [ "$age" -lt 120 ] && return 0
  fi
  return 1
}
lock_mine() { [ "$(awk '{print $1; exit}' "$1" 2>/dev/null)" = "$$" ]; }
lock_free() { ! lock_alive "$1" || lock_mine "$1"; }
lock_try() {
  local f=$1
  if ( set -C; echo "$$ - $LANE_NAME" > "$f" ) 2>/dev/null; then HELD_LOCKS+=("$f"); return 0; fi
  lock_alive "$f" && return 1
  rm -f "$f"   # left behind by a driver that no longer runs
  if ( set -C; echo "$$ - $LANE_NAME" > "$f" ) 2>/dev/null; then HELD_LOCKS+=("$f"); return 0; fi
  return 1
}
lock_release() {
  local f=$1 k keep=()
  lock_mine "$f" && rm -f "$f"
  for k in ${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}; do [ "$k" = "$f" ] || keep+=("$k"); done
  HELD_LOCKS=(${keep[@]+"${keep[@]}"})
}
release_all_locks() {
  local k
  for k in ${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}; do lock_mine "$k" && rm -f "$k"; done
  HELD_LOCKS=()
}
stage_variant()   { if [ "$1" = sim_recovery ]; then echo "$SIM_VARIANT"; fi; }
stage_lock_file() { echo "${PREFIX}_$1$(stage_variant "$1").running"; }
# stage_busy NAME [any]: another driver runs NAME. A lock without a variant
# conflicts with every variant; a sim_recovery range (SIM_REP_RANGE) conflicts
# only with the full run and the same range. With `any`, every variant counts.
stage_busy() {
  local name=$1 mode=${2:-} f own variant
  own=$(stage_lock_file "$name")
  variant=$(stage_variant "$name")
  for f in "${PREFIX}_${name}.running" "${PREFIX}_${name}"@*.running; do
    [ -e "$f" ] || continue
    if [ "$mode" != any ] && [ -n "$variant" ] && [ "$f" != "${PREFIX}_${name}.running" ] &&
       [ "$f" != "$own" ]; then continue; fi
    lock_mine "$f" && continue
    lock_alive "$f" && return 0
  done
  return 1
}
stage_free() { ! stage_busy "$1"; }
stage_settled() { ! stage_busy "$1" any; }
# stage_complete NAME: outputs present and current, and no lane is running it.
stage_complete() {
  local name=$1 line
  stage_busy "$name" any && return 1
  if [ "$name" = sim_recovery ]; then sim_done_strict; return; fi
  line=$(stage_line "$name") || return 1
  eval "$(field "$line" 4)"
}
expand_needs() {
  local needs=$1 n out=""
  if [ "$needs" = ALL ]; then
    for n in "${ALL_NAMES[@]}"; do is_render "$n" || out="$out $n"; done
    echo "${out# }"
  else
    echo "$needs"
  fi
}
pending_needs() {
  local n out=""
  for n in $(expand_needs "$(field "$(stage_line "$1")" 6)"); do
    stage_complete "$n" || out="$out $n"
  done
  echo "${out# }"
}

# wait_until DESCRIPTION COMMAND...: poll every POLL s until COMMAND succeeds;
# the first wait is logged and then one line every 30 polls.
wait_until() {
  local what=$1 n=0
  shift
  while ! "$@"; do
    if [ $((n % 30)) -eq 0 ]; then progress "WAIT  $what"; fi
    n=$((n + 1))
    sleep "$POLL"
  done
  if [ "$n" -gt 0 ]; then progress "GO    $what (waited $(( n * POLL / 60 )) min)"; fi
  return 0
}

# wait_needs NAME: wait while a stage that NAME reads runs in another lane;
# stop when such a stage has neither finished nor started anywhere.
wait_needs() {
  local name=$1 n
  for n in $(expand_needs "$(field "$(stage_line "$name")" 6)"); do
    stage_complete "$n" && continue
    if stage_busy "$n" any; then
      wait_until "$name needs $n, which is running in another lane" stage_settled "$n"
      stage_complete "$n" && continue
    fi
    die "$name needs $n, which has not finished and is not running in any lane. Run $n first, or let this lane wait for it (REFIT_WAIT_FOR=stage:$n)."
  done
}

# --- run one stage under the memory guard ------------------------------------
STAGE_RC=0
run_stage() {
  local name=$1 skip=$2 cmd=$3 log="${PREFIX}_$1.log" t0 pid gpid rc lockf mins
  STAGE_RC=0
  lockf=$(stage_lock_file "$name")
  while :; do
    if stage_busy "$name"; then
      wait_until "$name is running in another lane" stage_free "$name"
    fi
    if eval "$skip"; then
      progress "SKIP  $name (outputs present and current)"
      return 0
    fi
    wait_needs "$name"
    if is_render "$name" && ! lock_try "$RENDER_LOCK"; then
      wait_until "another lane is rendering" lock_free "$RENDER_LOCK"
      continue
    fi
    lock_try "$lockf" && break
    is_render "$name" && lock_release "$RENDER_LOCK"
  done
  # Another lane may have finished the stage while this one waited for the lock.
  if eval "$skip"; then
    lock_release "$lockf"
    if is_render "$name"; then lock_release "$RENDER_LOCK"; fi
    progress "SKIP  $name (outputs present and current)"
    return 0
  fi
  t0=$(date +%s)
  progress "START $name  [free $(free_pct)% | swap $(swap_used)]  $cmd"
  { echo "=== $(now) START $name (lane $LANE_NAME)"; echo "cmd: $cmd"; echo "git: $(git rev-parse --short HEAD 2>/dev/null) (+ uncommitted changes)"; } >> "$log"
  bash -c "$cmd" >> "$log" 2>&1 &
  pid=$!
  echo "$$ $pid $LANE_NAME" > "$lockf"   # alive while the stage runs, even without the driver
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
  lock_release "$lockf"
  if is_render "$name"; then lock_release "$RENDER_LOCK"; fi
  STAGE_RC=$rc
  mins=$(( ($(date +%s) - t0 + 30) / 60 ))
  if [ -e "$GUARD_FLAG" ]; then
    progress "ABORT $name after ${mins} min: memory guard tripped ($(cat "$GUARD_FLAG")). Close other apps (or stop a lane) and re-run; finished stages are kept."
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

RENDER_FAILED=0
maybe_stop_after() {
  if [ -n "$STOP_AFTER" ] && [ "$STOP_AFTER" = "$1" ]; then
    progress "STOP after $1 as requested (REFIT_STOP_AFTER). Re-run without it to continue."
    if [ "$RENDER_FAILED" = 1 ]; then exit 2; fi
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
      die "$src and $dest/$base both exist and differ; resolve by hand (which one is v1.2.6?)"
    fi
  else
    mv -n "$src" "$dest/" && progress "  archived $src -> $dest/"
    [ -e "$src" ] && die "could not move $src"
  fi
  return 0
}
# archive_dir SRC DESTDIR: the same for a folder (identical = diff -r finds
# no difference).
archive_dir() {
  local src=$1 dest=$2 base
  base=$(basename "$src")
  [ -d "$src" ] || return 0
  mkdir -p "$dest"
  if [ -e "$dest/$base" ]; then
    if diff -rq "$src" "$dest/$base" >/dev/null 2>&1; then
      rm -rf "$src"; progress "  $src/: identical copy already in $dest; removed duplicate"
    else
      die "$src/ and $dest/$base/ both exist and differ; resolve by hand (which one is v1.2.6?)"
    fi
  else
    mv -n "$src" "$dest/" && progress "  archived $src/ -> $dest/"
    [ -e "$src" ] && die "could not move $src"
  fi
  return 0
}

archive_v126() {
  if [ -e "$ARCHIVE_DONE" ]; then
    progress "SKIP  archive (done $(cat "$ARCHIVE_DONE"))"
    return 0
  fi
  if [ "$DRYRUN" = 1 ]; then
    progress "WOULD archive the v1.2.6 outputs: $(ls models/*.rds 2>/dev/null | wc -l | tr -d ' ') rds files from models/, $(ls models/daily/*.rds 2>/dev/null | wc -l | tr -d ' ') from models/daily/, $(ls data/processed/imputation/* 2>/dev/null | wc -l | tr -d ' ') files from data/processed/imputation/, and the folder $SIM_DIR/ ($( [ -d "$SIM_DIR" ] && echo present || echo absent))"
    return 0
  fi
  progress "START archive of the v1.2.6 outputs"
  local f
  # Every top-level fit in models/ and models/daily/ predates v1.3.0 (including
  # unused ones such as the centred h2_hier_model_v3 and m3_daily_ls_v3, kept
  # for comparison, and the loo_*.rds files).
  for f in models/*.rds;       do archive_one "$f" models/archive_v126; done
  for f in models/daily/*.rds; do archive_one "$f" models/daily/archive_v126; done
  archive_one models/refit_v126_manifest.md5 models/archive_v126
  # Derived v1.2.6 outputs. data/archive/processed_v126/ already holds copies made when
  # v1.3.0 arrived; identical duplicates are removed from data/processed/.
  archive_one data/processed/prior_sensitivity_summary.rds data/archive/processed_v126
  for f in data/processed/imputation/*; do archive_one "$f" data/archive/processed_v126/imputation; done
  archive_dir "$SIM_DIR" data/archive/processed_v126
  # Daily aggregates: keep them when they were regenerated from the v1.3.0
  # files (newer than data/clean and the processed inputs), else move them
  # aside; the daily_aggregate stage then rebuilds them.
  if ! ls data/processed/daily/* >/dev/null 2>&1; then
    progress "  data/processed/daily/ is empty; the daily_aggregate stage builds it"
  elif ! fresh "${DAILY_OUT[@]}" -- "${DAILY_IN[@]}"; then
    local dd=data/archive/processed_v126/daily
    if ls "$dd"/* >/dev/null 2>&1; then dd="data/archive/processed_v126/daily_superseded_$(date +%Y%m%d_%H%M)"; fi
    for f in data/processed/daily/*; do archive_one "$f" "$dd"; done
  else
    progress "  data/processed/daily/ is current (regenerated from v1.3.0); kept"
  fi
  mkdir -p models/archive_v126
  now > "$ARCHIVE_DONE"
  progress "END   archive"
}

# --- data manifest -----------------------------------------------------------
# Written once by the archive lane after its data stages; every later run and
# every other lane compares the data with it.
# (ls exits 1 when a pattern matches nothing; with pipefail that status must
# not decide whether the manifest is written, hence the explicit return 0.)
manifest_files() {
  ls data/clean/*.csv.gz data/processed/*.csv data/processed/daily/*.csv \
     data/reference/*.csv 2>/dev/null | LC_ALL=C sort
  return 0
}
manifest_now() { manifest_files | while read -r f; do md5 -r "$f"; done; }
MANIFEST_CHECKED=0
check_manifest() {
  MANIFEST_CHECKED=1
  if [ "$DRYRUN" = 1 ]; then
    if [ -e "$MANIFEST" ]; then
      if diff -q <(manifest_now) "$MANIFEST" >/dev/null; then progress "manifest: data unchanged"
      else progress "manifest: DATA CHANGED since the first run (a real run would stop here)"; fi
    elif is_archive_lane; then progress "manifest: none yet (a real run writes $MANIFEST)"
    else progress "manifest: none yet (WOULD wait for lane $ARCHIVE_LANE to write $MANIFEST)"; fi
    return 0
  fi
  if [ ! -e "$MANIFEST" ] && ! is_archive_lane; then
    wait_until "the data manifest of lane $ARCHIVE_LANE ($MANIFEST)" test -e "$MANIFEST"
  fi
  if [ -e "$MANIFEST" ]; then
    if ! diff <(manifest_now) "$MANIFEST" > "${PREFIX}_manifest_diff${SFX}.txt"; then
      progress "data/ inputs changed since the first run (diff in ${PREFIX}_manifest_diff${SFX}.txt):"
      sed 's/^/    | /' "${PREFIX}_manifest_diff${SFX}.txt" | head -20 | tee -a "$PROGRESS"
      die "refusing to mix fits from two data states. If the change is intended, archive the new fits made so far, delete $MANIFEST and re-run."
    fi
    progress "manifest: data unchanged since $(stat -f '%Sm' "$MANIFEST")"
  else
    manifest_now > "${MANIFEST}.tmp.$$"
    [ -s "${MANIFEST}.tmp.$$" ] || die "manifest: no data files found under data/"
    mv -f "${MANIFEST}.tmp.$$" "$MANIFEST" || die "manifest: could not write $MANIFEST"
    progress "manifest: wrote $MANIFEST ($(wc -l < "$MANIFEST" | tr -d ' ') files)"
  fi
}

# --- preflight ---------------------------------------------------------------
# check_chunks: same chunk labels in both manuscripts and identical code
# outside KNOWN_CHUNK_DIFFS (fits are made once, from manuscript.qmd). The R
# code contains no backslash, because Rscript -e removes one level of them.
R_CHUNK_CHECK='
known <- strsplit(Sys.getenv("REFIT_KNOWN_DIFFS"), " +")[[1]]
split_chunks <- function(qmd) {
  f <- tempfile(fileext = ".R")
  invisible(knitr::purl(qmd, output = f, quiet = TRUE, documentation = 1))
  l <- readLines(f, warn = FALSE)
  s <- grep("^## ----", l)
  e <- c(s[-1] - 1L, length(l))
  ch <- Map(function(a, b) l[(a + 1L):b], s, e)
  lab <- vapply(ch, function(code) {
    m <- grep("^#[|] label:", code, value = TRUE)
    if (length(m)) trimws(sub("^#[|] label:[[:space:]]*", "", m[1])) else NA_character_
  }, character(1))
  lab[is.na(lab)] <- paste0("unlabelled-", which(is.na(lab)))
  code <- lapply(ch, function(code) {
    x <- code[!grepl("^#[|]", code)]
    x[nzchar(trimws(x))]
  })
  names(code) <- lab
  code
}
a <- split_chunks("manuscript.qmd")
b <- split_chunks("manuscript_v43.qmd")
only <- c(setdiff(names(a), names(b)), setdiff(names(b), names(a)))
common <- intersect(names(a), names(b))
differ <- common[!mapply(identical, a[common], b[common])]
bad <- setdiff(differ, known)
writeLines(sprintf("chunks %d / %d (manuscript.qmd / manuscript_v43.qmd); code differs in %d, all in the known list: %s",
                   length(a), length(b), length(differ), if (length(bad)) "no" else "yes"))
if (length(only)) writeLines(paste("labels in one file only:", paste(only, collapse = ", ")))
if (length(bad)) writeLines(paste("code differs outside the known list:", paste(bad, collapse = ", ")))
quit(save = "no", status = if (length(only) || length(bad)) 1 else 0)
'
check_chunks() { REFIT_KNOWN_DIFFS="$KNOWN_CHUNK_DIFFS" Rscript -e "$R_CHUNK_CHECK" 2>/dev/null; }

preflight() {
  local ok=1 c f hdr n out
  for c in Rscript quarto memory_pressure md5 pgrep pkill; do
    command -v "$c" >/dev/null || { progress "preflight: '$c' not on PATH"; ok=0; }
  done
  for f in manuscript.qmd R/01_preprocess.R R/02_impute_wemwbs.R \
           R/03_prior_sensitivity.R R/04_daily_aggregate.R R/05_loo.R R/fit_main_models.R \
           R/fit_sensitivity_models.R R/fit_daily_models.R R/prep_primary_genre.R \
           R/sim_mm_recovery.R R/sim_mm_recovery_report.qmd \
           data/reference/baseline_days.csv data/clean/survey_intake.csv.gz \
           data/clean/survey_biweekly.csv.gz; do
    [ -e "$f" ] || { progress "preflight: missing $f"; ok=0; }
  done
  # Releases >= v1.2.5 do not ship ideal_baseline_day in the clean biweekly
  # file; its presence means data/clean still holds an older release.
  hdr=$(gzip -dc data/clean/survey_biweekly.csv.gz 2>/dev/null | head -n 1 || true)
  if [[ "$hdr" == *ideal_baseline_day* ]]; then
    progress "preflight: data/clean/survey_biweekly.csv.gz has ideal_baseline_day: an older release? Run make data."
    ok=0
  fi
  if ! Rscript -e 'for (f in c("R/fit_main_models.R","R/05_loo.R","R/01_preprocess.R","R/02_impute_wemwbs.R","R/03_prior_sensitivity.R","R/04_daily_aggregate.R","R/fit_daily_models.R","R/fit_sensitivity_models.R","R/prep_primary_genre.R","R/sim_mm_recovery.R")) invisible(parse(f))' >/dev/null 2>&1; then
    progress "preflight: an R script does not parse"; ok=0
  fi
  if [ ! -e manuscript_v43.qmd ]; then
    progress "preflight: manuscript_v43.qmd not present (local-only candidate, not in git); chunk comparison skipped"
  elif out=$(check_chunks); then
    progress "preflight: $out"
  else
    progress "preflight: manuscript.qmd and manuscript_v43.qmd no longer share their chunk code:"
    echo "${out:-(chunk check did not run)}" | sed 's/^/    | /' | tee -a "$PROGRESS"
    ok=0
  fi
  n=$(Rscript -e 'suppressMessages(suppressWarnings(source("R/01_preprocess.R"))); cat(length(analytic_pids()))' 2>/dev/null)
  progress "preflight: analytic sample ${n:-?} participants (analytic_pids() on data/clean)"
  # v1.3.0 under the sample rule gives 1,668 participants (v1.2.6: 1,608).
  if [ "$n" != "$EXPECTED_N_PIDS" ]; then
    progress "preflight: expected $EXPECTED_N_PIDS analytic participants (Open Play v1.3.0); is data/clean another release? Run make data."
    ok=0
  fi
  # Evaluate the chunks every fit depends on (setup, load-data, load-mobile,
  # model-data, mm-data-setup, mm-formula-setup) up to the first brm() call:
  # a failing guard there would otherwise stop main_m123 and main_m4 only
  # after the archive. About 10 s; fits nothing and loads no model.
  if out=$(REFIT_DRYRUN=1 REFIT_CHUNKS=minimal Rscript R/fit_main_models.R h2-mm-fit 2>&1); then
    progress "preflight: fit dependency chunks evaluate ($(echo "$out" | grep 'DRYRUN fit frame' | sed 's/^.*DRYRUN //'))"
  else
    progress "preflight: a fit dependency chunk fails (REFIT_DRYRUN=1 REFIT_CHUNKS=minimal Rscript R/fit_main_models.R h2-mm-fit):"
    echo "$out" | grep -v 'Sys.setlocale\|OS reports' | tail -n 8 | sed 's/^/    | /' | tee -a "$PROGRESS"
    ok=0
  fi
  if [ "$ok" != 1 ]; then
    [ "$DRYRUN" = 1 ] || die "preflight failed"
    progress "preflight FAILED (the dry run continues; a real run stops here)"
  else
    progress "preflight: ok (git $(git rev-parse --short HEAD 2>/dev/null); free $(free_pct)%; swap $(swap_used))"
  fi
  if [ "$DRYRUN" != 1 ]; then
    Rscript -e 'suppressPackageStartupMessages({library(brms); library(rstan); library(loo)}); print(sessionInfo()); if (requireNamespace("cmdstanr", quietly = TRUE)) print(tryCatch(cmdstanr::cmdstan_version(), error = function(e) conditionMessage(e)))' \
      > "${PREFIX}_sessioninfo${SFX}.log" 2>&1
    progress "preflight: sessionInfo in ${PREFIX}_sessioninfo${SFX}.log"
  fi
}

# --- waits of a lane that does not archive -------------------------------------
wait_for_archive() {
  if [ -e "$ARCHIVE_DONE" ]; then
    progress "archive: done by lane $ARCHIVE_LANE ($(cat "$ARCHIVE_DONE"))"
  elif [ "$DRYRUN" = 1 ]; then
    progress "WOULD wait for the archive by lane $ARCHIVE_LANE ($ARCHIVE_DONE)"
  else
    wait_until "the archive by lane $ARCHIVE_LANE ($ARCHIVE_DONE)" test -e "$ARCHIVE_DONE"
  fi
}
# REFIT_WAIT_FOR: files, or stage:<name> for a stage that has finished (outputs
# present and no lane running it). A fit file exists before brms has finished
# writing it, so use stage:<name> for a stage's outputs.
wait_for_files() {
  local w n
  for w in $WAIT_FOR; do
    case "$w" in
      stage:*)
        n=${w#stage:}
        stage_line "$n" >/dev/null || die "REFIT_WAIT_FOR: unknown stage '$n'"
        if stage_complete "$n"; then progress "wait-for $w: finished"
        elif [ "$DRYRUN" = 1 ]; then progress "WOULD wait for $w"
        else wait_until "REFIT_WAIT_FOR $w" stage_complete "$n"; fi
        ;;
      *)
        if [ -e "$w" ]; then progress "wait-for $w: present"
        elif [ "$DRYRUN" = 1 ]; then progress "WOULD wait for $w"
        else wait_until "REFIT_WAIT_FOR $w" test -e "$w"; fi
        ;;
    esac
  done
}

# --- timetable ---------------------------------------------------------------
timetable() {
  local s name est ram skip t cum=0 line
  t=$(date +%s)
  echo
  echo "Estimated timetable, lane $LANE_NAME (stage times of the v1.2.6 run, 13-14 Oct 2026; 'skip' = outputs already present now; waits for other lanes not included)"
  printf '  %-16s %8s  %-9s %s\n' "stage" "est." "peak RAM" "expected finish"
  for s in "${LANE_STAGES[@]}"; do
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

# --- dry-run plan line ---------------------------------------------------------
plan_line() {
  local name=$1 skip=$2 cmd=$3 after note=""
  if stage_busy "$name"; then note="  (running in another lane now)"; fi
  if eval "$skip"; then
    progress "SKIP  $name$note"
    return 0
  fi
  after=$(pending_needs "$name")
  if [ -n "$after" ]; then
    if [ "$(field "$(stage_line "$name")" 6)" = ALL ]; then note="$note  (after every other stage)"
    else note="$note  (after: $after)"; fi
  fi
  progress "WOULD RUN $name: $cmd$note"
}

# --- stale-pin report after a render -----------------------------------------
FAILURES_REPORTED=0
last_run_section() { awk '/^=== .* START /{buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' "$1"; }
report_render() {
  local name=$1 log="${PREFIX}_$1.log" out=docs/manuscript.docx
  [ "$name" = render_docx_v43 ] && out=manuscript_v43.docx  # not in the _quarto.yml render list: lands in the repo root; local only (reviews/manuscript_v43/), not published
  if [ "$STAGE_RC" -eq 0 ]; then
    progress "$name: rendered $out without errors (no stale pins hit)"
  else
    progress "$name: FAILED. Stale pins / guards (first failure stops knitr):"
    last_run_section "$log" | grep -n -A6 -E 'Quitting from|^Error|Error in|is not TRUE|are not all TRUE' |
      head -60 | sed 's/^/    | /' | tee -a "$PROGRESS"
    progress "Fix the pin, then re-run this script (only the failed render runs again)."
  fi
  if [ "$FAILURES_REPORTED" = 0 ] && [ -s "$FAILURES" ]; then
    FAILURES_REPORTED=1
    progress "Non-fatal chunk failures seen while fitting (expected: daily-setup and txt-daily-timescale-1 while models/daily/sesoi.rds was archived):"
    sed 's/^/    | /' "$FAILURES" | tee -a "$PROGRESS"
  fi
}

# --- main --------------------------------------------------------------------
if [ -z "$LANE_NAMES" ]; then echo "lane $LANE_NAME has no stages" >&2; exit 1; fi
if [ "$DRYRUN" != 1 ]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -e "$LOCK/pid" ] && kill -0 "$(cat "$LOCK/pid")" 2>/dev/null; then
      echo "another refit_v130.sh is running in lane $LANE_NAME (pid $(cat "$LOCK/pid")); exiting"; exit 1
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" || exit 1
  fi
  echo $$ > "$LOCK/pid"
  trap 'release_all_locks; rm -rf "$LOCK"' EXIT
  trap 'progress "INTERRUPTED (signal); stopping current stage"; for p in $(jobs -p); do kill_tree "$p"; done; exit 130' INT TERM HUP
  if [ -e "$GUARD_FLAG" ]; then
    mv "$GUARD_FLAG" "${GUARD_FLAG}.$(date +%Y%m%d_%H%M%S)"
    progress "previous guard kill noted (marker renamed); resuming"
  fi
fi

if is_archive_lane; then lane_role="archive lane"; else lane_role="archive lane: $ARCHIVE_LANE"; fi
progress "==== refit_v130.sh $( [ "$DRYRUN" = 1 ] && echo '(DRY RUN) ')start in $REPO; lane $LANE_NAME ($lane_role); stages: $LANE_NAMES"
if [ "$DRYRUN" = 1 ] && [ ! -e "$ARCHIVE_DONE" ]; then SIMULATE_ARCHIVE=1; fi
preflight
if is_archive_lane; then
  archive_v126
else
  wait_for_archive
  check_manifest
fi
wait_for_files
timetable | tee -a "$PROGRESS"

for s in "${LANE_STAGES[@]}"; do
  name=$(field "$s" 1); skip=$(field "$s" 4); cmd=$(field "$s" 5)
  # The archive lane fingerprints the data once its data stages are done.
  if [ "$MANIFEST_CHECKED" = 0 ] && ! is_data_stage "$name"; then check_manifest; fi
  if [ "$DRYRUN" = 1 ]; then
    plan_line "$name" "$skip" "$cmd"
    if [ -n "$STOP_AFTER" ] && [ "$STOP_AFTER" = "$name" ]; then
      progress "WOULD STOP after $name (REFIT_STOP_AFTER)"; break
    fi
    continue
  fi
  run_stage "$name" "$skip" "$cmd"
  rc=$?
  if is_render "$name"; then
    report_render "$name"
    [ "$rc" -eq 0 ] || RENDER_FAILED=1
  elif [ "$rc" -ne 0 ]; then
    die "stage $name failed; fix it and re-run (finished stages are kept)"
  fi
  maybe_stop_after "$name"
done
if [ "$MANIFEST_CHECKED" = 0 ]; then check_manifest; fi

[ "$DRYRUN" = 1 ] && { progress "==== dry run finished; nothing was changed"; exit 0; }
if [ "$RENDER_FAILED" = 1 ]; then
  progress "==== refit_v130.sh (lane $LANE_NAME) finished with a failed render: fix the pins and re-run (only the failed render runs again)."
  exit 2
fi
progress "==== refit_v130.sh (lane $LANE_NAME) finished. Next: render --to preprint-typst and --to html one at a time (CLAUDE.md); resolve the post-refit checklist (notes/post_refit_checklist_v130.md)."
