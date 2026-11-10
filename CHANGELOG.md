# Changelog

All notable changes to L'Esclop are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/). `Scripts/release-notes.sh` turns a version's section
into the body of its GitHub release.

## [Unreleased]

### Added
- Finder Quick Actions: right-click images, videos, PDFs or audio files in Finder and choose
  "Optimise with L’Esclop", "Optimise Harder with L’Esclop", "Convert to WebP with L’Esclop"
  (images) or "Run a Pipeline with L’Esclop…", which offers the pipelines whose triggers
  include Finder's right-click menu. Nothing opens: the files go through the usual floating
  results, or the batch window from `batchWindowFrom` files. Made with macOS Services, as Clop
  does; the titles are in English and Catalan.

## [0.1.0] - 2026-11-10

The first public beta: the menu bar app, the `esclop` command line and the MCP server for AI
agents, in one download for Apple Silicon and Intel (macOS 14 or later). The app is signed ad
hoc and not notarised yet.

### Added
- Catalan: the whole app speaks Catalan when macOS does (or with `ESCLOP_LANGUAGE=ca`): the
  menu, the floating results and their options, the batch window, the Settings window with
  every setting and its search, the Agents and MCP pane, the first-run tour, the pipeline
  editor and the parser's messages in it. The command line and the MCP server stay in English.
- Pipeline editor: a window (menu → Pipelines…, Settings → Advanced, a result's Share tab,
  `esclop://pipelines` and `esclop://pipelines/<name>`) to create, edit, duplicate, delete and
  run pipelines without a text file. Saved pipelines and the built-in templates (read-only,
  with Duplicate) are listed on the left. On the right: the steps for each kind of file, with a
  control for each argument and the parser's message on the step it belongs to; a filter
  ("Only some files") checked live against a file you choose; what runs the pipeline on its own
  (clipboard, drop zone, preset zone, Finder, command line, agents, watched folders); a text
  view of the same pipeline, kept in step with the form, that marks the lines with errors; and
  Try it, which runs the pipeline on a copy of a file and shows each step and the saving. What
  it saves is what `PipelineSerializer` writes. Script steps are shown as code, with a note
  that agents only run such a pipeline when "Agents may run scripts" is on.
- Watched folders: new images, videos, PDFs and audio files in the folders listed in Settings
  (the Desktop for screenshots and recordings by default) are optimised as they appear, with a
  floating result, or in the batch window when enough arrive. As in Clop, hidden, temporary and
  partial downloads are left alone, and so are files already optimised, files L'Esclop itself
  wrote in the last three seconds, and files outside the size limits. A file still being written
  waits until it stops changing. When more files of one kind than its count (`maxImageFileCount`
  4, `maxVideoFileCount` 1, `maxPDFFileCount` 2, `maxAudioFileCount` 2) appear at once, none of
  them is touched and a notice says so. A pipeline with a `folder(...)` trigger runs instead of
  the plain optimisation for the kinds it has steps for, also in folders no list names. Pause
  stops the watching; the menu says how many folders are being watched.
- Settings: each folder list has its own editor in its kind's pane: Add Folder… with the folder
  picker, Show in Finder and Stop Watching per folder, a line under a folder that no longer
  exists or that macOS does not let L'Esclop read (with a button to the privacy settings), and
  the folder macOS saves screenshots to offered when it is not in the list.
- Batch window: a job with four files or more (`batchWindowFrom`) lists them in one window
  instead of a floating result each, from the drop zone, "Optimise Files…" in the menu (files
  or folders), several copied files, and the CLI or MCP. The header shows the aggregate saving
  with the deflate bar and the counts; rows show each file's progress, sizes, bar and saving.
  Pause, Stop, Restore All and Show in Finder act on the batch; restore, try again, stop, copy
  and Show in Finder on a row.
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
  to write a file that changed after the preview or any file but the agent's own config, tests
  the server live (initialize, tools/list, `esclop_status`) and offers JSON, TOML and
  `claude mcp add` snippets.
- First-run tour: welcome, what is optimised on its own (the same switches as Settings), what
  macOS will ask and why (clipboard access with its current status, files in Desktop,
  Documents and Downloads, open at login), connecting an agent, and where the app lives. Every
  step can be skipped; the menu's "Welcome to L'Esclop…" opens it again.
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

### Changed
- The four "Watch folders for …" switches and the folder lists moved from Automation to the
  Images, Video, PDF and Audio panes.
- Watched folders no longer read inside a folder when they start: macOS asks for access to a
  protected folder such as the Desktop when the first new file lands there, as with Clop, and
  the first-run tour says so. If access is refused, the folder leaves the watch without a
  notice or another attempt until the folder lists change or the app restarts, and its
  Settings row says why.

### Fixed
- Release builds no longer carry the path of the machine that built them: looking for tools
  beside the source file is for debug builds only. The release workflow checks the app's
  binaries for such paths, as it did the command line's, and now builds the DMG.
- Floating results and the options popover, from a live UI check:
  - the popover header shows the result's size after a crop or a downscale;
  - a result's row of buttons no longer covers the result above, and results no longer touch;
  - a damaged or unreadable file says so plainly ("This file isn't a video L'Esclop can read.
    It may be damaged.") in the card, the batch window, the CLI and MCP (`unreadable`, exit
    code 65); the tool's own output goes to the log;
  - "Optimise Clipboard" on a result L'Esclop just wrote shows that result again instead of
    making a second one, and the app recognises its own clipboard writes by their bytes too;
  - a result with no saving reads "Already optimised", never "−0 %";
  - copied images are "Copied image" in the popover, and an unknown origin is named;
  - default buttons use the app's accent; the Share row's labels line up;
  - closing a detail gives the result its whole hide delay again.
- Settings: descriptions written for people (the values the CLI takes stay in the schema's
  `x-details`), left-aligned footers in Agents and MCP, a "Not found on this Mac" list that
  VoiceOver can open, a change preview that shows the whole change, and copied commands in
  double quotes when that is all they need.
- `esclop mcp status` and the install messages printed the command line unquoted when its path
  has an apostrophe (the app lives in `L'Esclop.app`), so the line could not be pasted into a
  shell.
