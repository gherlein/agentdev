# agentdev — task runner. agentdev itself is bash (nothing to compile); these
# targets build the container image, run tests, lint, and install the launcher.

IMAGE      ?= ghcr.io/gherlein/agentdev:latest
GO_VERSION ?= 1.25.0
PREFIX     ?= $(HOME)/.local
BINDIR     := $(PREFIX)/bin

SHELLS  := agentdev $(wildcard lib/*.sh) image/entrypoint.sh tests/smoke.sh
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

.PHONY: matrix
matrix: ## Run just the profile-option permutation matrix (offline, dry-run based)
	python3 ./tests/matrix.py

.PHONY: test-live
test-live: ## Tier B: launch real containers to verify enforcement (needs podman + image)
	./tests/live.sh

.PHONY: lint
lint: ## Syntax-check shell + python (uses shellcheck if installed)
	@for f in $(SHELLS); do bash -n "$$f" && echo "ok  $$f"; done
	@python3 -m py_compile $(PYFILES) && echo "ok  $(PYFILES)"
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning $(SHELLS) || echo "note: shellcheck not installed, skipped"

.PHONY: doctor
doctor: ## Run the environment check
	./agentdev doctor

.PHONY: install
install: ## Symlink the launcher into PREFIX/bin (default ~/.local/bin)
	@mkdir -p "$(BINDIR)"
	ln -sfn "$(CURDIR)/agentdev" "$(BINDIR)/agentdev"
	@echo "linked $(BINDIR)/agentdev -> $(CURDIR)/agentdev"

.PHONY: uninstall
uninstall: ## Remove the symlink from PREFIX/bin
	rm -f "$(BINDIR)/agentdev"

.PHONY: clean
clean: ## Remove local build/test cruft (pycache); image is left intact
	rm -rf lib/__pycache__

.PHONY: image-clean
image-clean: ## Remove the built container image
	-podman rmi $(IMAGE)
