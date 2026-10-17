# Download Open Play v1.2.6 from Zenodo
# Source: https://zenodo.org/records/22811439 (DOI 10.5281/zenodo.22811439)
# Relative to v1.2.1 (record 20119134, used for the first round of model fits),
# the telemetry files and game_metadata.csv.gz are byte-identical; the survey
# files changed: survey_intake.csv.gz drops 2,324 ineligible rows and the
# v1.2.4 fix revokes the 'qualified' flag for 306 intakes, and survey_daily
# changed (rows added/removed, some dates and life_sat values corrected).
# The analytic sample is restricted to intake 'qualified' == TRUE
# (analytic_pids() in R/01_preprocess.R).
#
# NOTE: releases >= v1.2.5 dropped ideal_baseline_day (and baseline_day,
# original_wave, derived_wave, n_valid, delta_days_final) from
# survey_biweekly.csv.gz. The per-participant baseline used for telemetry wave
# assignment is supplied by data/reference/baseline_days.csv, written once from
# the v1.2.1 biweekly file by R/00_baseline_days.R (values identical to v1.2.1).
ZENODO_URL := https://zenodo.org/api/records/22811439/files/digital-wellbeing/open-play-v1.2.6.zip/content
DATA_DIR := data/clean
ZIP_FILE := open-play-v1.2.6.zip
EXTRACT_DIR := open-play-v1.2.6-extract

.PHONY: all data clean list

all: data

data: $(DATA_DIR)/survey_biweekly.csv.gz

$(DATA_DIR)/survey_biweekly.csv.gz:
	@mkdir -p $(DATA_DIR)
	@echo "Downloading Open Play v1.2.6 from Zenodo (~197MB)..."
	@curl -sL -o $(ZIP_FILE) "$(ZENODO_URL)"
	@echo "Extracting clean data files..."
	@unzip -q -o $(ZIP_FILE) "*/data/clean/*.csv.gz" -d $(EXTRACT_DIR)
	@find $(EXTRACT_DIR) -path "*/data/clean/*.csv.gz" -exec cp {} $(DATA_DIR)/ \;
	@rm -rf $(EXTRACT_DIR) $(ZIP_FILE)
	@echo "Done. Data files available in $(DATA_DIR)/"

clean:
	@rm -f $(DATA_DIR)/*.csv.gz
	@echo "Data files removed."

list:
	@ls -lh $(DATA_DIR)/*.csv.gz 2>/dev/null || echo "No data files downloaded yet. Run: make data"
