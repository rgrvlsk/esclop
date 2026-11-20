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
`L'Esclop.app/Contents/MacOS/esclop`. To put `esclop` on your PATH, run
`"/Applications/L'Esclop.app/Contents/MacOS/esclop" install-cli`: it links it into
`~/.local/bin` (`--dir` for another folder).
`esclop-X.Y.Z-cli.tar.gz` has the command line and the MCP server without the app.

## Status

0.2 is a beta. The menu bar app optimises what you copy, drop or save in a watched folder
(screenshots and screen recordings by default), and keeps every original restorable. Each file
shows a floating result with its saving; its detail and options convert, resize, crop, compare,
upload or run a pipeline. Many files at once go to a batch window. A copied file is optimised as
a copy, so the file on disk stays as it is; hold ⌥ while dropping to keep the originals. Copying
a media link offers to download it; nothing is fetched until you click (or until you choose
"Download and optimise" in Settings › Clipboard).

The cards take Clop's keys while the pointer rests on them: Space Quick Look, ⌘Z Undo, ⌘C Copy,
⌘F Show in Finder, ⌘D Compare, ⌘K Crop, ⌘S Save, ⌘⌫ Dismiss, ⌘- and ⌘1–⌘9 to downscale.

The app also has Settings with search and `esclop://settings/<key>` links, one-click setup for
AI agents, a pipeline editor, preset zones beside the drop zone, Finder Quick Actions, Shortcuts
actions, uploads to your own S3-compatible storage, and automatic updates. It is in English and
Catalan. See the [roadmap](docs/PLAN.md) and [architecture](docs/ARCHITECTURE.md).

### Command line

The CLI and the MCP server run their jobs through the app when it is open.

```sh
esclop optimise photo.png                   # in place, with a backup
esclop optimise https://example.com/a.jpg   # downloads the address first
esclop recent                               # the recent results
esclop restore photo.png                    # puts the original back
```

### Known limits

- The beta is signed ad hoc and not notarised: macOS asks for **Open Anyway** once (Install).
- JPEG XL is read but not written: macOS cannot write it, so it is not offered as an output.
- A speed change leaves out the chapters of a video or audiobook, because their times would not follow.
- A re-encoded or muted iPhone video loses its location and camera, even with stripping off: the
  bundled ffmpeg cannot copy them in a form macOS reads. The details say so.
- No secure send link and no iCloud settings sync yet; both are planned for 0.3.

## Build

Requires macOS 14 or later and the Xcode Command Line Tools. The engine and bundled tools
have additional prerequisites documented in their build guides.

```sh
swift build
Scripts/build-tools.sh                 # ffmpeg, gifsicle from pinned source
Scripts/build-engine.sh                # esclop-engine, the Rust image engine
```

Run `.build/debug/esclop --help` to explore the CLI. `make help` lists build targets,
including `Scripts/bundle-app.sh` for the app.

See [Contributing](CONTRIBUTING.md), [tool builds](docs/build-tools.md), the
[image engine](engine/README.md), [pipelines](docs/pipelines.md) and [MCP setup](docs/mcp.md).
