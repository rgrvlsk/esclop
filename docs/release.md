# Releasing

1. Move the `## [Unreleased]` entries of `CHANGELOG.md` under `## [X.Y.Z] - YYYY-MM-DD` and set
   `EsclopVersion.string` (`Sources/EsclopIPC/Protocol.swift`) to `X.Y.Z`. Merge to main.
2. `make release-dry-run` locally, or run the `release` workflow by hand (workflow_dispatch):
   the same artefacts, no release.
3. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`. `release.yml` builds everything
   universal, runs the licence gate, packages and opens a **draft** release. Review it and
   publish it by hand.

## What a release carries

| File | Contents |
| --- | --- |
| `esclop-X.Y.Z-cli.tar.gz` | `bin/esclop`, `libexec/esclop/` (ffmpeg, ffprobe, gs, gifsicle, esclop-engine), `LICENSES/`, `THIRD_PARTY.md` |
| `esclop-X.Y.Z-source.tar.zst` | `git archive` of the tag |
| `esclop-swift-X.Y.Z-vendor.tar.zst` | SwiftPM dependency sources at the revisions in `Package.resolved` |
| `esclop-engine-X.Y.Z-vendor.tar.zst` | `cargo vendor` of `engine/Cargo.lock`, with the `.cargo/config.toml` that uses it |
| `third-party-src-X.Y.Z.tar.zst` | the upstream tarballs recorded in `THIRD_PARTY.md` (matched by SHA-256), `Binaries/patches/`, `Scripts/build-tools.sh` |
| `SHA256SUMS` | checksums of the above |

Releases must provide complete corresponding source, including SwiftPM dependencies,
vendored Rust crates and upstream tool sources. The menu bar app ships as
`LEsclop-X.Y.Z.dmg`, built by `release.yml` when `SHIP_APP` is `"true"`; with `"false"`,
`Scripts/bundle-app.sh` runs as a smoke test only. Without the signing secrets the app is signed
ad hoc and not notarised, and the release notes say how to open it.

## Signing and notarisation

Real releases require a clean working tree at the release tag. `--skip-vendor` is restricted
to dry runs. Existing release assets can be replaced only while the release is still a draft.
Packaging rejects binaries containing home-directory paths, even after stripping. Build
release binaries from a neutral directory such as `/tmp/esclop-build` and check them before
signing. Rust source locations are also remapped by `Scripts/build-engine.sh`.

`release.yml` reads the repository secrets `MACOS_CERTIFICATE` (base64 of a Developer ID
Application `.p12`), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and
`APPLE_APP_PASSWORD`. Without the first two everything is signed ad hoc; without the last three
nothing is notarised. Locally, `ESCLOP_SIGN_IDENTITY` and `ESCLOP_NOTARY_PROFILE` (a
`notarytool store-credentials` profile) do the same for `Scripts/package-release.sh` and
`Scripts/bundle-app.sh`.

## Licence gate

`Scripts/licence-gate.sh [--dist] [--universal] [--max-mb N] DIR` fails when a Mach-O file
under `DIR` has no record, when a record's licence is outside `engine/deny.toml`'s allowlist,
when a licence text is missing from `LICENSES/`, when the engine notices are stale, or when a
binary links a library outside the system. `Scripts/licence-gate-test.sh` is its test.
