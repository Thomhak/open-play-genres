# Analysis plan: exploratory daily-timescale extension (prespecified in code)

Status: DECISIONS FIXED BEFORE ANY EXPOSURE-OUTCOME MODEL IS FIT.
Written 2026-07-29 (Fable session, autonomous run authorised by Thomas).
Slots marked [A: ...] are filled from the marginals report (Phase A) BEFORE
fitting; nothing below changes after the first model runs. This document is
the audit trail for the manuscript's "prespecified before estimation" claim.

## Purpose and status of the analysis

Unregistered exploratory extension of the Stage 2 genres manuscript,
answering the manuscript's own measurement-resolution question one rung down
the hierarchy of disaggregation: do the biweekly conclusions (H1 practical
null; H2 heterogeneity bounded) reproduce at the daily timescale? Reported
in a clearly-labelled exploratory section; no "equivalence established"
claims; posterior mass inside the derived ROPE reported descriptively.

## Sample

Diary subsample (US protocol): all diary responses with a valid outcome; no
minimum compliance filter (multilevel models handle unbalanced panels;
attrition is described, not trimmed). By intake country the 1,275 diary pids
are 1,185 US, 23 UK, 67 without an intake match; described precisely, not as
"US-only". 402 diary pids have no telemetry sessions at all; they are
RETAINED with zero exposure (mirrors the registered zero-play handling) and
the section discloses the count. Constraints on generality: US protocol,
first 30 study days, console/PC telemetry.

Positive-control status (run 2026-07-29, before any outcome model):
shooter-gender d = 0.259 raw / 0.438 log in the diary subsample, expected
direction. Control 2 passes; control 1 (played24hr vs telemetry) filled from
the pipeline marginals report.

## Outcomes

- PRIMARY: life_sat (Cantril ladder, "past 24 hours", 0-100 as collected).
- SECONDARY: affective_valence ("right now", 0-100, momentary). Reported in
  the same table; no headline claims rest on it.

## Exposure

- Window: [completion timestamp - 24 h, completion timestamp] per response,
  matching the primary outcome's reference frame. Sessions clipped to the
  window; Steam approximate sessions scaled by clipped share.
- total_hours_24h: console/PC (Nintendo, Xbox, Steam), no genre duplication.
- Genre hours: full attribution to each of the game's labels, identical to
  the wave pipeline; 14 study genres pinned to genre_wave_long.csv.
- Mobile is excluded (sub-day windows impossible with day-level aggregates);
  noted as a scope limit, mirroring registered D6 logic.

## SESOI transfer (the key prespecification)

The registered SESOI is 0.06 SWEMWBS item-mean points per hour/day. Transfer
to the 0-100 daily scales by matching the threshold's size in WITHIN-PERSON
SD units, computed on observed data before any model is fit:

  SESOI_daily(outcome) = 0.06 * s_w(outcome) / s_w(SWEMWBS)

where s_w = SD of person-demeaned observed values (pids with >= 2 obs),
computed on all diary responses (outcome property, not coverage-dependent);
SWEMWBS anchor computed on the registered analysis population (full sample).
Filled 2026-07-29 from the marginals report, BEFORE any fit:
- s_w(SWEMWBS)  = 0.360
- s_w(life_sat) = 12.742  -> SESOI_LS ~= 2.13 points per hour/day
- s_w(valence)  = 13.074  -> SESOI_AV ~= 2.18 points per hour/day
(2.13 is the fit script's full-precision value; the rounded report SDs give
2.12. The script is authoritative; prose prints the computed value.)
(The fit script recomputes these at full precision; the script is the source
of truth, these are the rounded audit values. r ~= 35.4, so prior scales:
b ~= student_t(3, 0, 17.7); tau ~= HN(0, 3.54); sigma_s ~= HN(0, 10.6).)
Sensitivity threshold (co-reported, not primary): range-proportional
transfer 0.06 * (100-0)/(5-1) = 1.5 points per hour/day for both outcomes.
Rationale: the SD-transfer preserves the threshold's meaning relative to how
much the outcome actually moves within persons; the range transfer assumes
interval equivalence across instruments. Divergence between the two is
reported honestly.

## Models (mirroring the registered set; fitted in this order)

All Bayesian (brms), 4 chains, seed 8675309, iter 4000 / warmup 2000 unless
escalation is needed for convergence (escalations documented). Within-between
decomposition at the response level: x_within = x - person mean(x);
x_between = person mean(x). Priors scale from the registered models by the
SESOI ratio r = SESOI_LS / 0.06 (same ratios, new scale):
- Intercept: student_t(3, 50, 25)            (midpoint + half-range logic)
- Coefficients: student_t(3, 0, 0.5 * r)
- M2 hyperpriors (tau_within, tau_between): half-normal(0, 0.1 * r)
- M3 mm sigma_s: half-normal(0, 0.3 * r)
- Residual sigma: brms default.

- M0-daily (H1-daily): life_sat ~ total_within + total_between +
  (1 + total_within | pid). Person-level random-slope SD reported as the
  susceptibility bound, as in the registered M0.
