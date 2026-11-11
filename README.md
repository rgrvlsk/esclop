# L'Esclop

L'Esclop optimises images, videos, PDFs and audio on macOS. It provides a command line,
media pipelines and an MCP server for AI agents. It is free software under GPL-3.0-or-later.

L'Esclop is inspired by [Clop](https://lowtechguys.com/clop) and reuses some of its GPL code
with [attribution](docs/ATTRIBUTION.md). It is not affiliated with Clop's authors.

## Install

Download `LEsclop-X.Y.Z.dmg` from the [releases page](../../releases), open it and drag
L'Esclop to Applications. It needs macOS 14 or later and runs on Apple Silicon and Intel.

The beta is not notarised by Apple, so macOS refuses to open it the first time. Open it once,
then go to System Settings → Privacy & Security, find the message about L'Esclop near the end
and click **Open Anyway**.

The command line and the MCP server are inside the app, at
`L'Esclop.app/Contents/MacOS/esclop`. `esclop-X.Y.Z-cli.tar.gz` has them without the app.

## Status

0.1 is a beta. The menu-bar app optimises copied images (and copied files when the settings
say so) and new files in watched folders, shows a floating result for each file with its
options, crop and conversions, lists large jobs in a batch window, offers a drop zone while
files are dragged, and keeps originals restorable. Its Settings window lists every setting by
pane, with search and `esclop://settings/<key>` links, and connects AI agents in one click. A
pipeline editor creates and runs pipelines without a text file, and a first-run tour
introduces the app. The CLI and the MCP server run their jobs through the app when it is open.

It compares a result with its original, offers Finder Quick Actions and Shortcuts actions, and
updates itself when a new release is published. It uploads results to your own S3-compatible
storage and copies the link. Planned: preset zones. The app is in
English and Catalan.
See the [roadmap](docs/PLAN.md) and [architecture](docs/ARCHITECTURE.md).

## Build

Requires macOS 14 or later and the Xcode Command Line Tools. The engine and bundled tools
have additional prerequisites documented in their build guides.

```sh
swift build
Scripts/build-tools.sh                 # ffmpeg, Ghostscript, gifsicle from pinned source
Scripts/build-engine.sh                # esclop-engine, the Rust image engine
```

Run `.build/debug/esclop --help` to explore the CLI. `make help` lists build targets,
including `Scripts/bundle-app.sh` for the app.

See [Contributing](CONTRIBUTING.md), [tool builds](docs/build-tools.md), the
[image engine](engine/README.md), [pipelines](docs/pipelines.md) and [MCP setup](docs/mcp.md).
