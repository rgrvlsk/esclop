# Architecture

esclop is one SwiftPM package with two executables and five libraries. Modules only depend
downward. `EsclopCore/Contracts.swift` defines shared types. The menu bar app is
`EsclopApp` (the entry point) over `EsclopAppKit` (everything else, so tests reach it).

```
EsclopApp → EsclopAppKit         esclop (CLI, `esclop mcp serve`)
    │                                 │
    ├── EsclopMCP (EsclopService) ◄───┤      shared service layer
    ├── EsclopIPC ◄───────────────────┤      app <-> CLI message ports
    ├── EsclopPipelines ◄─────────────┤      pipeline model, DSL, executor
    │        │                        ├── EsclopMCP   tools, resources, installers
    │        ▼                        │
    └── EsclopOptimisers ◄────────────┘      image / video / pdf / audio / gif engines
             │
             ▼
         EsclopCore      models, errors, settings registry, process runner, binary locator, log
```

## Modules

### EsclopCore
- `Contracts.swift`: `MediaKind`, `OutputFormat`, `CompressionQuality`, `CropSize`,
  `OutputLocation`, `OptimisationRequest`, `OptimisationResult`, `EsclopError`,
  `OptimisationEngine`.
- `Settings`: a declarative registry. Each setting has a key, type, default, title, description
  and a JSON schema fragment. The registry supports the planned Settings window search, the CLI
  `esclop settings` and the MCP `settings_schema` tool. Storage is `UserDefaults` in the app's
  suite; the CLI and MCP read and write the same suite.
- `Tools`: finds bundled binaries (`<bundle>/Contents/Resources/bin`, or `$ESCLOP_BIN`, or
  `Binaries/` in a dev checkout, then PATH). Exposes `Tool.ffmpeg.url` etc. and a `Process`
  runner with cancellation, stderr capture and progress parsing hooks.
- `Backups`: backup folder management (`~/Library/Application Support/esclop/backups`),
  `.esclop` xattr marking of already-optimised files.
- `Log`: `os.Logger` wrappers with one subsystem.

### EsclopOptimisers
One `Engine` per `MediaKind` behind `OptimisationEngine`. The Swift side orchestrates; the
pixel work happens in `esclop-engine` (Rust) or in system frameworks:
- Image: `esclop-engine` over the protocol in `docs/engine-protocol.md` (PNG via imagequant +
  oxipng, JPEG via mozjpeg, WebP, AVIF via libaom/libavif, resize, crop, metadata, fit-under-size).
  ImageIO for HEIC, JPEG XL decode and HDR gain maps. Vision saliency for smart crop hints.
  gifsicle (separate process) for GIF optimisation; gifski inside the engine for video to GIF.
- Video: ffmpeg built without x264/x265, using `h264_videotoolbox`/`hevc_videotoolbox`,
  `libsvtav1`, `libvpx`; speed, mute, cap fps, lower bitrate. Fit-under-size searches bitrate
  and resolution with VideoToolbox and falls back to AV1 when needed.
- PDF: Ghostscript with `-dSAFER` and adaptive DPI stops (300, 250, 200, 150, 100, 72, 48);
  crop-pdf and uncrop; extract pages as images. A Rust replacement is a possible later change.
- Audio: ffmpeg with `aac_at`, libopus, libmp3lame; cover art compression, loudness
  normalisation.
- `Clipboard`: NSPasteboard reading and writing of images, file URLs, base64, paths.

### engine/ (Rust, `esclop-engine`)
Cargo workspace. One binary, JSON-lines protocol on stdio (`docs/engine-protocol.md`).
`cargo-deny` enforces the licence allowlist; `cargo about` generates the notices. Built
universal with `lipo` and placed in `Contents/Resources/bin`.

### EsclopPipelines
- `Pipeline` model: name, hotkey, triggers (clipboard, drop zone, preset zone, folder, right
  click, CLI, MCP), per-media-kind step lists.
- Text DSL compatible with Clop's pipeline language so existing pipelines migrate:
  `optimise(...)`, `downscale(factor:)`, `convert(to:)`, `crop(...)`, `targetSize(bytes:)`,
  `stripExif`, `watermark(...)`, `copy/move/rename/delete`, `filterIf/filterIfNot`,
  `removeAudio`, `changeSpeed`, `capFps`, `normalize(lufs:)`, `runScript`, `runShortcut`,
  `copyToClipboard`, `fork`, `shelveWith`, `uploadWith`, `openWith`.
