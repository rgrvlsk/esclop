# Attribution

esclop is inspired by [Clop](https://github.com/FuzzyIdeas/Clop) by Alin Panaitiu
(lowtechguys), published under the GNU GPL v3. Where esclop reuses Clop code, the file says so
in its header and is listed here. Everything else is original work, also under GPL-3.0-or-later.

All reused code comes from Clop at commit `4be5106` (2026-10-16) or earlier and keeps its
original copyright header plus a dated modification notice (GPLv3 §5a).

| L'Esclop file | Clop source (commit 4be5106) | What was kept, what changed |
|---|---|---|
| `Sources/EsclopOptimisers/CompressionCurves.swift` | `Shared.swift` | Kept: the curves that map one compression factor to JPEG quality, PNG quantisation range and speed, gifsicle `-O`/`--lossy`/`--colors`, WebP/AVIF/HEIC quality, ImageIO qualities, VideoToolbox H.264/HEVC `-q:v`, SVT-AV1 CRF and preset, VP9 CRF. Changed: dropped the tier enum and the x264/x265 paths; image curves feed esclop-engine parameters. |
| `Sources/EsclopOptimisers/GhostscriptArguments.swift` | `Clop/PDF.swift` | Kept: the pdfwrite argument set, distiller parameters, DOCINFO clearing, QFactor at low DPI, DPI stops and the per-document DPI choice with the low-outlier fence. Changed: `-dSAFER` first, image scan rewritten as a plain function, no parallel-page path, progress UI or settings plumbing. |
| `Sources/EsclopOptimisers/AudioEncoding.swift` | `Clop/Audio.swift`, `Shared/AudioFormat.swift` | Kept: per-codec bitrate ranges, factor-to-bitrate curve, allowed bitrate steps, LAME VBR mapping and ffmpeg encoding arguments. Changed: mapped onto `OutputFormat`, fallback from AudioToolbox AAC to ffmpeg's AAC, no settings or UI. |

### Behavioural references (no code reused)

| L'Esclop module | Clop sources consulted | What matches |
|---|---|---|
| `Sources/EsclopIPC`, `Sources/EsclopMCP`, `Sources/esclop` | `Shared.swift`, `ClopCLI/main.swift`, `ClopCLI/MCPServer.swift`, `ClopCLI/MCPTools.swift`, `ClopCLI/MCPToolTable.swift`, `Clop/MCPInstaller.swift`, `Clop/MCPClients.swift` | CLI subcommand and flag names where Clop has them; which MCP tools exist and what an agent may do without the person's permission; asking the person (elicitation) only for a missing choice; which agents the installer supports, where each keeps its config and the shape of its entry, and editing those files in place. Port names, message formats, tool names and descriptions, the server and every editor are written from scratch. |
| `Sources/EsclopOptimisers` (engines) | `Clop/Images.swift`, `Clop/Video.swift`, `Clop/OptimisationUtils.swift`, `Clop/ClopUtils.swift`, `Clop/Xattr.swift`, `Clop/BatchBackup.swift`, `Clop/ClipboardType.swift` | Behaviour only: VFR passthrough for screen recordings, never flattening an animated GIF, JPEG to PNG when transparent, adaptive PNG/JPEG choice (100 KB margin), watermark placement (width fraction, 20 px margin), "optimised" marker on output, cover-art handling, video-to-GIF frame rate and quality. Written from scratch. |
| `Sources/EsclopPipelines` | `Clop/Automation.swift`, `Clop/Pipeline.swift`, `Clop/PipelineStep.swift`, `Clop/PipelineExecution.swift`, `Shared/FileNameTemplate.swift`, `ClopCLI/main.swift` | The pipeline language (step names, arguments, defaults, value spellings), template tokens and location rules, so Clop pipelines run unchanged. Parser, serializer, runner and store are written from scratch. |

Bundled tools and their licences are recorded in `Binaries/LICENSES/` and `THIRD_PARTY.md` by
`Scripts/build-tools.sh`; Rust crate notices are generated with `cargo about`.
