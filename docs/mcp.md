# MCP server

L'Esclop's MCP server lets AI agents optimise, convert, crop and resize images, videos, PDFs and
audio files on this Mac, and manage pipelines and settings, within limits the person sets. It is
part of the `esclop` command line: agents start it as `esclop mcp serve` and talk to it over
stdin and stdout (newline-delimited JSON-RPC, MCP protocol 2025-11-25 and earlier). The server
is named `esclop-mcp`; its entry in agent configs is called `esclop`.

When the L'Esclop app is running, the server sends jobs to it: they join the app's queue and
show the same floating result cards as copied and dropped files, and the app applies the agent
permissions again. Without the app, the server runs jobs in its own process.

## Install

In the app: Settings → Agents and MCP (`esclop://settings/agents`) lists the agents on this Mac
and whether each runs L'Esclop. Connect shows the exact change to the agent's config file as a
diff and writes it only after you agree; if the file changed in the meantime nothing is
written. Run Test starts the server as agents do and reports its tools. The same pane has the
JSON, TOML and `claude mcp add` snippets for setting an agent up by hand.

From a terminal:

```
esclop mcp install --all            # every agent found on this Mac
esclop mcp install claude-code      # one or more by name
esclop mcp status                   # which agents are found and which run esclop
esclop mcp uninstall cursor         # or --all
```

The installer edits each agent's own config file in place: other servers, comments, key order and
formatting stay as they were. The edited text is checked before it is written and read back
after; the previous version of each file is kept in
`~/Library/Application Support/esclop/agent-config-backups/`. Restart the agent (or
start a new session) to load the server. `esclop mcp status` prints the exact command line agents
run; `--command <path>` installs a different `esclop` binary.

| Agent | id | Config file | Format |
|---|---|---|---|
| Claude Code | `claude-code` | `~/.claude.json` (`mcpServers`) | JSON |
| Claude Desktop | `claude-desktop` | `~/Library/Application Support/Claude/claude_desktop_config.json` | JSON |
| Codex CLI and ChatGPT desktop | `codex` | `~/.codex/config.toml` (`[mcp_servers.esclop]`) | TOML |
| Cursor | `cursor` | `~/.cursor/mcp.json` | JSON |
| Windsurf | `windsurf` | `~/.config/devin/mcp_config.json`, or `~/.codeium/windsurf/mcp_config.json` when only that exists | JSON |
| Zed | `zed` | `~/.config/zed/settings.json` (`context_servers`) | JSON with comments |
| Gemini CLI | `gemini` | `~/.gemini/settings.json` | JSON |
| GitHub Copilot CLI | `copilot` | `~/.copilot/mcp-config.json` | JSON |
| OpenCode | `opencode` | `~/.config/opencode/opencode.json` or `.jsonc` (`mcp`) | JSON |
| pi | `pi` | `~/.pi/agent/mcp.json` | JSON |
| Goose | `goose` | `~/.config/goose/config.yaml` (`extensions`) | YAML |
| VS Code | `vscode` | `~/Library/Application Support/Code/User/mcp.json` (`servers`) | JSON |
| Amp | `amp` | `~/.config/amp/settings.json` (`amp.mcpServers`) | JSON |
| Factory Droid | `droid` | `~/.factory/mcp.json` | JSON |
| Qwen Code | `qwen` | `~/.qwen/settings.json` | JSON |
| Warp | `warp` | none: Warp → Settings → AI → MCP Servers → Add, paste the JSON `esclop mcp install warp` prints | manual |

For manual setup, use the installed CLI path. Replace `/path/to/esclop` below with its
absolute path. Each agent expects a different configuration wrapper:

```json
{ "mcpServers": { "esclop": { "command": "/path/to/esclop", "args": ["mcp", "serve"] } } }
```

```toml
[mcp_servers.esclop]
command = "/path/to/esclop"
args = ["mcp", "serve"]
```

Claude Code can also add it itself:
`claude mcp add --scope user esclop -- /path/to/esclop mcp serve`.

## Tools

Every file tool takes `paths`: files or folders, as absolute paths, `~/...`, `file://` URLs or
paths relative to the server's working directory (a single string works too), with `recursive`
and `types` (extensions) for folders. Results come back as a short text summary (bytes before →
after, saving, output path) followed by the same data as JSON, also in `structuredContent`:
`results[]` with `source`, `output`, `backup`, `bytesBefore`, `bytesAfter`, `savedPercent`,
`width`, `height`, and `failures[]` with `source`, `error` and a `code` (`fileNotFound`,
`unsupportedFile`, `unreadable` (a damaged or mislabelled file), `alreadySmaller`, `toolMissing`,
`notPermitted`, `invalidArgument`,
`invalidPipeline`, ...). A file that fails does not stop the others; `isError` is set only when
every file failed or the call was refused.