- Executor: runs steps on an engine, tracks the working file, writes a run log.
- Store: pipelines persist as `.pipeline` text files under Application Support so people
  can edit them in any editor and agents can write them.

### EsclopIPC
- Message-port protocol between CLI/MCP and the running app. Request, progress, response and
  stop ports. Payloads are the Core request/result types.
- The CLI and MCP run the engines in-process when no IPC server is available. Routing to an
  app server is implemented in the library; the menu bar app starts it at launch.
- Ports `dev.esclop.app.request|stop|settings|control`, a reply port per client for progress and
  responses. `AppServer` + `AppRequestHandler` is the app's side; `JobExecutor` runs jobs
  in-process; `AgentPolicy` is the permission gate both sides apply. Details in `docs/mcp.md`.

### EsclopMCP
- Built on the official MCP Swift SDK, stdio transport. Also holds `EsclopService`, the layer
  the CLI and the MCP server share (routing to the app or in-process, pipelines, settings).
- Tools (names mirror the CLI): `esclop_optimise`, `esclop_convert`, `esclop_downscale`,
  `esclop_crop`, `esclop_fit_under_size`, `esclop_strip_metadata`, `esclop_crop_pdf`,
  `esclop_uncrop_pdf`, `esclop_pipeline_list/show/write/delete/run/attach/detach/preset`,
  `esclop_settings_schema/get/set`, `esclop_status`, `esclop_start_app`, `esclop_stop_app`,
  `esclop_recent_results`, `esclop_restore_backup`, `esclop_logs`.
- Resources: recent results, pipelines, settings. Prompts: "write a pipeline for…".
- Installers: write the server entry into each agent's config (Claude Code, Claude Desktop,
  Codex and ChatGPT desktop, Cursor, Windsurf, Zed, Gemini CLI, Copilot CLI, OpenCode, pi,
  Warp) and verify it.
- Permission gate: requests carry `origin = .mcp`; the app's settings say what agents may do
  (overwrite originals, delete, run scripts, change settings) and the server asks via
  elicitation when a tool needs more input.

### esclop (CLI)
swift-argument-parser. Subcommands: `optimise`, `convert`, `downscale`, `crop`, `fit`,
`strip`, `pdf crop|uncrop|pages`, `pipeline list|show|run|write|delete`, `settings
get|set|schema`, `status`, `logs`, `mcp serve|install|uninstall|status`.

### EsclopApp and EsclopAppKit
`EsclopApp` holds only the `@main` scene (menu bar extra and Settings window). `EsclopAppKit`
holds the rest, in folders by feature:
- `App/AppModel`: the single `@Observable` store on the main actor: results on screen, recent
  results, pause state. Every job runs through `run(_:)`, one card per file, at most
  `WorkGate.limit` files at once, with `JobExecutor` doing the work over `EsclopService`
  (in-process, `useApp: false`). Results are appended to the shared recent-results log, so
  `esclop_recent_results` and restore see them. `AppServices` starts everything at launch.
- `Jobs`: `RequestFactory` maps the "Optimised … go" settings to `OutputLocation` and applies
  the automatic limits (min/max size per kind, the `dev.esclop.optimised` xattr).
- `Clipboard`: `ClipboardWatcher` polls `NSPasteboard.changeCount` every 0.5 s on a serial
  queue (all pasteboard reads stay there); `ClipboardPolicy` decides from plain values: skip own
  writes and nspasteboard.org transient types, ignored apps, pause, and per-kind settings.
  Copied pixels are saved to a temporary file, optimised in place (the backup is the original)
  and put back on the clipboard.
- `Results`: the floating result (DESIGN.md). `ResultCard` is one result's model;
  `FloatingResultMachine` is its state as a value (thumbnail or detail level, hover buttons,
  the activity capsule, the 600 ms dwell, auto-hide paused while hovered, focused, dragged or
  open), driven by a clock passed in, so tests run it on a fixed one. `CardPresentation` holds
  the copy and figures (`Figures`: "612 kB · −75 %"), `JobEstimate` the expected duration
  (bytes, or frames for video via AVFoundation) behind the two-second activity rule.
  `FloatingResultView` draws the glass thumbnail, capsule, hover buttons and activity capsule,
  `DetailCard` the 320 pt card with the before/after comparison. Glass is Liquid Glass on
  macOS 26 (one `GlassEffectContainer` per result, shared glass IDs so levels morph), the HUD
  material before, opaque under Reduce Transparency. `FloatingPanelController` is a
  non-activating `NSPanel` at the chosen corner of the screen with the pointer; it grows at
  once and shrinks after animations, and a two-finger swipe toward the edge dismisses.
