# Download Open Play v1.2.1 from Zenodo
# Source: https://zenodo.org/records/20119134 (DOI 10.5281/zenodo.20119134)
# v1.2.1 is the newest release whose nine input files (telemetry, game
# metadata, biweekly/daily/intake surveys) are byte-identical to v1.1.0, the
# version the cached model fits were produced from. Later releases (>= v1.2.2)
# change the survey files, so bumping this version requires refitting the models.
ZENODO_URL := https://zenodo.org/api/records/20119134/files/digital-wellbeing/open-play-v1.2.1.zip/content
DATA_DIR := data/clean
ZIP_FILE := open-play-v1.2.1.zip
EXTRACT_DIR := open-play-v1.2.1-extract

.PHONY: all data clean list

all: data

data: $(DATA_DIR)/survey_biweekly.csv.gz

$(DATA_DIR)/survey_biweekly.csv.gz:
	@mkdir -p $(DATA_DIR)
	@echo "Downloading Open Play v1.2.1 from Zenodo (~197MB)..."
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
