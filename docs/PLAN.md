# Roadmap

The first usable GUI release should let a person copy a screenshot, see its size reduction
in a floating card and restore the original. CLI and MCP workflows already run without the app.

## Implemented

- CLI commands, message-port IPC library and MCP server with agent installers.
- Swift media engines, Rust image engine, settings registry and backups.
- Pipeline parser, executor, file store and built-in presets.
- Pinned tool builds, licence checks, CI and CLI release packaging.
- Menu-bar app: clipboard watcher, the Liquid Glass floating result (thumbnail, detail with
  before/after comparison, activity capsule for long jobs), drop zone, hotkeys, backups menu,
  and the IPC server that runs CLI and MCP jobs with results.
- Settings window: a sidebar of panes generated from the registry, search across every
  setting, `esclop://settings/<key>` deep links, validation and reset per setting.
- Agents and MCP pane: agent detection, connect and disconnect with a preview of the config
  change, the permission switches, snippets and a live server test.
- First-run onboarding, skippable and reopened from the menu.
- The options popover from "…" (Optimise, Size with the crop editor, Share; Sound for audio)
  with size estimates, origin suggestions, clipboard rules and the Catalan localisation.
- The batch window for many files at once: progress, aggregate saving, pause, stop and restore all.
- Watched folders (screenshots and recordings by default) and pipeline folder triggers in the
  app, with a folder list editor in each kind's Settings pane.

- The pipeline editor: steps, triggers, filter, a text view and Try it.
- Finder Quick Actions through Services: optimise, optimise harder, convert to WebP, run a pipeline.

## Next

- Shortcuts actions through App Intents.
- A crop window for files that are not on screen as a floating result.

## Later

- Preset zones, uploads and shelf integrations.
- App release validation, notarisation, Sparkle updates and a Homebrew cask.

## Quality targets

- Build and test changes with `swift build` and `Scripts/test.sh`.
- Test media operations with generated fixtures and the real bundled tools.
- Aim for median image output size at most 102% of the reference at equal or better
  SSIMULACRA2, and peak RSS at most 300 MB on a 24-megapixel JPEG. The
  [benchmark report](../engine/bench/README.md) records the limited synthetic results and
  quality shortfalls; these targets are not claims about all media.
- Include light and dark screenshots for UI changes, with personal data removed.
- Preserve attribution headers for reused code.
