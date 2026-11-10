# Releasing

1. Move the `## [Unreleased]` entries of `CHANGELOG.md` under `## [X.Y.Z] - YYYY-MM-DD` and set
   `EsclopVersion.string` (`Sources/EsclopIPC/Protocol.swift`) to `X.Y.Z`. Merge to main.
2. `make release-dry-run` locally, or run the `release` workflow by hand (workflow_dispatch):
   the same artefacts, no release.
3. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`. `release.yml` builds everything
   universal, runs the licence gate, packages and opens a **draft** release. Review it and
   publish it by hand.
4. Publishing it starts `release.yml`'s feed job, which signs the DMG and offers it to installed
   apps (Updates, below). Check the job's notice: it names the build the feed now offers.

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
`Scripts/bundle-app.sh` builds with the Swift Build engine and refuses an app whose resource
accessor only looks in the build directory, and `Scripts/smoke-app.sh` starts the bundled app
from a copy with the build directory moved away; CI and the release workflow both run it.
Packaging rejects binaries containing home-directory paths, even after stripping. SwiftPM can
write its build directory into a binary, so the release workflow builds in
`ESCLOP_SCRATCH_PATH` (`/private/tmp/esclop-build`), which every packaging script honours. Build
release binaries from a neutral directory such as `/tmp/esclop-build` and check them before
signing. Rust source locations are also remapped by `Scripts/build-engine.sh`.

`release.yml` reads the repository secrets `MACOS_CERTIFICATE` (base64 of a Developer ID
Application `.p12`), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and
`APPLE_APP_PASSWORD`. Without the first two everything is signed ad hoc; without the last three
nothing is notarised. Locally, `ESCLOP_SIGN_IDENTITY` and `ESCLOP_NOTARY_PROFILE` (a
`notarytool store-credentials` profile) do the same for `Scripts/package-release.sh` and
`Scripts/bundle-app.sh`.

## Updates

Installed apps update themselves with [Sparkle](https://sparkle-project.org) 2 (MIT, a SwiftPM
dependency; `Sparkle.framework` with its helpers and XPC services sits in
`Contents/Frameworks`). No Apple Developer account is involved.

**Feed.** `https://raw.githubusercontent.com/rgrvlsk/esclop/appcast/appcast.xml`: the file
`appcast.xml` on the `appcast` branch, which holds nothing else. The address never changes,
whatever the releases are. GitHub's `releases/latest/download/…` was not used because it skips
pre-releases, and ours are pre-releases for now; a Pages site would need the repository's Pages
switched on for one file. When a release is published (pre-release or not), `release.yml`'s
feed job downloads its DMG, signs it, writes the appcast with `Scripts/appcast.sh` (version,
build, size, EdDSA signature, minimum macOS, and the release's `CHANGELOG.md` section as
Markdown notes), signs the appcast itself and commits it to the branch. It never goes back: a
release whose build is not newer than the one offered leaves the feed as it is. The appcast
lists only the newest release. A beta channel later is the same file with
`<sparkle:channel>beta</sparkle:channel>` on beta items and an "Include betas" setting that
returns `["beta"]` from `SPUUpdaterDelegate.allowedChannels(for:)`.

Sparkle compares `CFBundleVersion`, which is the release workflow's run number, so a new tag
always has a higher build than the last.

**Keys.** The DMG and the appcast are signed with an EdDSA (Ed25519) key. Its public half is
`SPARKLE_PUBLIC_KEY` in `Scripts/bundle-app.sh`, written into `Info.plist` as `SUPublicEDKey`. The
private half is the repository secret `SPARKLE_ED_PRIVATE_KEY`, and its only backup is the login
keychain of the Mac that made it (Sparkle's `generate_keys --account esclop`, item "Private key
for signing Sparkle updates"). Lose both and installed apps can no longer be updated: they
reject anything not signed with that key. To sign by hand on that Mac:
`Scripts/appcast.sh DMG URL appcast.xml` without the variable uses the keychain. To restore the
secret: `generate_keys --account esclop -x key.txt`, `gh secret set SPARKLE_ED_PRIVATE_KEY <
key.txt`, then delete `key.txt`.

**Ad hoc signing.** Sparkle accepts an update when its EdDSA signature matches the public key of
the installed app, or when both apps carry the same Apple code signing identity
(`SUUpdateValidator`). An ad hoc signature names no identity and changes with every build, so
the second never holds for us and the EdDSA check carries the trust. Sparkle still insists that
an update of a signed app is itself validly signed, and ad hoc counts, so `bundle-app.sh`
re-signs Sparkle's nested code inside out and the whole bundle; with a Developer ID later the
same code signs with it. The installer swaps the bundle atomically when the update has no team
identifier, which an ad hoc app never has. Sparkle 2.10's own binaries are ad hoc signed too.

**Quarantine.** The first copy of the app, downloaded in a browser, is quarantined, and macOS
asks once for "Open Anyway". Sparkle downloads updates itself and removes the quarantine
attribute from the new app before moving it in place (`SUPlainInstaller`), so an update opens
without asking again. Sparkle refuses to update an app running from the DMG (a read-only volume)
or translocated by macOS (opened from where it was downloaded without being moved): it says so
and asks to move the app to Applications first.

**Settings.** "Check for updates automatically" (`checkForUpdatesAutomatically`, on) and
"Download and install updates automatically" (`installUpdatesAutomatically`, off) in Settings ›
General › Updates set Sparkle's own switches, and the box in Sparkle's update window sets them
back. Because the app sets them, Sparkle never asks for permission, and the first check runs at
the first launch; it sends no system profile. "Check for Updates…" in the menu checks at once.

**Testing.** `ESCLOP_UPDATE_FEED=<url>`, read when the app starts, replaces the feed.
`Scripts/update-e2e.sh "dist/L'Esclop.app"` makes build 1 and build 2 of a bundled app with a
throwaway key, a DMG and a signed appcast of build 2 on `127.0.0.1`, starts build 1 with
automatic installation on, and checks that the bundle on disk becomes build 2, validly signed,
without quarantine, and starts. CI runs it after the smoke test ("app bundle starts on its own").
It starts the real app as the current user, so elsewhere it needs `ESCLOP_SMOKE_HERE=1`.

## Licence gate

`Scripts/licence-gate.sh [--dist] [--universal] [--max-mb N] DIR` fails when a Mach-O file
under `DIR` has no record, when a record's licence is outside `engine/deny.toml`'s allowlist,
when a licence text is missing from `LICENSES/`, when the engine notices are stale, or when a
binary links a library outside the system. A framework in `Contents/Frameworks` (Sparkle) must
come from a `Package.resolved` pin of the same name, whose licence is checked in
`LICENSES/swift-packages.md`; links to it are not foreign. `Scripts/licence-gate-test.sh` is its
test.
