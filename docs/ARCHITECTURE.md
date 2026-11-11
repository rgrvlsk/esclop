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
- Installers: plan an edit of an agent's config (`ConfigChange`: the text before and after, the
  backup path, a diff), apply it only when the file is unchanged since the plan, and read it
  back. `esclop mcp install` and the app's Agents pane both go through plan and apply.
  `MCPProbe` starts `esclop mcp serve` and runs initialize, tools/list and `esclop_status`.
  The installers write the server entry into each agent's config (Claude Code, Claude Desktop,
  Codex and ChatGPT desktop, Cursor, Windsurf, Zed, Gemini CLI, Copilot CLI, OpenCode, pi,
  Warp) and verify it.
- Permission gate: requests carry `origin = .mcp`; the app's settings say what agents may do
  (overwrite originals, delete, run scripts, change settings) and the server asks via
  elicitation when a tool needs more input.

### esclop (CLI)
swift-argument-parser. Subcommands: `optimise`, `convert`, `downscale`, `crop`, `fit`,
`strip`, `pdf crop|uncrop|pages`, `pipeline list|show|run|write|delete`, `settings
get|set|reset|schema`, `status`, `logs`, `mcp serve|install|uninstall|status`.

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
- `Batch`: jobs with `batchWindowFrom` files or more (four by default) get a `Batch` instead of
  floating results: one `BatchRow` per file, filled by the same `AppModel.run` and work gate.
  Rows are added when the batch opens, so the window lists every file at once; a paused batch
  holds files before the gate and sends back a file that reached it meanwhile. `Batch` holds
  the aggregate figures, `BatchPresentation` the copy, `BatchView` and `BatchWindowController`
  the window, which comes forward without taking focus.
- `Options`: the options popover (DESIGN.md › Options popover). `OptionsModel` holds one
  popover's state; `OptimiseChoice` is a choice as a value that writes the fields of an
  `OptimisationRequest`, so a suggestion, a popover change and a clipboard rule all run the
  same engine operations, from the original, on the same card. `OriginClassifier` is a pure
  function of `OriginSignals` (EXIF screenshot mark, the app in front at the copy, pasteboard
  types, folders, PDF creator, audio encoder); `Suggestion` maps origin and format to a choice.
  `ClipboardRules` stores rules in the `clipboardRules` setting, keyed by origin and input
  UTType. `SizeEstimator` (an actor) caches estimates per file and choice, two at a time,
  cancelled when the popover closes: real encodes into a scratch folder for images and PDFs up
  to 25 MB, a bitrate model calibrated by the card's result for video and audio.
  `CropGeometry` is the crop editor's arithmetic; `CropSize.rect` carries a free crop to the
  engines. Copy goes through `Strings`, which reads `Localizable.xcstrings` (English base,
  Catalan) by locale; `ESCLOP_LANGUAGE` overrides the system language.
- `DropZone`: global mouse-drag monitors and the drag pasteboard (read off the main thread)
  show a panel at the results corner; Command switches it to "optimise harder". `PresetZones`
  is a pure function of the saved pipelines, the built-in templates and the `presetZones`
  setting: every possible zone in order, and the four a drag of some kinds shows. The views
  report each target's frame in a named space, and `DropTargetView` hit-tests the drag point
  against them, so a drop goes to the zone drawn under it. `esclop://dropzone` pins the panel.
- `Hotkeys`: KeyboardShortcuts names with Clop's default keys (⌃⇧P pause cycle, ⌃⇧C clipboard,
  ⌃⇧A harder).
- `IPC/AppIPCHandler`: the `AppRequestHandler`; applies `AgentPolicy` again, then routes jobs
  into `AppModel.run` so CLI and MCP jobs show floating results too.