- `DropZone`: global mouse-drag monitors and the drag pasteboard (read off the main thread)
  show a panel at the results corner; Command switches it to "optimise harder".
- `Hotkeys`: KeyboardShortcuts names with Clop's default keys (⌃⇧P pause cycle, ⌃⇧C clipboard,
  ⌃⇧A harder).
- `IPC/AppIPCHandler`: the `AppRequestHandler`; applies `AgentPolicy` again, then routes jobs
  into `AppModel.run` so CLI and MCP jobs show floating results too.
- `Menu`, `Settings`: the menu bar menu and a minimal Settings window over the registry.

Planned: the full settings window with sidebar and deep links, watched folders, pipeline
editor, MCP pane, batch and crop windows, onboarding.

## Build and packaging
- `swift build` builds the CLI and libraries with Command Line Tools. The package includes
  the app target when the active developer directory is an Xcode (`DEVELOPER_DIR` or
  `xcode-select`) or `ESCLOP_WITH_APP` is set. Without switching globally:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`.
- `Scripts/build-tools.sh` builds ffmpeg, Ghostscript and gifsicle from pinned upstream
  tarballs (sha256 checked, patches in `Binaries/patches/`), universal, minimal ffmpeg
  configuration (`--disable-network`, no GPL components), into `Binaries/`, and records each
  tool's licence, source URL and checksum in `Binaries/LICENSES/` and `THIRD_PARTY.md`. It
  never downloads prebuilt binaries. `cargo build --release` in `engine/` produces
  `esclop-engine`. The build scripts cache outputs by content hash.
- `Scripts/bundle-app.sh` assembles `dist/L'Esclop.app` from the release build: Info.plist
  (from `Scripts/templates/Info.plist.in`), `Resources/bin`, `Resources/LICENSES`, SwiftPM
  resource bundles, `AppIcon.icns` drawn from `assets/icon.svg` (`Scripts/make-icon.swift`), an
  optional `assets/menubar-icon.*` template glyph, the CLI inside `Contents/MacOS`, codesign
  (ad hoc without a Developer ID). It exits cleanly when the app product is absent.
- `Scripts/licence-gate.sh DIR` finds every Mach-O file under `Binaries/`, an `.app` or a
  release directory by content and fails on any without a record: a `THIRD_PARTY.md` row
  ("Ships as" column) with version, licence, source and SHA-256 and its licence text in
  `LICENSES/`, `engine/THIRD_PARTY-engine.md` for the engine (checked against `cargo tree`), or
  L'Esclop's own executables. Licences are checked against `engine/deny.toml`'s allowlist.
- CI (`.github/workflows/ci.yml`) checks secrets and private paths, runs script checks and
  Swift build/tests, and builds the engine and tools on every pull request and main-branch push
  (`binaries.yml`), then runs the licence gate and tests with real tools. A tag `v*` runs `release.yml`
  with the same build and `Scripts/package-release.sh`
  (CLI tarball, repository and SwiftPM source, `cargo vendor`, third-party source, checksums) and a draft GitHub
  release. See `docs/release.md`.
- Tests: `swift test`. Golden media fixtures under `Tests/Fixtures` (small, generated).

## Rules
- Reused Clop code is taken from commit `4be5106` or earlier, keeps Clop's original header,
  and adds: `// Derived from Clop (github.com/FuzzyIdeas/Clop, commit 4be5106), GPL-3.0,
  Copyright Alin Panaitiu. Modified <YYYY-MM-DD> for L'Esclop: ...`. Listed in
  `docs/ATTRIBUTION.md` with file, origin commit and licence.
- Never take anything from Lowtech*, PaddleSPM, swift-ignore, WarpDrop, `required.swift`,
  `Colorize.swift`, `bin.tar.lrz` or lrzip, and never Clop's Pro gating nor code that removes it.
- Never reuse Clop's name, bundle identifier, URL scheme, IPC/MCP names, icon, images,
  website copy, Sparkle/Sentry/lowtechguys infrastructure or keys.
- gifsicle (GPL-2.0-only) runs as a separate process and is never linked. gifski and
  Ghostscript are AGPL. The MCP server exposes a source link; the planned About window
  must do the same.
- Bundle identifier prefix: `dev.esclop`. No personal data or machine paths in the repo.