- M2-daily (H2-daily, hierarchical prior): 14 genre within + 14 between
  exposures with learned hyperprior scales tau_within, tau_between.
- M3-daily (H2-daily, multi-membership): mm() over the 14 genres with
  composition weights (uniform 1/K for zero-play responses, as registered),
  total_within + total_between fixed effects, genre random slopes; PRIMARY
  outcome only (compute control).
- Valence secondaries: M0-daily and M2-daily only.
- Lagged secondary (frequentist, lmer): life_sat_t ~ play in the 24 h window
  PRECEDING the primary window (t-1 exposure), within-between decomposed;
  reported as a direction check only.

## Positive controls (must pass before the models are interpreted)

1. played24hr self-report vs telemetry any-play in the window (agreement,
   phi; threshold-free description; also with >= 5 min telemetry threshold).
2. Shooter-gender d ~ 0.3 in the US diary subsample (biweekly pipeline).

## Missing data

Observed-data likelihood (ML/Bayes) on available responses; attrition
structure described in the section (responses per day, days per pid). No MI
for the exploratory pass: the person x day grid (1,275 x 30, ~42% observed)
is deferred, stated openly as a limitation. Wellbeing-missingness is not
conditioned on exposure anywhere.

## Pre-fit amendment (2026-07-29, after marginals, BEFORE any fit)

