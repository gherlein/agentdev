# factory-test - the pngdec software-factory benchmark, run through agentdev.
# Everything executes in agentdev containers; the host needs only podman, python3 and git.

LABEL ?=
RUN   ?=

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: selftest
selftest: ## Prove the scorer: the reference passes every case, a fake binary does not
	./factory.sh selftest

.PHONY: run
run: ## One full pipeline run, then score it (LABEL=name optional)
	./factory.sh run $(LABEL)

.PHONY: score
score: ## Re-build and re-score an existing run (RUN=runs/<id>)
	@test -n "$(RUN)" || { echo "usage: make score RUN=runs/<id>"; exit 2; }
	./factory.sh score $(RUN)

.PHONY: results
results: ## Markdown table of every run under runs/
	./factory.sh results

# Required targets (makefile-builds convention). There is nothing to compile here: the
# candidate is built inside the run's sandbox container.
.PHONY: build test run-tests clean
build: ## Check the harness scripts parse
	bash -n factory.sh
	python3 -m py_compile lib/anchor_score.py lib/results.py
test: selftest ## Alias for selftest
run-tests: test ## Alias for test
clean: ## Remove python caches (runs/ is kept; delete runs yourself)
	rm -rf lib/__pycache__
