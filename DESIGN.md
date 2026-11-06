# Design brief

This brief describes the planned GUI. The current app is a minimal menu-bar stub.
Results should be easy to read without interrupting work. The app should look like a
first-class macOS 27 citizen: Liquid Glass materials, native controls, SF Pro and SF Symbols.

References in [docs/design](docs/design): an interactive prototype
([floating-result-prototype.html](docs/design/floating-result-prototype.html), open it in a
browser) and storyboards of the floating result and the options popover. The prototype fakes
file operations and approximates glass with CSS; the rules below win where they differ.

## Floating result
One object at the bottom-right corner of the screen, with the geometry and gesture of the
system screenshot thumbnail. It has three levels; the person moves between them on purpose.

1. **Thumbnail (default).** About 200 pt wide, slides in from the right edge. While
   compressing, a specular sheen sweeps the picture and a progress hairline runs along the
   glass rim. On finish the picture deflates in one spring (scale 1 → 0.95 → 1) and a glass
   capsule pinned to the bottom edge counts down to the result: "612 kB · −75 %".
2. **Detail.** Opened by clicking the capsule or holding the pointer still for 600 ms. A plain
   pass of the pointer only shows the hover buttons. The card grows from the bottom-right
   anchor to 320 pt: before/after comparison with a draggable divider, the deflate bar (full
   original size contracting to the new proportion), metrics, a quality chip shown only when
   the engine can justify it, and actions.
3. **Activity.** Only when a job is expected to take longer than 2 s (video, large PDFs). A
   glass capsule grows out of the thumbnail's left edge with a progress ring and the time left,
   turns into the result, and retracts after 2 s.

Hover shows a row of 28 pt round glass buttons above the thumbnail: Undo, Convert, Downscale,
Crop and "…". The set is configurable. The buttons float above the thumbnail, so the
object never changes size under the pointer. The thumbnail drags out as the file (the original
after a restore). Errors keep the original and say so in the capsule;
clicking it retries. Several results in a row: show the newest three with 8 pt gaps, newest at
the bottom, older ones go to the menu-bar history; never stack expanded details. Dismissal
pauses while the object is hovered, focused, dragged or open.

## Options popover
Opens from the "…" button of the floating result, anchored to it with a popover arrow, and acts
on that one file. It replaces a long context menu. It is not the menu-bar menu. Width about
360 pt, never taller than 560 pt.

- **Header:** thumbnail, editable filename, "2,4 MB → 612 kB · −75 %", format and dimensions
  (duration and bitrate for media, pages and DPI for PDFs).
- **Tabs** (segmented control): Optimise · Size · Share. Audio replaces Size with Sound.
- **Optimise:** first a suggestion chosen from the file's origin (see below), then a folded
  "Format and options" group: compression (Adaptive · Lossless · Aggressive), format tiles
  with size estimates (⌥ keeps both files), quality slider with estimate, strip metadata, HDR
  to SDR (HDR input only), re-optimise with another encoder, restore original (⌘Z). Video, PDF
  and audio show their own controls here: playback speed, remove audio, GIF and still frame;
  DPI, pages as images; bitrate and loudness.
- **Size:** downscale slider in 10 % steps with live dimensions and size, restore 100 %, fit
  under 500 kB / 1 / 2 / 5 MB / custom, crop aspect chips and the crop editor.
- **Share:** a row of round buttons (Copy ⌘C, AirDrop, Save as ⌘S, Show in Finder ⌘R, Quick
  Look Space, Share…), then drill-downs: Open with, Run a Shortcut, Run a pipeline, Add to
  shelf app, Upload with Dropshare. Footer: keep visible duration, customise hover buttons.
- Every choice that changes size shows an estimate before it is applied. Long lists are
  drill-downs inside the popover, never inline walls. Only installed apps are listed.

## Origin rules
The suggestion comes from where the file came from and its format.

| Origin signal | Suggestion |
|---|---|
| Screenshot (screenshot metadata or file) + PNG | PNG, adaptive quantisation for sharp text, strip metadata |
| Photos export + HEIC | JPEG, adaptive, strip location |
| Browser + WebP | Keep WebP, adaptive |
| Alpha channel, graphic content | PNG, keep transparency |
| Animated GIF | Animated WebP, keep timing |
| Screen recording | HEVC, 30 fps, strip metadata |
| Exported PDF / voice memo | PDF at 150 DPI keeping text / AAC 96 kbps, −16 LUFS |

`NSPasteboard` does not reliably name the source app, so origin is a heuristic from screenshot
metadata, UTTypes and optional source hints. Unknown origin gets conservative defaults; never
infer Photos from HEIC alone.

