CHART_DIR := hippo-service
CHART_VERSION := $(shell grep '^version:' $(CHART_DIR)/Chart.yaml | awk '{print $$2}')

# ── Targets ────────────────────────────────────────────────
.PHONY: help lint template render test validate-schema package

help:
	@echo "Usage:"
	@echo "  make lint            Lint the Helm chart"
	@echo "  make template        Render templates with default values"
	@echo "  make render ONE=<f>  Render a single test values file"
	@echo "  make test            Render all test value files and validate YAML"
	@echo "  make validate-schema Validate values.schema.json"
	@echo "  make package         Package the chart as a .tgz"

lint:
	helm lint $(CHART_DIR)/

template:
	helm template hippo-release $(CHART_DIR)/ \
	  --values $(CHART_DIR)/values.yaml

render:
	@if [ -z "$(ONE)" ]; then echo "Usage: make render ONE=tests/values/service-api-simple.yml"; exit 1; fi
	helm template hippo-release $(CHART_DIR)/ \
	  --values $(CHART_DIR)/values.yaml \
	  --values $(ONE)

test:
	@echo "Rendering all test value files..."
	@for f in tests/values/*.yml; do \
	  echo "  → $$f"; \
	  helm template hippo-release $(CHART_DIR)/ \
	    --values $(CHART_DIR)/values.yaml \
	    --values $$f > /dev/null || exit 1; \
	done
	@echo "All test renders passed."

validate-schema:
	@python3 -c "import json; json.load(open('$(CHART_DIR)/values.schema.json'))" && \
	  echo "values.schema.json is valid JSON"

package:
	helm package $(CHART_DIR)/ --destination dist/