- `Menu`: the menu bar menu.
- `Settings`: the Settings window. `SettingsPane` maps registry sections to sidebar panes, so a
  new registry setting appears in its pane without view code; `SettingPresentation` picks each
  setting's control, words and unit, and which switch it depends on; `SettingsRoute` parses
  `esclop://settings[/<pane>][/<key>][?highlight=<key>]` (the shape of Clop's settings links).
  `SettingsViewModel` reads and writes through the same `SettingsProvider` as the CLI and MCP
  and observes the defaults suite with key-value observation, which also reports writes from
  other processes, so `esclop settings set` shows up in an open window.
  `SettingsWindowController` owns the one window; `AppServices.open(_:)` routes links to it.
  `AgentsModel` backs the Agents and MCP pane: agent statuses read off the main thread, the
  planned `ConfigChange` shown as a diff before it is applied, and the `MCPProbe` test. The
  command agents run is the `esclop` next to the app's executable (inside the bundle).

- `Folders`: watched folders. `WatchPlan` is a pure function of the settings and the saved
  pipelines: the folders to watch (the four lists of the kinds switched on, plus every
  pipeline's `folder(...)` trigger, the first pipeline by name winning a folder) and what a new
  file gets (`optimise`, `pipeline` or a `WatchSkip` reason). `FolderWatcher` is one FSEvents
  stream with file-level events; `FileSettle` waits until a file's size and modification date
  stop changing. `WatchedFolders` ties them to the model: files of one kind arriving within a
  second form a `Burst`, a burst above the kind's count is left alone with a notice, the rest
  settle, are decided again and go to `AppModel.optimise` or `AppModel.runPipeline`. The model
  remembers what it wrote for three seconds (`wasJustWritten`), and the optimised mark covers the
  rest, so a result is never picked up again. `AppServices` refreshes the watcher when the
  lists, the pause, the pipelines folder or the mounted disks change. `FolderListEditor` is the
  Settings control for the four lists.
- `Compare`: the compare window. `CompareSides` resolves the two files from a result (its
  backup, or the original beside a result written next to it) and says when the original is no
  longer kept; `CompareViewport` is the zoom, pan and divider arithmetic shared by both sides;
  `CompareMedia` decodes images, draws PDF pages from their media box and computes the
  difference mask with Core Image; `ComparePlayers` keeps two AVPlayers in step.
  `CompareModel` follows the result's floating result, so "try another" (run through
  `AppModel.reprocess`, as the popover does) updates the window in place.
- `Finder`: Finder's Quick Actions. `FinderServices` is `NSApp.servicesProvider`: the four
  services declared in `Info.plist` (`NSServices`, titles localised in
  `Resources/<lang>.lproj/ServicesMenu.strings`, both from `Scripts/templates`) hand their files
  to `AppModel.optimise` with the `finder` origin, or to a pipeline with the `rightClick` trigger.
- `Pipelines`: the pipeline editor. `PipelineDraft` is a pipeline as the form holds it (each
  step as its name and the text of its arguments, the filter as the `if` step every section
  starts with); it builds step text, has `PipelineParser` read it, places the parser's errors
  and warnings on their step, and turns into the `Pipeline` that `PipelineStore` saves through
  `PipelineSerializer`. `PipelineEditorModel` holds the list, the selection, the text view and
  "Try it" (a `PipelineRunner` with no host on a copy in a folder of its own);
  `PipelineEditorWindowController` owns the window and `esclop://pipelines[/<name>]`. Rows bind
  to steps through `PipelineEditorModel.binding(for:)`, which looks the step up by id on every
  read, so a row read in the update where its step, section or filter went away does not trap.
  A try's folder is removed by the next try, a new selection and the window closing, and
  leftovers at launch.
- `Onboarding`: `OnboardingModel` (steps, the `finishedOnboarding` flag in the app's defaults,
  clipboard access from `NSPasteboard.accessBehavior`, open at login through `SMAppService`),
  `OnboardingView` (its pages reuse `SettingRow` and the Agents pane's section) and
  `OnboardingWindowController`, which `AppServices.start()` asks to show on the first launch.
- `Intents`: Shortcuts actions. `FileIntents` and `SettingIntents` are the App Intents;
  `IntentChoices` holds their typed choices (`ConvertFormat`, and queries over the saved
  pipelines and the settings registry). Every action goes through `ShortcutActions`, which waits
  for `AppServices` to set the model, runs file jobs through `AppModel` and settings through the
  same `SettingsProvider` as the CLI. `Scripts/appintents-metadata.sh` type-checks the files that
  import AppIntents against the release build's modules to get the compiler's constant values
  (only some Swift Build versions write them in a SwiftPM build), runs Xcode's
  `appintentsmetadataprocessor` on them into `Contents/Resources/Metadata.appintents` and writes `ca.lproj/Localizable.strings` from the
  catalog for the strings Shortcuts reads from the main bundle.
- `Updates`: `Updater` runs Sparkle (`SPUStandardUpdaterController`) when the bundle carries
  `SUPublicEDKey`, keeps Sparkle's automatic check and install switches and the two registry
  settings in step both ways, honours `ESCLOP_UPDATE_FEED` at launch, and brings Sparkle's window
  forward in a menu bar app. Feed, keys and signing: docs/release.md › Updates.

Planned: a crop window.

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
  resource bundles (EsclopAppKit's carries the menu bar glyph `MenuBarIcon.pdf`), the committed
  `assets/AppIcon.icns` (`make icons` regenerates it, see `assets/README.md`), the CLI inside
  `Contents/MacOS`, `Sparkle.framework` in `Contents/Frameworks` (the build directory's rpaths
  removed), codesign inside out
  (ad hoc without a Developer ID). It exits cleanly when the app product is absent.
- `Scripts/appcast.sh DMG URL OUT` writes and signs the update feed; `Scripts/sparkle-tools.sh`
  fetches Sparkle's `sign_update` at the pinned version; `Scripts/update-e2e.sh` updates a
  bundled app from a local feed.
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