At the bottom of Optimise a small native checkbox turns the current choice into a rule:
"Always apply to PNG screenshots". The rule key is origin + input format. Unticking deletes the
rule, so the next item of that kind gets the default behaviour again; ⌘Z only restores the
current file. When a rule was applied, the result capsule shows a small rule glyph with the
tooltip "Rule: PNG screenshots → WebP", and the popover opens with the box ticked. Rules are
listed and edited in Settings › Automation › Clipboard rules.

## Color
Use system Liquid Glass materials for floating surfaces, with one accent colour and one warning
colour.

| Token | Light | Dark | Role |
|---|---|---|---|
| `accent` | `#1E7F6A` | `#3DBF9F` | savings, progress, primary actions |
| `warm` | `#B8741C` | `#E0A040` | aggressive mode, "fit under size" |
| `ink` | `#1B1F1E` | `#F2F4F3` | primary text (used only where system label colors cannot) |
| `clog` | `#8A5A33` | `#8A5A33` | app icon wood only, never in UI |
| error | system red | system red | failures |

Never: cream page backgrounds, terracotta, acid green on black, gradient washes. Dark glass
stays translucent; it must not become an opaque slab.

## Type
System font (SF Pro) everywhere, sizes from the macOS text styles, nothing below 11 pt. Byte
figures and percentages use SF Pro with monospaced digits (`monospacedDigit()`), never a
monospaced typeface. The saving percentage is the one large figure: `title2`, semibold,
rounded design. Labels are sentence case, never all caps, never tracked out. Icons are SF
Symbols; checkmarks are symbols, not text glyphs.

## Layout
- Floating result: non-activating `NSPanel` placed against `NSScreen.visibleFrame`; it never
  takes focus from the working app. SwiftUI content in a `GlassEffectContainer` with
  `glassEffect`, sharing glass identity so thumbnail, detail and activity morph into each other.
  On macOS 14–25, which lack Liquid Glass, fall back to `NSVisualEffectView` with the
  `.hudWindow` material and a 1 pt hairline border; geometry and motion stay the same.
- Radii are concentric: 12 pt thumbnail shell with a 9 pt picture inside, 24 pt detail card with
  12 pt picture, 22 pt popover. Controls use capsules or the system's control radius.
- Drop zone: a single rounded glass shape at the cursor or screen edge, label "Drop to
  optimise"; holding Command changes it to "Drop to optimise harder".
- Settings: sidebar panes with the search at the top of the sidebar, grouped forms with native
  controls (switches, menus, sliders with their figure, fields with a stepper and unit). Each
  row has its title and a one-line explanation; a reset arrow appears beside the title while
  the value differs from the default. A typed value is checked as it is typed, and a refused one
  keeps the field and says why under the row in red. A deep link scrolls to its row and marks
  it with an accent wash that fades after 2.5 s (no scroll animation with Reduce Motion).

## Motion
| Event | Motion |
|---|---|
| Thumbnail enters | slide from the right, 220 ms |
| Result | deflate spring, 450 ms; capsule figure counts down over the same 450 ms |
| Hover buttons | fade in, 180 ms |
| Detail opens | grow from the bottom-right anchor, 400 ms spring; deflate bar contracts in 450 ms |
| Activity capsule | grows from the left edge, 350 ms; retracts 2 s after the result |
| Popover | scale 0.97 → 1 and fade, 160 ms; tab change 100 ms |

No idle motion after a result. Reduce Motion replaces slides, deflate, morphs and the sheen with
180 ms crossfades and shows final figures without counting. Reduce Transparency uses opaque
system backgrounds with a contrasting border.

## Accessibility
Every hover action is also reachable by keyboard and VoiceOver as a named action. The popover
supports arrow keys, Return, Escape and the listed ⌘ shortcuts. VoiceOver announces each result
once ("Optimised, 612 kB, 75 % smaller").

## Copy
Say what happens: "Optimise", "Convert to WebP", "Fit under 1 MB", "Undo", "Keep original".
Errors say what went wrong and what to do: "ffmpeg is missing. Reinstall esclop or run
Scripts/build-tools.sh". The Catalan localisation uses the strings shown in the storyboards
("Optimitzat", "Desfés", "Aplica-ho sempre a les captures de pantalla PNG").

## Icon
The approved app icon is a carved Dutch wooden clog in three-quarter view on an `accent`
macOS squircle, sized to Apple's icon grid: 824 px wide on the 1024 px canvas. Preserve the wood artwork in `assets/icon-wood.png`; `assets/icon.svg` composes
it with the background. The monochrome mark is `assets/mark.svg`. The menu bar uses the
rounded optical variant in `assets/menubar.svg`, a 28 × 18 pt template image with a transparent
foot cavity. It keeps the high vamp and raised toe without wood texture. Regenerate the PNG,
ICNS and menu bar PDF with `make icons`. The branding is original and independent of Clop.
