# Contributing

## Build
`make help` lists the common targets; each is a thin wrapper around the commands below.
```
swift build                 # make build: CLI and libraries; includes the app when enabled
Scripts/test.sh             # make test: swift test, with a workaround for Command Line Tools only
ESCLOP_TEST_TIMEOUT=300 Scripts/test.sh   # as CI: a hang fails with the unfinished tests and stacks
Scripts/build-tools.sh      # make tools: ffmpeg, gs, gifsicle from pinned source into Binaries/ (not committed)
Scripts/build-engine.sh     # make engine: esclop-engine, universal, into Binaries/
Scripts/bundle-app.sh       # make bundle: dist/L'Esclop.app (needs Xcode for the app target)
Scripts/licence-gate.sh Binaries   # make gate: every bundled Mach-O has a licence record
Scripts/package-release.sh --dry-run   # make release-dry-run: every release artefact into dist/
```
Record user-visible changes under `## [Unreleased]` in `CHANGELOG.md`.

## Rules for every change
1. GPL-3.0-or-later. New source files include an SPDX header in the language's comment syntax,
   for example `// SPDX-License-Identifier: GPL-3.0-or-later` in Swift.
2. Code derived from Clop keeps its copyright and gets a header naming the source file and the
   changes, and an entry in `docs/ATTRIBUTION.md`. Clop's name, bundle id, icon, images,
   website text and keys are never copied.
3. No personal data in the repository: no home paths, user names, emails, hostnames, device
   names, API keys or screenshots that show them. Use `~` or `$HOME` in docs and fixtures.
   Use your public GitHub handle and GitHub-provided `noreply` email for commits. Run
   `python3 Scripts/privacy-check.py` and `gitleaks git --redact` before pushing.
4. Tests for logic (parsers, size math, settings, IPC payloads). Fixtures are tiny generated
   files, never personal media.
5. `swift build` and `swift test` pass before a PR. UI changes include screenshots in light
   and dark appearance with any personal data cropped out.
6. Module dependencies only point downward (see `docs/ARCHITECTURE.md`). Changes to
   `Sources/EsclopCore/Contracts.swift` are additive unless maintainers agree on a migration.
7. Commit messages: imperative subject under 72 characters, body says why.
