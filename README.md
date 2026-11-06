# L'Esclop

L'Esclop optimises images, videos, PDFs and audio on macOS. It provides a command line,
media pipelines and an MCP server for AI agents. It is free software under GPL-3.0-or-later.

L'Esclop is inspired by [Clop](https://lowtechguys.com/clop) and reuses some of its GPL code
with [attribution](docs/ATTRIBUTION.md). It is not affiliated with Clop's authors.

## Status

The CLI, MCP server, pipelines and media engines are implemented. The menu-bar app optimises
copied images (and copied files when the settings say so), shows a floating result for
each file, offers a drop zone while files are dragged, keeps originals restorable, and serves
the CLI and MCP server when it runs. The full settings window, pipeline editor and batch and
crop windows are planned.
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
including `Scripts/bundle-app.sh` for the unfinished app.

See [Contributing](CONTRIBUTING.md), [tool builds](docs/build-tools.md), the
[image engine](engine/README.md), [pipelines](docs/pipelines.md) and [MCP setup](docs/mcp.md).