The marginals decomposed the 8,097 zero-exposure responses into 5,726
within-coverage zeros, 1,322 from 221 pids with no console/PC telemetry at
all, and 1,049 from windows wholly outside the pid's telemetry span. The
latter two classes are exposure measurement gaps, not observed non-play,
and misclassifying them as zeros biases within-person estimates toward the
null this section is designed to test fairly. Amendment:
- PRIMARY frame: responses with covered == TRUE (pid has telemetry AND the
  window overlaps the pid's telemetry span). Person-centring on this frame.
- SENSITIVITY: M0-daily refit on the full frame (all responses, zeros as-is),
  reported in one sentence.
- Kept registered-consistent and DISCLOSED, not changed: Steam session
  overlaps (24.4% of Steam sessions; max window total 20.4 h), ~7% of
  clipped minutes without genre labels (93.0% coverage vs 94.1% biweekly),
  full-attribution overshoot (median rowSums(gh)/total = 2.0), consecutive
  windows sharing sessions (34% of adjacent pairs), Nintendo 235 overlapping
  sessions (contradicts data paper claim; flag to Nick).
- Positive-control 1 read on marginals: played24hr vs telemetry any-play
  agreement 65.2%, phi = 0.355 (68.1% / 0.376 coverage-restricted);
  significant positive association -> passes; attenuation attributed to
  excluded mobile play (self=Yes with telemetry=0 dominates the
  disagreement). Control 2 passed (shooter d, see above).

## Interpretation rules (fixed now)

- H1-daily: report posterior mass of total_within / total_between inside
  [-SESOI_LS, +SESOI_LS]; language mirrors registered H1 but flagged
  exploratory; no "equivalence established" wording.
- H2-daily: heterogeneity parameters (tau_within, tau_between, sigma_s)
  against SESOI_LS as the benchmark band; per-genre coefficients reported
  in a caterpillar figure without individual interpretation (registered
  rule carried over).
- If daily results CONTRADICT the biweekly null (heterogeneity or dose
  effects above threshold), that is reported plainly; the section exists to
  test the measurement-resolution explanation, not to confirm it.

## Post-results amendments (2026-07-29 evening; POST-HOC, disclosed as such)

Two changes made AFTER the primary results were seen, on the author's
prompt to reconsider the thresholds. Neither changes any verdict (every
parameter was already inside all candidate regions before the change);
both are disclosed in the manuscript text.

1. THRESHOLD RECONSIDERATION.
   - life_sat: the SD-transfer (2.13/h) stays primary, but single-item
     measurement error inflates s_w relative to the 7-item SWEMWBS
     composite, making 2.13 the generous end of the defensible range. The
     range-proportional transfer (1.5/h) is now CO-REPORTED as the stricter
     benchmark; the section's table gives posterior shares under both.
   - affective_valence: equivalence benchmarking DROPPED entirely (was:
     SD-transfer 2.18). A momentary state measured hours after the exposure
     window has no defensible per-hour MID; valence is reported
     descriptively. The original prespecified transfer remains recorded
     above for the audit trail.

2. SAME-INSTRUMENT BRIDGE (author request). One additional fit: M0
   structure on BIWEEKLY life satisfaction (registered-style frame:
   full survey rows, zero-filled exposure, no coverage restriction, waves
   1-6), priors by the same ratio rule using s_w(biweekly life_sat).
   Purpose: the daily section otherwise changes instrument and grain
   together; the bridge holds the instrument constant so the daily-vs-
   biweekly difference is attributable to grain. Reported in ONE sentence;
   footprint deliberately minimal (author's density concern). The
   interpretation sentence is written only after the fit is seen.

3. PRIMARY BENCHMARK FLIPPED (2026-07-30, author decision). The
   leisure-anchored derivation is now PRIMARY: the registered logic (0.3-pt
   MID = 7.5% of scale range, over ~5 daily leisure hours) carried to the
   0-100 ladder gives 7.5 points MID -> 1.5 points per hour. The SD-transfer
   (2.13) is demoted to a sensitivity bound (single-item s_w inflation makes
   it permissive). Rationale: the conservative primary strengthens rather
   than flatters the null claim. Consequence disclosed: tau_between retains
   89.0% below the primary benchmark (98.5% below the SD bound). Dose
   inversions added to the section (MID/beta): within 35 h/day at the point
   estimate, 21 h/day at the favourable bound (> waking day); between 13
   and 6 h/day (> 5 leisure hours); guards pin all four. NOTE the framing
   boundary agreed with the author: the daily effect is immediate in
   direction but does NOT reach practical significance under any defensible
   benchmark; prose says "visible within a day, averaged away over two
   weeks", never "meaningful short-term effect".

4. SINGLE BENCHMARK + M1-DAILY (2026-07-30, author decisions). (a) The
   SD-transfer sensitivity bound is REMOVED from the manuscript entirely;
   the leisure-anchored 1.5/h is the sole equivalence benchmark. This plan
   remains the audit trail for the earlier constructions. Prior scales in
   R/fit_daily_models.R retain their original data-derived values (0.5 x r
   with r from the s_w ratio, ~17.7 for b); they are machinery, not
   benchmarks, and are weakly informative either way; no refits. (b) M1-daily
   (unpooled 28-coefficient fixed-effects specification, life_sat only,
   same prior family) ADDED for cross-grain consistency after the author
   queried its absence; result mirrors the biweekly signature: raw SD
   within 0.39 [0.24, 0.55] (noise-inflated vs tau_w 0.16), raw SD between
   2.28 [1.48, 3.21], exceeding the benchmark exactly as the biweekly M1
   between-SD exceeds the SESOI; reported with the registered caveat.
   (c) Daily summary table moved to Appendix E; model colours unified
   across all model-comparison figures (M1 blue #1f78b4, M2 orange
   #ff8c00, M3 purple #6a3d9a from the per-genre figure; M0 dark grey
   #4d4d4d after the author flagged steelblue as too close to M1's blue).
   (d) Round 2: M3's H1-daily fixed effects added to figure/prose/table
   (agree with M0); lowest-model-on-top ordering in all model figures;
   A5.2 rebuilt in A5.1's column scheme.

5. OUTCOME IDENTITY CORRECTED (2026-07-30). The daily `life_sat` item is
   NOT the Cantril ladder. The released codebook says "integer 0-10, Cantril
   Self-Anchoring Scale", but the data hold 101 distinct integer values
   0-100 (38.2% multiples of 10; granularity indistinguishable from
   `affective_valence`, 36.5%). The dataset authors confirmed (open-play
   issue #146) that the ladder was replaced for brevity by a simpler daily
   statement, "I was satisfied with my life today", on a 0-100 slider, and
   the codebook was not updated. Consequences applied here:
   - The outcome is described correctly in the manuscript, with the codebook
     discrepancy noted; no rescaling to ladder rungs (the ladder was never
     administered daily).
   - SESOI REDERIVED for a 0-100 daily slider: MID = 5 points, taken below
     both the distribution-based half-within-SD rule (6.4 points) and the
     registered MID expressed as a share of scale range (7.5 points);
     benchmark = 5 / 5 leisure hours = 1.0 points per hour. Supersedes the
     1.5 and 2.13 constructions above.
   - The BIWEEKLY life_sat item IS the Cantril ladder (0-10 integers).
     Its comparison model gets its own benchmark on that instrument:
     MID = 0.5 rungs (half the smallest expressible increment; 5% of range,
     matching the daily choice proportionally) over 5 leisure hours =
     0.1 rungs per hour.
   - The bridge is NO LONGER a "same-instrument" comparison: daily and
     biweekly differ in item, wording, and response format. It now varies
     construct at fixed grain (SWEMWBS vs life satisfaction) and is
     described that way; it cannot isolate response format.
   - VALENCE REMOVED entirely (author decision): fits deleted from
     R/fit_daily_models.R, all rows/prose/guards removed. The cached
     m0_daily_av / m2_daily_av fits remain on disk but are unreported.
     Retained as a limitation: the daily outcome correlates r = .87 with the
     valence slider (.68 within persons), so it is affect-laden.
   - Consequence of the stricter benchmark, disclosed in text: M0's
     between-person posterior is 90.8% inside (not "almost entirely"), and
     M2's tau_between straddles it (62.1% below), so daily between-person
     genre heterogeneity is reported as inconclusive.

## Out of scope (recorded so scope creep is visible)

BPNSFS/BANGS needs, sleep, stressors, social context, displacement items;
time-use diary covariates; mobile platforms; MI; AR(1)/full dynamic models;
biweekly life_sat bridge (flagged as candidate follow-up, not run here).
