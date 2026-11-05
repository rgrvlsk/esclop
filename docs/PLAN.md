# Roadmap

The first usable GUI release should let a person copy a screenshot, see its size reduction
in a floating card and restore the original. CLI and MCP workflows already run without the app.

## Implemented

- CLI commands, message-port IPC library and MCP server with agent installers.
- Swift media engines, Rust image engine, settings registry and backups.
- Pipeline parser, executor, file store and built-in presets.
- Pinned tool builds, licence checks, CI and CLI release packaging.

`Sources/EsclopApp/EsclopApp.swift` is a minimal menu-bar stub. It does not yet connect
clipboard monitoring, result cards or the IPC server to the GUI.

## Next: usable menu-bar app

- Connect the engines and IPC server to the app.
- Add clipboard monitoring, floating result cards, a drop zone and hotkeys.
- Make originals accessible through a backups menu.
- Verify copying an image and dropping a file through the complete UI workflow.

## Later

- Settings search, deep links, a pipeline editor, MCP setup and onboarding.
- Batch and crop windows, plus before-and-after comparison.
- Watched folders, preset zones, Finder actions, uploads and shelf integrations.
- App release validation, notarisation, Sparkle updates and a Homebrew cask.
- Shortcuts actions through AppIntents.

## Quality targets

- Build and test changes with `swift build` and `Scripts/test.sh`.
- Test media operations with generated fixtures and the real bundled tools.
- Aim for median image output size at most 102% of the reference at equal or better
  SSIMULACRA2, and peak RSS at most 300 MB on a 24-megapixel JPEG. The
  [benchmark report](../engine/bench/README.md) records the limited synthetic results and
  quality shortfalls; these targets are not claims about all media.
- Include light and dark screenshots for UI changes, with personal data removed.
- Preserve attribution headers for reused code.
