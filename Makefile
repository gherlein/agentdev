# agentdev — task runner. agentdev itself is bash (nothing to compile); these
# targets build the container image, run tests, lint, and install the launcher.

IMAGE      ?= ghcr.io/gherlein/agentdev:latest
GO_VERSION ?= 1.25.0
PREFIX     ?= $(HOME)/.local
BINDIR     := $(PREFIX)/bin

SHELLS  := agentdev $(wildcard lib/*.sh) image/entrypoint.sh scripts/release.sh tests/smoke.sh tests/live.sh tests/live-agent.sh tests/live-containment.sh
PYFILES := lib/jsoncfg.py image/proxy.py tests/matrix.py tests/test_proxy.py

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: build
build: ## Build the container image (IMAGE, GO_VERSION overridable)
	podman build --format docker --build-arg GO_VERSION=$(GO_VERSION) \
	  -t $(IMAGE) -f image/Containerfile image/

.PHONY: push
push: ## Push IMAGE to its registry (run `podman login ghcr.io` first)
	podman push $(IMAGE)

.PHONY: digest
digest: ## Print IMAGE's pin-by-digest reference (set it as the default IMAGE)
	@podman inspect --format '{{index .RepoDigests 0}}' $(IMAGE)

.PHONY: test
test: ## Run the offline suite: smoke + option-permutation matrix (docs/testing-plan.md)
	./tests/smoke.sh
	python3 ./tests/matrix.py

.PHONY: run-tests
run-tests: test ## Alias for `test` (the default offline suite; CI entrypoint)

.PHONY: matrix
matrix: ## Run just the config-permutation matrix (offline, dry-run based)
	python3 ./tests/matrix.py

.PHONY: test-live
test-live: ## Tier B: launch real containers to verify enforcement (needs podman + image)
	./tests/live.sh

.PHONY: test-live-agent
test-live-agent: ## Tier C: drive a real agent to verify agent-home persistence (host claude login or ANTHROPIC_API_KEY; real model cost)
	./tests/live-agent.sh

.PHONY: test-live-containment
test-live-containment: ## Tier D: boot a real agent from copied ~/.claude creds and prove it cannot escape (real model cost)
	./tests/live-containment.sh

.PHONY: lint
lint: ## Syntax-check shell + python (uses shellcheck if installed)
	@for f in $(SHELLS); do bash -n "$$f" && echo "ok  $$f"; done
	@python3 -m py_compile $(PYFILES) && echo "ok  $(PYFILES)"
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning $(SHELLS) || echo "note: shellcheck not installed, skipped"

.PHONY: install
install: ## Symlink the launcher into PREFIX/bin (default ~/.local/bin)
	@mkdir -p "$(BINDIR)"
	ln -sfn "$(CURDIR)/agentdev" "$(BINDIR)/agentdev"
	@echo "linked $(BINDIR)/agentdev -> $(CURDIR)/agentdev"

.PHONY: uninstall
uninstall: ## Remove the symlink from PREFIX/bin
	rm -f "$(BINDIR)/agentdev"

.PHONY: release
release: ## Tag vVERSION and open a Homebrew tap PR (VERSION=X.Y.Z; needs gh). Prompts before pushing.
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=X.Y.Z"; exit 1; }
	./scripts/release.sh "$(VERSION)"

.PHONY: release-dry
release-dry: ## Preview the release: run checks + render the formula, no tag/push/PR (VERSION=X.Y.Z)
	@test -n "$(VERSION)" || { echo "usage: make release-dry VERSION=X.Y.Z"; exit 1; }
	./scripts/release.sh --dry-run "$(VERSION)"

.PHONY: clean
clean: ## Remove local build/test cruft (pycache); image is left intact
	rm -rf lib/__pycache__

.PHONY: image-clean
image-clean: ## Remove the built container image
	-podman rmi $(IMAGE)
