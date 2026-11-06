# Changelog

All notable changes to L'Esclop are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/). `Scripts/release-notes.sh` turns a version's section
into the body of its GitHub release.

## [Unreleased]

The full settings window, watched folders and the batch and crop windows remain planned.

### Added
- App icon and menu bar glyph: the carved wooden clog on the green squircle, and a rounded
  template clog for the menu bar that dims while paused. `make icons` regenerates them.
- Menu-bar app: optimises copied images (and copied videos, PDFs and audio when enabled), shows
  a floating card per file whose bar deflates to the new size, offers Restore, Show in Finder
  and Copy, and a drop zone while files are dragged (Command optimises harder). Hotkeys
  ⌃⇧P (pause cycle), ⌃⇧C (optimise clipboard) and ⌃⇧A (harder); a backups menu to restore
  originals; a minimal settings window. When it runs, the CLI and MCP server send their jobs
  to it and they show cards too.
- Settings for floating results and the drop zone: `floatingResultsCorner`,
  `followCursorScreen`, `autoHideFloatingResults`, `autoHideFloatingResultsAfter`,
  `autoHideClipboardResultAfter`, `enableDragAndDrop` (section `interface`).
- `esclop` command line: `optimise`, `convert`, `downscale`, `crop`, `fit`, `strip`,
  `pdf crop|uncrop|pages`, `pipeline list|show|run|write|delete`, `settings get|set|schema`,
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