Where results go: `location` is `inPlace` (replace the original, keeping a backup), `sameFolder`
(a new file next to it) or `temporary`; `output` takes a folder ending in `/` or a path template
(`%f` name, `%e` extension, `%d` folder). Left out, it is `inPlace` when the person allows agents
to overwrite originals and `sameFolder` otherwise.

| Tool | What it does | Example arguments |
|---|---|---|
| `esclop_optimise` | Compress files. Lossy settings can change image quality. Optional `aggressive`, `compression` (0-100, higher is smaller), `downscale`, `removeAudio`, `playbackSpeed`, `pdfDPI`, `stripMetadata`. | `{"paths": ["~/Desktop/shot.png"]}` |
| `esclop_convert` | Change format: `format` is webp, avif, jpeg, png, heic, jxl, gif, tiff, bmp, mp4, mov, webm, mkv, hevc, av1, gif-video, mp3, aac, m4a, opus, flac, wav. | `{"paths": ["clip.mov"], "format": "mp4"}` |
| `esclop_downscale` | Scale down by `factor` (0.5 is half the width and height). | `{"paths": ["~/Pictures/big"], "recursive": true, "factor": 0.5}` |
| `esclop_crop` | Exact `width`/`height`, `longEdge`, or `aspectRatio` (16:9), `smart` to keep the subject. | `{"paths": ["card.png"], "width": 1200, "height": 630}` |
| `esclop_fit_under_size` | Shrink until each file is under `maxSize` (2MB, 500KB, bytes). | `{"paths": ["video.mp4"], "maxSize": "25MB"}` |
| `esclop_strip_metadata` | Remove EXIF, GPS and other metadata; re-encoding depends on the format. | `{"paths": ["photo.jpg"]}` |
| `esclop_crop_pdf` | Set every page's crop box to `aspectRatio` (3:4, or A4, Letter, iPad, Kindle Paperwhite, reMarkable 2, ...); `extend` pads instead of cutting. Reversible. | `{"paths": ["paper.pdf"], "aspectRatio": "Kindle Paperwhite"}` |
| `esclop_uncrop_pdf` | Reset every page to its full size. | `{"paths": ["paper-cropped.pdf"]}` |
| `esclop_pipeline_list` | Saved pipelines (what they do, triggers, problems) and built-in presets. | `{}` |
| `esclop_pipeline_show` | One pipeline's text and summary. | `{"name": "to WebP"}` |
| `esclop_pipeline_write` | Save a pipeline; mistakes come back with line, column and fix. | `{"name": "blog", "steps": "crop(longEdge: 1600) -> convert(to: webp)"}` |
| `esclop_pipeline_delete` | Delete a saved pipeline (to the Trash). | `{"name": "blog"}` |
| `esclop_pipeline_run` | Run a saved pipeline, a preset or inline steps on files. | `{"pipeline": "optimise -> convert(to: avif)", "paths": ["a.png"]}` |
| `esclop_pipeline_attach` | Add a trigger: clipboard, dropZone, presetZone, rightClick, cli, mcp or a folder path. | `{"pipeline": "blog", "trigger": "~/Desktop/To blog"}` |
| `esclop_pipeline_detach` | Remove a trigger from one pipeline or from all. | `{"trigger": "clipboard"}` |
| `esclop_pipeline_preset` | `list` and `install` built-in presets; `add`/`remove` a preset zone. | `{"action": "add", "name": "to WebP"}` |
| `esclop_settings_schema` | Every setting with value, type, allowed values; `query` narrows it. | `{"query": "agent permission"}` |
| `esclop_settings_get` | One setting. | `{"key": "allowRunScripts"}` |
| `esclop_settings_set` | Change one setting (string form of the value). | `{"key": "...", "value": "true"}` |
| `esclop_status` | Version, app, engine, permissions, paths, and whether this client can answer questions. | `{}` |
| `esclop_start_app` / `esclop_stop_app` | Open or quit the menu bar app. | `{}` |
| `esclop_recent_results` | Latest results, newest first. | `{"limit": 10}` |
| `esclop_restore_backup` | Put an original back from its backup. | `{"path": "~/Desktop/shot.png"}` |
| `esclop_logs` | Recent log messages and log files. | `{"window": "30m"}` |

### Resources and prompts

- `esclop://results/recent`: the last 50 results as JSON.
- `esclop://settings`: every setting with its value and JSON schema.
- `esclop://pipelines/{name}`: a saved pipeline's text (each saved pipeline is also listed).
- Prompt `write_pipeline` (`goal`, optional `fileType`, `name`): the full step reference and
  instructions to write and save a pipeline for the goal.
- Prompt `shrink_for` (`platform`: email, slack, web, app-store; optional `paths`): concrete
  targets for each destination and which tools reach them.

Trigger tools save configuration; automatic clipboard, drop-zone and folder triggers await
GUI integration. App start/stop tools do not provide the planned optimisation UI yet.

## Permissions

