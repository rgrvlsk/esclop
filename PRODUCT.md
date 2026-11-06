# L'Esclop

## Purpose and status

L'Esclop is free software for making images, videos, PDFs and audio smaller on macOS.
The CLI, MCP server, pipelines and media engines are implemented. The menu-bar app watches the
clipboard, shows floating results and a drop zone, runs the CLI's and MCP server's jobs when
it is open, and has a Settings window with search, deep links and one-click agent setup, and a
first-run tour; the other GUI windows are planned.

The name is Catalan for a wooden clog. Technical identifiers use lower-case `esclop`:
the CLI, the `esclop://` scheme, the `dev.esclop` bundle prefix and `esclop_*` tool names.

## Users

- People who share screenshots, recordings and photos and want smaller files.
- People who use AI agents to optimise, convert and crop media through MCP.
- People who automate media processing with pipelines and scripts.

## Planned app workflow

Copy or drop a file, see a floating result, then drag, resize, convert or undo it.
In-place operations keep a backup of the original.

The GUI will include result cards, drop and preset zones, settings with search and deep
links, MCP setup, onboarding, a pipeline editor, and batch and crop windows.

## Platform

macOS 14 and later, Apple Silicon and Intel. Swift provides the CLI and integration with
macOS; the planned GUI uses SwiftUI and AppKit. The Rust image engine uses imagequant,
oxipng, mozjpeg, fast_image_resize, libwebp, libaom through libavif, and gifski.
An optional rav1e encoder is available. See the [engine guide](engine/README.md).

The bundled external tools are ffmpeg and ffprobe, Ghostscript and gifsicle, built from
pinned source. ffmpeg uses an LGPL configuration with VideoToolbox and AudioToolbox encoders.
ImageIO handles HEIC and other system image formats; ImageIO and Core Image handle HDR gain maps.

## Release scope

The CLI and MCP server are the current entry points. The full GUI, Shortcuts actions and
Sparkle updates remain planned. Signing and notarisation support exists in the release
scripts; app releases remain disabled until the GUI is ready. Windows and Linux are out of scope.

## Constraints

- No telemetry or licence checks. Network operations require a user request.
- Reused Clop code comes only from commit `4be5106` or earlier, keeps its original header,
  includes a dated modification notice and is listed in [Attribution](docs/ATTRIBUTION.md).
  Excluded sources are Lowtech*, Paddle, swift-ignore, WarpDrop, `required.swift` and
  `Colorize.swift`, whose licence is unconfirmed. Do not reuse Pro gating or code that removes it.
- Do not reuse Clop's branding, artwork, bundle identifiers, URL scheme, IPC/MCP names,
  website copy, service infrastructure or keys.
- Releases must include complete corresponding source, including SwiftPM dependencies,
  vendored Rust crates, upstream tool tarballs, patches and build scripts. Bundled executable
  licences are listed in `THIRD_PARTY.md` and `Contents/Resources/LICENSES/`.
- Do not commit personal data or machine-specific paths.
