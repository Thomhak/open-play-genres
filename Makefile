# Download Open Play v1.1.0 from Zenodo
# Source: https://zenodo.org/records/18430947
ZENODO_URL := https://zenodo.org/records/18430947/files/open-play-v1.1.0.zip
DATA_DIR := data/clean
ZIP_FILE := open-play-v1.1.0.zip

.PHONY: all data clean list

all: data

data: $(DATA_DIR)/survey_biweekly.csv.gz

$(DATA_DIR)/survey_biweekly.csv.gz:
	@mkdir -p $(DATA_DIR)
	@echo "Downloading Open Play v1.1.0 from Zenodo (~194MB)..."
	@wget -q -O $(ZIP_FILE) "$(ZENODO_URL)"
	@echo "Extracting clean data files..."
	@unzip -q $(ZIP_FILE) "open-play-v1.1.0/data/clean/*" -d .
	@cp open-play-v1.1.0/data/clean/*.csv.gz $(DATA_DIR)/
	@rm -rf open-play-v1.1.0/ $(ZIP_FILE)
	@echo "Done. Data files available in $(DATA_DIR)/"

clean:
	@rm -f $(DATA_DIR)/*.csv.gz
	@echo "Data files removed."

list:
	@ls -lh $(DATA_DIR)/*.csv.gz 2>/dev/null || echo "No data files downloaded yet. Run: make data"
