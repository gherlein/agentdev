# scorer - runs INSIDE a network-less agentdev container, mounted read-only at /scorer.
# The frozen acceptance suite is at /anchor (read-only) and is never placed in a
# candidate's workspace, so scoring is a true external check.
#
#   make -f /scorer/Makefile reference OUT=/out           build the known-good pngdec
#   make -f /scorer/Makefile anchor BIN=/abs/pngdec OUT=/out/anchor.json

ANCHOR    ?= /anchor
REFERENCE ?= /reference
OUT       ?= /out
# Always an absolute path: go test runs from $(ANCHOR), so a relative binary path
# would resolve against the wrong directory and every subprocess test would error.
BIN       ?= $(OUT)/pngdec

export GOTOOLCHAIN := local
export GOFLAGS     := -count=1

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show the targets
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: reference
reference: ## Build the reference pngdec into OUT (proves the suite)
	go build -C $(REFERENCE) -o $(OUT)/pngdec .

.PHONY: anchor
anchor: ## Run the frozen suite against BIN; go test -json events to OUT/anchor.json
	@case "$(BIN)" in /*) ;; *) echo "BIN must be absolute: $(BIN)" >&2; exit 2;; esac
	@test -x "$(BIN)" || { echo "no executable binary at $(BIN)" >&2; exit 2; }
	cd $(ANCHOR) && PNGDEC_BIN=$(BIN) go test -json . > $(OUT)/anchor.json || true

# Required targets (makefile-builds convention). There is nothing to build or clean
# here; the scorer runs in a throwaway container.
.PHONY: build test run-tests clean
build: reference ## Alias: build the reference binary
test: anchor ## Alias: score BIN
run-tests: test ## Alias for test
clean: ## Remove scoring output in OUT
	rm -f $(OUT)/pngdec $(OUT)/anchor.json
