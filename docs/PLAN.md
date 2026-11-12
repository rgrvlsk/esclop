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
- The compare window: split, side by side and flip, zoom with pan in step, the pixel
  difference, video, audio and PDF, keep, restore and try another.
- Finder Quick Actions through Services: optimise, optimise harder, convert to WebP, run a pipeline.
- Shortcuts actions through App Intents: optimise, convert, downscale, crop, run a pipeline,
  get and change a setting, pause or resume.
- Automatic updates with Sparkle: signed DMGs, a signed appcast on the `appcast` branch, two
  settings and "Check for Updates…".
- Preset zones beside the drop zone, from pipelines and built-in templates, ordered in Settings.

- Uploads to S3-compatible targets with Keychain keys, from the Share tab, a pipeline step,
  automatic sources, `esclop upload` and MCP.

## Next

- A crop window for files that are not on screen as a floating result.

## Later

- PDF: a streaming load and write in `pdf.optimise`, so a large file is not held twice while it
  loads (peak memory is now about twice the input above roughly 256 MB; see
  `docs/engines.md`, PDF memory).
- Shelf integrations.
- More upload targets (WebDAV, a custom command) if they are asked for.
- App release validation, notarisation, a beta update channel and a Homebrew cask.

## Quality targets

- Build and test changes with `swift build` and `Scripts/test.sh`.
- Test media operations with generated fixtures and the real bundled tools.
- Aim for median image output size at most 102% of the reference at equal or better
  SSIMULACRA2, and peak RSS at most 300 MB on a 24-megapixel JPEG. The
  [benchmark report](../engine/bench/README.md) records the limited synthetic results and
  quality shortfalls; these targets are not claims about all media.
- Include light and dark screenshots for UI changes, with personal data removed.
- Preserve attribution headers for reused code.
