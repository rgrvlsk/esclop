# SPDX-License-Identifier: GPL-3.0-or-later
# One entry point for contributors; every target is a thin wrapper around a script or tool.
# `make help` lists them.

.PHONY: help build test engine engine-check tools icons bundle gate release-dry-run lint clean

help: ## list the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

build: ## swift build (CLI, MCP server, libraries; the app too when Xcode is installed)
	swift build

test: ## swift test, with the Command Line Tools workaround when needed
	Scripts/test.sh

engine: ## esclop-engine, universal, into Binaries/
	Scripts/build-engine.sh

engine-check: ## rustfmt, clippy, tests and cargo-deny for the engine (against the pinned libaom, as CI)
	cd engine && cargo fmt --all --check
	eval "$$(Scripts/build-libaom.sh --env)" && cd engine && \
		cargo clippy --locked --all-targets -- -D warnings && \
		cargo test --locked
	cd engine && cargo deny --locked check

tools: ## ffmpeg, ffprobe, gs and gifsicle from pinned source into Binaries/ (cached)
	Scripts/build-tools.sh

icons: ## regenerate the app icon and the menu bar glyph from assets/ (macOS, librsvg required)
	Scripts/build-icons.sh

bundle: ## dist/L'Esclop.app (skipped when the app product is absent)
	Scripts/bundle-app.sh

gate: ## licence gate over Binaries/, after its own tests
	Scripts/licence-gate-test.sh
	Scripts/licence-gate.sh --universal Binaries

release-dry-run: tools engine ## every release artefact into dist/, unsigned, no GitHub release
	Scripts/package-release.sh --dry-run

lint: ## actionlint on the workflows
	actionlint

clean: ## remove dist/ (Binaries/ and its cache are kept)
	rm -rf dist
