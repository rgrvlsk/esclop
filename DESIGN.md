# Design brief

This brief describes the GUI.
Results should be easy to read without interrupting work. The app should look like a
first-class macOS 27 citizen: Liquid Glass materials, native controls, SF Pro and SF Symbols.

References in [docs/design](docs/design): an interactive prototype
([floating-result-prototype.html](docs/design/floating-result-prototype.html), open it in a
browser) and storyboards of the floating result and the options popover. The prototype fakes
file operations and approximates glass with CSS; the rules below win where they differ.

## Floating result
One object at the bottom-right corner of the screen, with the geometry and gesture of the
system screenshot thumbnail. The look follows [docs/design/targets](docs/design/targets) on the
`design/ui-overhaul` branch. It has two levels; the person moves between them on purpose.

1. **Card (default).** A 208 pt cream card: the picture at its own aspect ratio over a footer.
   Work in progress tints it aqua with a straight bar and the time left for long jobs; a saving
   gets the ring with the figure, the original size in brick red and the new one in grey; a
   failure tints it amber (`pr2-failed-not-uploaded`): a red triangle and what did not happen
   ("Not optimised", "Not uploaded") with Retry beside it, and under them, across the card,
   why and that nothing was lost ("The original is untouched.", "The file is kept.").
2. **Detail.** Opened by a click, Return or Space, or VoiceOver's action; never because the
   pointer rested. The card grows to 320 pt: the picture, the name with format and
   dimensions, the saving at the next size up, and the actions as 1 + 2 + "…": the most likely
   action in charcoal with what it acts on (Show in Finder and the folder, or Copy for a copied
   screenshot), up to two round buttons (Copy, Undo), and "…" for the rest: Convert… (the
   options: format, size, crop), Compare where there is an original, Share…, then Save as… for a
   copied image or Move to Trash for a file of the person's. × sits in its own band above the
   picture; × and Esc close it. The picture is fitted whole, 120 to 200 pt tall.
   In a right-hand corner the row runs the other way, so "…" faces the screen.
3. **"…" menu.** A panel in the card's fill outside the card, on the screen side, joined to "…"
   by a liquid neck: one outline for button, neck and panel, with one hairline and one shadow.
   It opens as a drop that leaves the button, travels out round, then spreads into the panel
   (spring, 0.34 s response, 0.72 damping); the rows fade in where they stand once the drop
   has its full width, after 200 ms, 18 ms apart. It closes the other way: rows out in 70 ms,
   then the panel sinks back in 160 ms. Reduce Motion crossfades the open shape in 120 ms. Arrows,
   Home and End move, Return or Space runs, Esc or a click elsewhere closes, and so does
   turning to another window. The panel takes the keys while the menu is open, even with
   another app in front, without activating L'Esclop. Share… shows the system's share
   services at "…".
4. **Loupe** (`pr6-compare-loupe`). Compare in the detail, for a picture that lost detail (JPEG,
   WebP, AVIF, HEIC, JPEG XL, quantised PNG): the picture becomes a loupe. A lens 124 pt across
   (smaller in a short picture) shows the file at true size, one file pixel to one screen pixel
   and at least twice the picture's scale, up and to the left of the pointer, so the pointer
   sits on its rim and never hides what it points at. A label on its top edge says which side
   shows: ORIGINAL in charcoal, OPTIMISED in cream. A click swaps and stays; a press swaps
   while held (over 250 ms or 4 pt) and swaps back on release. The swap is a cut. The action
   row gives its place, at its height, to a hint ("Click or hold to see original", "Release to
   see optimised") and Done, so nothing in the detail moves. Space swaps, the arrows move the
   lens 8 pt, Esc, Return or Done end it; × still closes the detail. The picture does not drag
   out while the loupe is on. Other files compare in the Compare window.

Hover shows three round buttons over the picture's corner (Copy for a copied screenshot, Show
in Finder for a file, then Undo and "…") and a close button over its outer corner, so the
object never changes size under the pointer. The card glows in the picture's tone. The picture
drags out as the file (the original after a restore). Errors keep the original and say so in
plain words ("This file isn't a video L'Esclop can read. It may be damaged.").
Several results in a row: show the newest three, newest at the bottom, older ones go to the
menu-bar history; never stack expanded details. Two or more failures share one of the three
places (`pr2-failures`): an amber pill, "3 not optimised" ("not uploaded" for uploads, "failed"
for a mix), that a click opens into their list, 320 pt wide, under an amber header in the serif:
each file with its picture, why, and Retry, or no button when the file is gone ("The file was
moved or deleted."); four rows show, more scroll; Retry All and Dismiss close it. An open list
stays while one failure is left, so nothing changes under the pointer. Failures never hide on
their own.
Dismissal pauses while the object is hovered, focused, dragged or open.

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
  shelf app, Upload with Dropshare. Footer: keep visible duration.
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

## Batch window
When a job brings more files than the stack of three floating results can show (four by
default, `batchWindowFrom`), they go to one window instead: a dropped folder, "Optimise Files…",
many copied files, or a list from the CLI or an agent. It comes forward without taking focus.

- **Header:** "Optimising 7 of 9 files", "48 MB → 12 MB" and the saving as the one large figure
  ("−75 %", rounded, in the accent), the bar (progress while running, then the deflate bar at
  the new proportion), the counts ("5 optimised · 1 already optimised · 1 failed") and Pause,
  Stop, Restore All, Show in Finder.
- **Rows:** thumbnail, name, sizes or status, the file's own deflate bar and its saving. On hover
  the saving gives way to 28 pt round buttons (restore, try again, stop, copy, Show in Finder);
  the same actions are in the context menu and are VoiceOver actions.
- Pause holds the files still waiting; the ones running finish. Stop keeps every original. New
  files join a batch that is still running. VoiceOver announces the batch once, when it ends.

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
- Radii: the 208 pt result card is 20 pt with a 14 pt picture inset 9 pt, a photo in a mount
  rather than concentric corners; 24 pt detail card with a 12 pt picture, 22 pt popover. Controls use capsules or the system's control radius.
- Drop zone: a single rounded glass shape at the cursor or screen edge, label "Drop to
  optimise"; holding Command changes it to "Drop to optimise harder". Preset zones sit beside
  it, toward the screen, as a 2 × 2 grid of 92 × 64 pt dashed squares (symbol and name, two
  lines at most); the one under the drag fills with the selected fill and its symbol turns
  accent. Text and icons use the popover's inks on its near-opaque surface.
- Settings: sidebar panes with the search at the top of the sidebar, grouped forms with native
  controls (switches, menus, sliders with their figure, fields with a stepper and unit). Each
  row has its title and a one-line explanation; a reset arrow appears beside the title while
  the value differs from the default. A typed value is checked as it is typed, and a refused one
  keeps the field and says why under the row in red. A deep link scrolls to its row and marks
  it with an accent wash that fades after 2.5 s (no scroll animation with Reduce Motion).
- Onboarding: one 640 × 560 window with a transparent title bar, five steps (welcome, automatic,
  permissions, agents, done) and a footer with Skip, step dots and Back/Continue. Steps slide in
  the direction of travel (350 ms spring); Reduce Motion turns it into a 180 ms crossfade. The
  steps reuse Settings rows, so a switch flipped in the tour is the same setting.

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
