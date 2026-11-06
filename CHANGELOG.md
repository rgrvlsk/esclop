# Changelog

All notable changes to L'Esclop are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/). `Scripts/release-notes.sh` turns a version's section
into the body of its GitHub release.

## [Unreleased]

Watched folders and the batch window remain planned.

### Added
- Settings window: a sidebar of panes (General, Images, Video, PDF, Audio, Clipboard, Floating
  results, Agents and MCP, Advanced) built from the settings registry, search across every
  setting and hotkey, `esclop://settings/<key>` links that open the pane and mark the row,
  values checked as they are typed, a reset arrow per changed setting and Reset All. It reads
  and writes the same settings as `esclop settings` and follows changes made from the command
  line while it is open. Replaces the minimal settings window. Agent refusals now carry the
  link to the switch that would allow the request, for example
  `esclop://settings/agents/allowRunScripts`, and name it as the Settings window does.
- `esclop settings reset <key>` puts one setting back to its default.
- Settings → Agents and MCP: lists the agents on this Mac (the ones `esclop mcp install`
  supports) with whether each runs L'Esclop, connects, updates and disconnects them in one
  click after showing the exact change to their config file as a diff, keeps a backup, refuses
  to write a file that changed after the preview, tests the server live (initialize,
  tools/list, `esclop_status`) and offers JSON, TOML and `claude mcp add` snippets.
- Floating result redesigned for Liquid Glass (DESIGN.md): a ~200 pt thumbnail with a capsule
  that counts down to "612 kB · −75 %", round hover buttons (Undo, Convert, Downscale, Crop,
  "…"), a 320 pt detail with a before/after divider opened by the capsule or a still pointer,
  an activity capsule with the time left for jobs over two seconds, errors in the capsule with
  retry, the newest three stacked, two-finger swipe to dismiss. VoiceOver announces each result.
- Options popover from the "…" hover button (DESIGN.md): Optimise (a suggestion from where the
  file came from, compression, format tiles with size estimates, quality, metadata, HDR, encoder,
  video, PDF and audio controls), Size (downscale in 10 % steps, fit under a size, crop presets
  and a crop editor with a free or locked rectangle and the size in pixels) and Share (Copy,
  AirDrop, Save as, Finder, Quick Look, Share, Open with, Shortcuts, pipelines, shelf and upload
  apps when installed). Audio gets Sound in place of Size. Choices run again on the same card.
- Clipboard rules: "Always apply to PNG screenshots" stores the current choice for that origin
  and format; the next copy of that kind uses it and the capsule shows a pin. Rules live in the
  `clipboardRules` setting and are listed, with a delete button, in Settings › Clipboard.
- `hoverButtons` setting, switches in Settings › Floating results and "Customise buttons…" in
  the popover, for the round buttons above a result.
- `CropSize.rect`: a free crop region for images and videos, in the engine and the contracts.
- Catalan localisation of the floating result, the popover and the rules (String Catalog).
- App icon and menu bar glyph: the carved wooden clog on the green squircle, and a rounded
  template clog for the menu bar that dims while paused. `make icons` regenerates them.
- Menu-bar app: optimises copied images (and copied videos, PDFs and audio when enabled), shows
  a floating card per file whose bar deflates to the new size, offers Restore, Show in Finder
  and Copy, and a drop zone while files are dragged (Command optimises harder). Hotkeys
  ⌃⇧P (pause cycle), ⌃⇧C (optimise clipboard) and ⌃⇧A (harder); a backups menu to restore
  originals. When it runs, the CLI and MCP server send their jobs
  to it and they show cards too.
- Settings for floating results and the drop zone: `floatingResultsCorner`,
  `followCursorScreen`, `autoHideFloatingResults`, `autoHideFloatingResultsAfter`,
  `autoHideClipboardResultAfter`, `enableDragAndDrop` (section `interface`).
- `esclop` command line: `optimise`, `convert`, `downscale`, `crop`, `fit`, `strip`,
  `pdf crop|uncrop|pages`, `pipeline list|show|run|write|delete`, `settings get|set|reset|schema`,
  `status`, `logs`. It runs without the app.
- MCP server (`esclop mcp serve`) with the `esclop_*` tools, resources and prompts, and
  installers that add it to Claude Code, Claude Desktop, Codex, Cursor, Windsurf, Zed, Gemini
  CLI, Copilot CLI, OpenCode, pi and Warp. Agents cannot overwrite originals unless permission is enabled.
- Message-port IPC library for the command line, MCP server and planned app integration,
  with timeouts and concurrency guards.
- Pipelines: a model, a text language compatible with Clop's so existing pipelines carry over,
  a runner, a store of `.pipeline` files and built-in presets.
- `esclop-engine`, the Rust image engine: PNG (imagequant, oxipng), JPEG (mozjpeg), WebP, AVIF
  (libaom through libavif, with optional rav1e), GIF (gifski and its own optimiser), resize,
  crop, metadata and fit-under-size behind a JSON-lines protocol. The
  [synthetic benchmarks](engine/bench/README.md) compare reference tools using Clop 3.5's
  flags. All listed operations stay under 300 MB on the 24-megapixel JPEG fixture; AVIF
  and aggressive PNG have small quality shortfalls against the reference.
- Video, audio and PDF engines on ffmpeg (LGPL build with VideoToolbox), Ghostscript and
  gifsicle, which `Scripts/build-tools.sh` builds from pinned, checksummed upstream source.
- Settings registry shared by the app, the command line and the MCP server; tool locator;
  process runner; backups of originals with pruning.
- Licence policy: `cargo deny` allowlist for the engine, generated notices for the engine's
  crates (`engine/THIRD_PARTY-engine.md`) and the bundled tools (`THIRD_PARTY.md`).
- Release engineering: continuous integration, a licence gate over every bundled Mach-O file,
  release packaging with the complete corresponding source, and this changelog.

### Fixed
- `esclop mcp status` and the install messages printed the command line unquoted when its path
  has an apostrophe (the app lives in `L'Esclop.app`), so the line could not be pasted into a
  shell.