Every request from the MCP server carries origin `mcp`. Set permissions through the CLI,
for example `esclop settings set allowOverwriteOriginals true`, or in the app's Settings →
Agents and MCP (`esclop://settings/agents`). Each switch defaults to off and cannot be changed
through MCP. Refusals name the switch and its link, such as
`esclop://settings/agents/allowRunScripts`, so the agent can pass it on to the person.

| Setting | Off (default) | On |
|---|---|---|
| `allowOverwriteOriginals` | Results are written next to the original; `location: inPlace` and `esclop_restore_backup` are refused; pipelines run on copies. | Files may be replaced in place (a backup is always kept); pipeline steps may delete files. |
| `allowDeleteBackups` | `esclop_restore_backup` keeps the backup. | `deleteBackup: true` is allowed. |
| `allowRunScripts` | Pipelines with `runScript` or `runShortcut` steps are refused (saving, running, attaching). | They may be saved and run. |
| `allowSettingsChanges` | Settings, triggers and preset zones stay as they are; replacing a pipeline or deleting one that has triggers is refused. | Agents may change them. |

An `output` path never lands on a file that exists, or on one file for several sources, unless
overwriting is allowed; pipeline `copy`, `move` and `rename` steps do not replace existing files
either. Writing a new pipeline, running pipelines and every read-only tool need no permission. A refusal
comes back as `notPermitted` naming the switch; agents should tell the person rather than look for
another way. The app-side request handler implements the same checks. The gate covers
MCP requests: an agent that can run shell commands can also run the `esclop` command line, which
acts for the person (origin `cli`) like any other program they run.

### Questions to the person

When a choice is missing (a format for `esclop_convert`, a factor for `esclop_downscale`, a size
for `esclop_crop` or `esclop_fit_under_size`, a ratio for `esclop_crop_pdf`), the server asks the
person through the client (MCP elicitation). The question waits 120 seconds
(`ESCLOP_MCP_ELICIT_TIMEOUT` changes it). If the client cannot ask, or nobody answers, the tool
fails with `needsInput` and the options, so the agent can ask in the chat and call again.

## Troubleshooting

- **Start with `esclop_status`** (or `esclop status` in a terminal): it says whether the app is
  running, which engine runs in-process, what agents may do and where files live.
- **"Missing tool: esclop-engine"** (or ffmpeg, gifsicle): the server cannot find a bundled
  tool. From a checkout, run `Scripts/build-tools.sh` and `Scripts/build-engine.sh`, or point
  `ESCLOP_BIN` at a folder that contains the tools.
- **The agent does not see the tools**: run `esclop mcp status`. `installed, other command` means
  the entry points at another `esclop` (a moved app, a dev build): run `esclop mcp install <id>`
  again. Then restart the agent.
- **"config unreadable"**: the agent's config file is not valid JSON/TOML/YAML; the installer
  leaves it alone. Fix the file (the message has the position) and install again.
- **Codex: "written inline"**: `config.toml` defines `mcp_servers` as an inline table. Rewrite it
  as `[mcp_servers.<name>]` tables and install again.
- **Logs**: `esclop logs --last 30m` or the `esclop_logs` tool. The server writes its own
  diagnostics to stderr, which most agents show in their MCP log.
- **By hand**: `Scripts/mcp-smoke.sh` pipes a few JSON-RPC requests into the server and prints
  the replies.

Environment variables, mostly for testing: `ESCLOP_NO_APP=1` never uses the app;
`ESCLOP_SUPPORT_DIR` moves all of esclop's data (pipelines, recent results, backups);
`ESCLOP_PIPELINES_DIR` moves only the pipelines; `ESCLOP_MCP_ELICIT_TIMEOUT` sets the question
timeout in seconds.

## For developers

- `Sources/EsclopIPC`: the app protocol. `AppServer` listens on `dev.esclop.app.request`, `.stop`,
  `.settings` and `.control` (CFMessagePort, JSON envelopes with a protocol version); each client
  opens `dev.esclop.app.reply.<uuid>` for progress and responses. `AppClient` is the CLI/MCP
  side, `AppServer` plus `AppRequestHandler` the app side, `JobExecutor` the in-process runner the
  app can reuse, `AgentPolicy` the permission gate both sides apply.
- `Sources/EsclopMCP`: `EsclopService` (routing to the app or in-process, pipelines, settings,
  status, restore, logs), the MCP server on the official Swift SDK, tools, resources, prompts,
  and the agent installers (`AgentCatalog`, `AgentInstaller`, JSONC/TOML/YAML splice editors).
- `Sources/esclop`: the command line. `Integrations.swift` chooses the engine (`EsclopEngine`),
  the settings (`SettingsRegistry` through `RegistrySettingsProvider`) and the pipeline store.
- Tests: `Scripts/test.sh` builds `esclop` and runs every suite, including the stdio conformance
  test in `Tests/esclopTests/MCPConformanceTests.swift`.
