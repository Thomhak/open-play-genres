# Download Open Play v1.3.0 from Zenodo
# Source: https://zenodo.org/records/23419571 (DOI 10.5281/zenodo.23419571)
# v1.3.0 (16 Oct 2026) re-keyed survey and console records to each
# participant's canonical identifier, corrected the intake 'qualified' flag and
# removed duplicate sign-ups (open-play release notes; backend PR #10). The
# analytic sample is the set of participants with 'qualified' == TRUE in
# survey_intake.csv.gz and at least one valid SWEMWBS in biweekly waves 1-6
# (analytic_pids() in R/01_preprocess.R).
#
# NOTE: releases >= v1.2.5 do not ship ideal_baseline_day in
# survey_biweekly.csv.gz. The per-participant baseline used for telemetry wave
# assignment is rebuilt by R/00_baseline_days.R from the release's own raw
# biweekly file (data/raw/survey_biweekly_raw.csv.gz, extracted below) with the
# release's data-process.qmd rule, and written to data/reference/baseline_days.csv.
ZENODO_URL := https://zenodo.org/api/records/23419571/files/digital-wellbeing/open-play-v1.3.0.zip/content
DATA_DIR := data/clean
RAW_DIR := data/raw
ZIP_FILE := open-play-v1.3.0.zip
EXTRACT_DIR := open-play-v1.3.0-extract

.PHONY: all data clean list

all: data

data: $(DATA_DIR)/survey_biweekly.csv.gz

$(DATA_DIR)/survey_biweekly.csv.gz:
	@mkdir -p $(DATA_DIR) $(RAW_DIR)
	@echo "Downloading Open Play v1.3.0 from Zenodo (~200MB)..."
	@curl -sL -o $(ZIP_FILE) "$(ZENODO_URL)"
	@echo "Extracting clean data files and the raw biweekly survey..."
	@unzip -q -o $(ZIP_FILE) "*/data/clean/*.csv.gz" "*/data/raw/survey_biweekly_raw.csv.gz" -d $(EXTRACT_DIR)
	@find $(EXTRACT_DIR) -path "*/data/clean/*.csv.gz" -exec cp {} $(DATA_DIR)/ \;
	@find $(EXTRACT_DIR) -path "*/data/raw/survey_biweekly_raw.csv.gz" -exec cp {} $(RAW_DIR)/ \;
	@rm -rf $(EXTRACT_DIR) $(ZIP_FILE)
	@echo "Done. Clean files in $(DATA_DIR)/, raw biweekly in $(RAW_DIR)/. Next: Rscript R/00_baseline_days.R"

clean:
	@rm -f $(DATA_DIR)/*.csv.gz $(RAW_DIR)/survey_biweekly_raw.csv.gz
	@echo "Data files removed."

list:
	@ls -lh $(DATA_DIR)/*.csv.gz 2>/dev/null || echo "No data files downloaded yet. Run: make data"
