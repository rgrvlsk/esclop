# Design proposal

Status: round 4, under review. It answers [critique.md](critique.md). Nothing here is built into
the app yet: the pictures come from prototype views in `Tests/EsclopAppTests/Prototype`, drawn
with real SwiftUI and AppKit and captured as real windows, so glass is the system's Liquid Glass.
Render them with `ESCLOP_RENDER_DIR=<folder> Scripts/test.sh --filter 'PrototypeRenderTests'`.
A render is named `proto-<name>-light.png` or `-dark.png`; the second direction's renders are
`proto-own-<name>-…`.

## The owner's answers

1. **Menu:** a custom panel under the glyph, not a native menu.
2. **Voice:** sparse. A label alone, and one sentence only where a choice has a consequence.
3. **Motion:** lively, never kitsch. Alive on the elements that are singular or mean something,
   quiet everywhere else.
4. **Brand:** two directions compete, at the owner's request, over one structure:
   - **A, Native:** system Liquid Glass and controls; the system accent on controls; the green
     has one job; the clog lives in the glyph.
   - **B, Own:** a surface of the app's own (boxwood in light, walnut in dark), the wood of the
     icon as a second colour, the green on controls as well as on the saving, and the carved
     wooden clog in the drop zone, the empty states and the first run.

Everything below holds for both unless a line says "A" or "B".

## Five rules

1. **One material.** Everything that floats (result, menu panel, options, drop zone) shares one
   surface and one elevation. Every window is stock chrome.
2. **One green, one job.** `saving` marks the saving: the figure and the saved part of a bar. At
   most one green figure per surface. (B also tints controls with it.)
3. **The picture is never covered.** Figures sit beside or under a picture, never on it.
4. **One figure per surface.** SF Pro Rounded semibold, and only for a saving. Everything else
   is SF Pro at 13, 12 or 11 pt.
5. **Motion goes where the meaning is.** Four moments are alive: a result arriving, a drag
   reaching the drop zone, the glyph working, the first run. Everything else moves in under
   200 ms without overshoot, or not at all.

## Tokens

| Token | A, Native | B, Own |
|---|---|---|
| Floating surface | Liquid Glass as a layer under the content, with a backing in the appearance's own tone over it (white 97 % or 13 %, at 88 %; 94 % under shapes shorter than 44 pt), so the ground under the ink is bounded whatever the desktop is; HUD material before macOS 26 | opaque: `#F6F0E8` in light, `#2B2521` in dark. Wood does not transmit. |
| Elevation (both) | shadow y 8, blur 24, black 20 % light and 45 % dark; inner rim 0.5 pt, white 35 % light and 14 % dark; outer hairline 0.5 pt, black 10 % light and 30 % dark | same |
| `saving` | `#176B59` light, `#63D6B8` dark | same |
| `warm` (aggressive) | `#8F5510` light, `#E0A040` dark | same |
| `error` | `#C4281C` light, `#FF6961` dark | same |
| Kept part of a split bar | ink at 32 % | pale wood `#D8BF9F` light, dark wood `#6E5746` dark: 3:1 against `saving` by lightness, not by hue |
| Text on the surface | black at 88 % light, white at 92 % dark | same |
| Secondary text on the surface | black at 62 % light, white at 62 % dark | `#625C56` light, `#B9AFA5` dark |
| Fill of a filled control | system accent | `#176B59` light, `#1C8068` dark (white content holds 4.5:1); rings and strokes use `saving` |
| Lit drop tile | `#0A60D8` (the selection blue), white text | `#176B59`, white text |
| Lit tile, aggressive | `#8F5510`, white text | same |
| Controls and selection | system accent | `saving` |
| Text | system label colours | same |

Ink on a floating surface is pinned: it is never the system's vibrant label colour, and the
glass sits under the content rather than around it, so the system cannot flip what the app draws
to suit the desktop. `saving`, text and secondary text hold at least 4.5:1, and the `warm` mark
3:1, on the floating surface over a white, a black and a busy desktop, in both appearances and
both directions; white holds 4.5:1 on a lit tile. This is a test, and it measures rendered
pixels, not a model: `PrototypeRenderTests.inkContrastOnRenderedSurfaces` draws each ink as a
square on the surface over each ground (`proto-ink-probe-*`) and fails under the bar. It failed
on the first run and found the flip.
Lit tiles use one fill in both appearances so their white text never drops. B is a skin of the
floating surfaces and the control tint; its windows are stock, as A's are.

Type, all SF Pro, digits monospaced, the percent sign after a narrow no-break space (U+202F):

| Role | Size and weight |
|---|---|
| Figure (savings only) | Rounded semibold, four steps: 17 (card, compare), 24 (panel, popover), 34 (detail, batch, all results), 44 (first run) |
| Title | 13 semibold; 22 semibold for a document; 24 semibold for a panel state ("Paused"); 28 semibold in the first run |
| Body | 13 regular |
| Label on a floating surface | 12 medium |
| Caption | 11 regular, secondary. Nothing smaller, anywhere. |

Geometry: a 4 pt grid (4, 8, 12, 16, 24). Radii are concentric, outer = inner + padding, and
there are six: 6 (key caps, 40 pt thumbnails in lists), 10 (the card's picture, children of a
panel or popover), 14 (card, the detail's picture), 18 (drop tiles), 22 (detail, panel,
popover), and capsules or circles for controls on a floating surface. Neutral fills have three
strengths: 6 % (resting), 14 % (a button, a selected tile), 20 % (pressed). Every pointer target is at least 28 × 28 pt, 4 pt apart.
Floating objects are 8 pt apart; drop tiles 12 pt.

Symbols: one meaning each. Undo `arrow.uturn.backward`; Undo All `arrow.uturn.backward.circle`;
Optimise Again `arrow.uturn.forward`; Copy `square.on.square`; Options `ellipsis`; Compare
`rectangle.split.2x1`; Show in Finder `folder`; Stop `stop.fill`; fit under a size
`arrow.down.right.and.arrow.up.left`; convert `arrow.triangle.2.circlepath`; try another
`arrow.clockwise`; aggressive `bolt.fill`; rule `pin.fill`.

## Floating result

`proto-result-states`, `-states-hover`, `-stack`, `-detail`, `-busy`, `-on-white`, `-on-black`,
`-notice`.

One card, 208 pt wide, at the chosen corner, 16 pt from the screen edges. The picture is on top
at its own aspect ratio (72 to 190 pt tall); under it a 34 pt footer inside the same surface.
The footer is the only part that changes. Picture and footer are one object: either drags the
file, either opens the detail.

| State | Footer, left | Footer, right | On hover, right becomes |
|---|---|---|---|
| Working | "Optimising" | time left ("4 s") for jobs over 2 s | Stop |
| Uploading | "Uploading" | "40 %" | Stop |
| Done | **−75 %** in `saving` | "612 kB" | Undo, Copy, Options |
| Done, aggressive | **−75 %**, `bolt.fill` in `warm` | "612 kB" | Undo, Copy, Options |
| Done by a rule | **−75 %**, `pin.fill` | "612 kB" | Undo, Copy, Options |
| Nothing to gain | "Already optimised" | "612 kB" | Copy, Options |
| Undone | "Original restored" | "2.4 MB" | Optimise Again, Options |
| Uploaded | `link`, "Link copied" | "−75 %" in secondary | Copy Link, Options |
| Failed, another try can help (upload refused, file busy) | `exclamationmark.triangle.fill` in `error`, "Not optimised" | **Retry** (always shown, 28 pt) | |
| Failed, it cannot (unreadable file) | the same | **Show in Finder** (always shown) | |

Working shows progress as one 2 pt neutral line at the footer's top edge, wholly inside the
footer and inside the picture's corners (track ink 24 %, fill ink 70 %). There is no sheen, rim,
ring or wing. A dropped file's card enters Working at once; any other job shows Working once it
has run for 1 s, and enters done if it finished sooner.

Pointer:

- **Hover:** after 80 ms of intent, the footer's right side becomes the state's buttons (fade
  120 ms, 200 ms grace on leaving), and a 20 pt close button shows centred on the card's outer
  top corner (28 pt target, clipped to the card's own slot and half the gap, so it never takes
  a click meant for the card above). The footer keeps one baseline in every state: the buttons
  lie over its right side, so the figure does not move by a pixel; the card keeps its size; no
  neighbour moves. The first button is always the way back or forward (Undo, then Optimise
  Again), so a second click stays on it. The buttons stay while a popover, a menu or the detail
  of that card is open.
- **Click** the picture or the footer: opens the detail. Nothing opens because the pointer
  rested.
- **Drag** the picture or the footer: drags the file out; the card's picture and ink dim, its
  surface does not. In the detail too, the picture drags the file.
- **Two-finger swipe** toward the screen edge: the card follows the fingers 1:1 and leaves past
  40 % of its width or 500 pt/s; otherwise it returns (spring 0.35 / 1.0).
- **Failed, clicked:** the card grows by one caption, away from the screen corner and over its
  neighbours: what went wrong, and that the original is untouched.
- Buttons that appear under a pointer that was already there take clicks only once their fade
  has ended, so a click meant for the footer never lands on a button.

Keyboard: ⌃⇧R (new, global) moves focus to the newest result, or opens the menu panel when
there is none. The focused card draws the system focus ring and shows its buttons, which Tab
walks (so Options, Retry and Optimise Again have a key). ↑ ↓ move between results, Return opens
the detail, ⌘Z undoes, ⌘C copies, ⌘R reveals, Space is Quick Look, ⌘. stops a working one, and
⌫ dismisses the card. Esc only ever backs out one level: popover, then detail, then focus, which
returns to the app that had it; the cards stay and their timers resume with at least 5 s left.
Esc never removes anything.

Stack: three slots, always (`proto-result-stack`, `-stack-failures`). A new result enters at the
end away from the corner and the oldest leaves. Failures share one slot: "3 not optimised" with
one Retry for all; clicking it opens All Results. A card is held while it is hovered, pressed,
focused, dragged or open, and every card is held while a file drag is live anywhere. While the
pointer is within the stack (plus 8 pt) or any card is held, no slot moves: an arrival replaces
the oldest card that is not held, in place, with a 150 ms crossfade, and that slot takes no
click for 300 ms; if all three are held the arrival goes to the panel only. A card never changes
identity under the pointer. Slots settle and re-sort by age 400 ms after the pointer leaves
(spring 0.35 / 1.0). Older results are in All Results.

Auto-hide: 10 s for a copy, 30 s otherwise; paused while hovered, focused, dragged or open, and
at least 5 s remain after the pointer leaves. A failed result stays. With VoiceOver running
nothing hides on its own.

**Detail.** The same card grown to 320 pt from its corner, over its neighbours: the ones it
covers fade out (120 ms), the others dim, none moves. It grows away from the corner and becomes
key, so Esc reaches it. It holds the comparison (the divider moves from its handle and its
line, a 44 pt strip, and with ← → by 5 %; the rest of the picture drags the file, as on the
card), "Original 2.4 MB" and "612 kB Optimised" under their
halves, the figure at 34 pt with "1.8 MB saved", the split bar, one caption of facts, and Undo,
Compare, Options…. Esc, the close button or a click outside closes it.

**Split bar.** The whole width is the original. The left part is what is left (ink at 32 % in
A, `wood` in B); the right part, in `saving`, is what was saved. It is 6 pt tall everywhere, and
is hidden from VoiceOver, which reads the figure.

A notice (the pause hotkey) is a 34 pt capsule with a symbol, one line and the keys. Ink on a
floating surface is pinned to the appearance: the system's glass may not flip it to suit the
desktop, because the backing already bounds the ground (`-on-white`, `-on-black`).

## Menu bar

`proto-glyph`, `proto-menu-panel`, `-menu-panel-ca`, `-menu-panel-busy`.

**Glyph.** Three states, each drawn as its own vector (the renders stand in with a rotated and
an eroded copy). Idle: solid. Working, after 1 s of work: the clog walks on a 1 pt ground line
(heel raised 15°, then toe 8°, 280 ms each, ease-in-out), rests 1.4 s, and repeats while work
runs; it always finishes a step. Paused: a 1.5 pt outline. Reduce Motion: working holds the
raised heel over the ground line, a form of its own, so the state never rests on motion alone.
VoiceOver reads the status item as "L'Esclop", "L'Esclop, optimising" or "L'Esclop, paused".

**Panel.** A 316 pt panel under the glyph. It is a non-activating panel that always becomes
key, so the shortcuts it prints work; Esc or a click outside closes it and gives the key window
back. Pressing the glyph, dragging to a command and releasing activates it, as in a menu.

- **Header:** the day's saving as the figure ("−38 MB") over "today, across 14 files"; a Pause
  pull-down and a gear. The gear's menu: Settings… ⌘, · Check for Updates… · Show the Tour ·
  About L'Esclop · Quit L'Esclop ⌘Q.
- **Pause** menu: For the Next Copy · For 5 Minutes · For an Hour · Until I Resume. The
  hotkey has three steps, not five: the next copy, until resumed, resume. Paused, the header reads "Paused / Resumes at 14:32" (or "Until you
  resume") with Resume, and the status line reads "Watching nothing".
- **Recent results:** the last six as 92 × 64 pt pictures, 8 pt apart, each with its saving
  under it in secondary 11 pt. A picture drags out as the file. One is always selected, the
  newest when the panel opens: a row under the grid shows its name, sizes and Undo, Compare,
  Show in Finder. The row is always there, paused or not, so the commands never shift and ⌘Z
  has a visible target. With the grid focused, Return opens Compare, ⌘R reveals, Space is Quick
  Look, ⌘Z undoes. Double-click opens Compare. Nothing happens at the far corner.
- **Commands:** Optimise Files… ⌘O · Optimise Clipboard ⌃⇧C · All Results · Pipelines. (No
  ellipsis on the two that only open a window.) Holding ⌥ turns the first two into "…
  Aggressively"; ⌥Return does the same from the keyboard, and VoiceOver has it as an action.
  ⌘Z undoes the selected result.
- **A running batch** takes the status line's place: a spinner, "Optimising 7 of 9", Show.
  Nothing above it moves.
- **Status:** "Watching the clipboard and 2 folders".
- **Empty:** "Ready / Nothing optimised yet" and "Copy a screenshot. It lands here, smaller."
  (B: with the wooden clog.)
- **Keyboard:** Tab moves between header buttons, grid and commands; arrows move within; Return
  activates. VoiceOver reads a picture as "Beach 02.jpg, 54 % smaller, 1.1 megabytes" with Undo,
  Compare and Show in Finder as actions.

**All Results** (`proto-all-results`) is a window: every original still kept (7 days), by day,
searchable, with the week's saving as its figure and the same row actions as the batch window.
It is where "put it back" always works.

## Options popover

`proto-options`, `-options-kinds`, `-options-ca`.

340 pt, anchored to the result's Options button. It opens on the controls and never scrolls.

- **Header:** a 60 × 42 pt picture, the name (click to rename), "2.4 MB → 612 kB", the figure.
- **Format · Size · Actions**, for every kind, always at the same height under the header. The
  popover's top edge is fixed and it is placed so that its tallest tab fits; a tab never moves
  because it was used.
- **Suggestion:** the first row of Format, only when there is something to propose: "As WebP it
  would be 410 kB / Usually right for screenshots", **Convert** (spoken "Convert to WebP") and a
  close button. Used or closed, it is gone for that file.

| Kind | Format tab |
|---|---|
| Image | tiles PNG, JPEG, WebP, AVIF and "…", named "More formats" (HEIC, GIF, TIFF), each with its estimated size; Adaptive · Lossless · Aggressive; Quality; Remove metadata; (HDR input: Keep HDR) |
| Video | tiles HEVC, H.264, GIF and "…" (AV1, still frame); Adaptive · Lossless · Aggressive; Frame rate; Speed; Remove audio |
| PDF | tiles Screen, Reading, Print (72, 150, 300 dpi) with a caption for the chosen one, and "…" (Pages as Images); Keep text selectable; Remove metadata |
| Audio | tiles AAC, MP3, Opus and "…"; Bitrate in kbps; Speed; Even out loudness |

- Under a hairline, the rule: "Always do this for screenshots" (for screen recordings, exported
  PDFs, voice memos…).
- Holding ⌥ over a format tile shows "+ WebP" on it: the click converts and keeps both files.
  The same is in the tile's context menu as "Convert and Keep Both".
- **Size:** Scale with "50 % · 1470 × 956 · 180 kB"; "Fit under" chips; Crop chips. A ratio
  crops from the centre at once; "Free…" opens the crop window. Video and PDF show Scale and
  Fit under only; audio shows Fit under.
- **Actions:** a list like a menu, so no label wraps in any language: Copy ⌘C · Save As… ⌘S ·
  Show in Finder ⌘R · Quick Look Space · Compare with the Original | Share… · Open With › ·
  Send To › (shelf apps and uploaders, only those installed) · Run a Shortcut › · Run a
  Pipeline › · Upload to (target).
- A tile, chip or switch applies at once; a slider applies on release. While the change runs
  (`proto-options-kinds`, the video): the selection has already moved, a 2 pt line runs under
  the header, and after 400 ms a Stop button takes the figure's place. A new change cancels the
  one still running. Done, the figure counts to the new value. If it fails, the selection goes
  back (150 ms) and one caption in `error` says so: "Not converted. The PNG is kept." ⌘Z undoes
  the last change, or stops it mid-run.
- The popover hangs from the card's edge, not from a button that can vanish, and the card
  keeps its footer and its height until the popover closes.
- ⌥ over a tile, ⌥Return on it, or the context menu: "Convert and Keep Both".
- Estimates carry no "≈"; VoiceOver says "about 410 kilobytes".

## Drop zone

`proto-drop-zone`.

A row of tiles at the results corner: up to three pipeline tiles (92 × 92 pt: a 20 pt symbol
pinned 18 pt from the top, a 12 pt name on at most two lines) and the main tile (208 × 92 pt:
the clog in a fixed slot, "Optimise", "3 files"). Tiles never change size; the gaps between them
belong to the nearest tile, so there is no dead strip.

Its place is decided once, when the drag starts, and does not change until the drag ends: 8 pt
beyond the stack, or beside the corner card when the stack leaves no room (a 13-inch screen with
three tall cards). A live file drag holds every card and pauses auto-hide, so nothing moves
while a file is in the air.

- **It appears quietly.** When a drag of files the app can optimise starts anywhere, the row
  fades in at full size in 120 ms, and out in 100 ms when the drag ends. Most drags are going
  to Finder; they get no show. It never appears for a drag that started on one of the app's own
  cards.
- **It comes alive when the drag is over a tile:** that tile lights (white on the lit fill) and
  grows to 104 % from its centre; on the others the symbol recedes to 40 % and the name
  keeps its contrast, since they are still targets. Lit means "a drop here is accepted",
  nothing else. Within 120 pt of the row, before any tile is under the drag, the row rises 4 pt
  and no tile lights.
- **⌥** turns the main tile into "Optimise Aggressively" in `warm` (⌘ is Finder's Move).
- **Drop:** the tile becomes the result card (it morphs into the card's frame, spring 0.35 /
  0.85, carrying the drop's momentum). Two or three files become two or three cards, the first
  from the tile; four or more become the batch window, and the tile fades.
- Tile names are the pipelines' names. A name that does not fit two lines is cut in the
  middle. Tiles reorder in Settings by dragging, or with ⌥↑ and ⌥↓.

## Batch window

`proto-batch`, `proto-batch-running`.

Titled with the count ("9 files"), with a toolbar: Pause and Stop while running; Undo All and
Show in Finder always, each with a tooltip and a VoiceOver name.

- **Header:** the figure, "29 MB → 8.4 MB", the split bar. While running, "7 of 9" and a
  spinner at the right: progress is a count, and the bar keeps one meaning. Finished with
  failures, a red "1 failed" scrolls to the first.
- **Rows:** a 40 pt picture, the name, the sizes, and the saving at the right in ink. On hover
  or focus, Undo, Compare and Show in Finder arrive beside the saving; the saving stays. A
  failed row loses its colour, says why in `error` and has Retry.

## Compare window

`proto-compare`.

A toolbar: the file name as title; Split · Side by Side · Flip in the middle; Differences, Zoom
to Fit, Try Another, Undo at the right. The canvas is a checkerboard in the appearance's own
greys; the divider stops at the picture's edges. A 34 pt bar under it: "Original PNG · 4.8 MB",
the saving, "JPEG · 1.2 MB Optimised". For video the bar's middle also holds Play, Next Frame
and a scrubber that drives both sides; for a PDF, Previous Page, "3 of 28", Next Page. No "Keep": closing keeps. Undo asks nothing. Flip is a
cut with no fade, because the eye needs the edge.

## Settings

`proto-settings-general`, `-settings-automatic`, `-settings-quality`.

Seven panes, by decision:

| Pane | Holds |
|---|---|
| General | Open at login; where optimised and converted files go, once, with "Different for video, PDF or audio · Set…"; Remove metadata, Keep file dates, Keep HDR; the four shortcuts |
| Automatic | what is optimised when copied, and "Put the result back on the clipboard"; watched folders per kind; rules; ignored apps; size limits per kind; "most new files at once" |
| Compression | "Normally": Light · Balanced · Strong per kind. "When aggressive": only the levels above the normal one (Strong · Maximum). "Always aggressive for". Then one row per kind (Images… · Video… · PDF… · Audio…) holding its conversions and exact numbers: formats converted automatically, adaptive format, Retina downscale and the default downscale factor; encoder, frame rate cap and floor, what a speed change does to frames, remove audio, GIF width and frame rate; PDF dpi; convert to AAC, loudness, cover art |
| Results | corner, screen, how long results stay, the footer's buttons, batch threshold, drop zone and pipeline tiles |
| Uploads | targets and automatic uploads |
| Agents | connected agents first; "Add an Agent…" lists the rest; what agents may do |
| Advanced | updates, backups, path templates, reset |

The pane is named for what its scale measures: Strong is more compression, so it is not under
"Quality", where the popover's slider runs the other way. Every registry setting has a place in
this table; the implementation carries a test that fails when a setting has none. Search finds every one, including those behind "Set…" and the per-kind
sheets, and opens the sheet on the row. A row is its label; a second line appears only where
the choice has a consequence ("The original is kept for 7 days. Put it back from All Results.";
the number is the retention setting).
Lists reorder by dragging, with ⌥↑ and ⌥↓ and with VoiceOver's Move Up and Move Down.

## First run

`proto-onboarding-1-try`, `-2-tried`, `-3-menu-bar`.

Three steps, 600 × 480 pt.

1. **Copy a screenshot.** "Press ⌃⇧⌘4 and drag over anything.", in primary ink: it is the
   step's one instruction. The stage waits; "Use a Sample
   Instead" for whoever would rather not. macOS asks for clipboard access here; if it is
   refused the stage says so and offers "Open Privacy Settings" and the sample. The corner card
   is held back during this step: the stage is the result.
2. **That is all it does.** The person's own screenshot, the figure, "2.4 MB → 612 kB", the
   split bar. "It was smaller before you could paste it. The original is kept for 7 days."
3. **It lives in the menu bar.** The glyph as it looks up there, in both directions, three
   shortcuts as key caps, and one link: "Connect an AI Agent…". Done; no Skip on the last step.

In B the wooden clog waits on the stage of step 1.

## Pipeline editor

`proto-pipeline`.

- Sidebar: "Yours" and "Examples" (the templates, in sentence case, no padlocks; opening one
  offers "Make It Mine").
- The document: its name as a title, then one sentence of chips: "Runs for [PNG screenshots]
  when [copied] or [dropped on its tile] ⊕".
- Steps are a flow: a symbol per kind of step in a 30 pt circle, joined by a line; the step's
  name and its settings in plain words. Clicking a step opens its settings in a popover. Steps
  reorder by dragging, with ⌥↑ and ⌥↓, and with VoiceOver's Move Up and Move Down.
- Problems are written for people: "A size has to be more than zero."
- Toolbar: Steps · Text, "Try It…" and "Run on Files…".

## Motion

Springs are response / damping ratio. Every spring retargets from its current value and
velocity, so every row is interruptible; durations are not. Reduce Motion turns every row into
a 150 ms crossfade, shows final figures without counting, and holds the glyph's heel pose.

| Moment | Motion | How often |
|---|---|---|
| Card enters | slides 24 pt from the screen edge and fades, 0.35 / 1.0 | every result |
| **Result arrives** | the picture dips to 95 % in 120 ms and returns on 0.35 / 0.60 (about 1 pt of overshoot, once); the figure counts to its value in 300 ms, ease-out | the signature. Only when the previous result is more than 3 s old; in a burst, figures appear set |
| Fast job (under 1 s) | the card enters already done and the figure counts; no dip, which nobody would see during the entrance | |
| Detail: neighbours | covered ones fade out, the rest dim, 120 ms | |
| Detail: the figure | grows from 17 to 34 pt with the card, as one text scaling, not two crossfading | |
| Card leaves | fades and moves 12 pt toward the screen edge, 150 ms ease-in | |
| Working becomes done | the footer crossfades, 120 ms, then the arrival | |
| Footer buttons, close button | fade 120 ms | every hover |
| Detail opens, closes | the card resizes from its corner, 0.35 / 1.0; content opacity follows the spring's progress from 0.7 to 1, so it reverses with it; the split bar draws with it, once per result | on click |
| Failed caption, panel selection row | height follows 0.30 / 1.0; text fades with progress | |
| Swipe away | tracks 1:1; leaves or returns on 0.35 / 1.0 | |
| Stack settles | 0.35 / 1.0, 400 ms after the pointer leaves | |
| Drop row | fades in 120 ms, out 100 ms | every file drag |
| **Tile under the drag** | 100 → 104 %, 0.25 / 0.60; the others dim in 120 ms | a drag has momentum |
| **Drop** | the tile morphs into the card, 0.35 / 0.85 | a drop is a release |
| **Glyph working** | one step, 280 ms per half, ease-in-out; 1.4 s rest | after 1 s of work |
| Menu panel | 98 → 100 % from the glyph and fade, 100 ms; closes in 80 ms | |
| Options popover | the system's | |
| Options change | the figure counts to the new value in 300 ms | |
| Compare: flip | cut | |
| Compare: layout | crossfade 180 ms | |
| Batch row finishes | its figure fades in, 150 ms | |
| List item moves | follows the pointer; settles on 0.30 / 1.0 | |
| **First run, step 2** | the arrival, as on a result | once |
| Settings, tabs | none | |

Three rows overshoot: the arrival and the tile under the drag at a damping of 0.60 (about 1 pt
past the mark), and the drop at 0.85, which follows a release. They are the product's singular
moments and the owner asked for those to be alive; the arrival is rate-limited so it cannot
repeat in a burst.

## Words

One name per thing, in both languages. Catalan uses the comma for decimals ("2,4 MB").

| Concept | English | Catalan |
|---|---|---|
| The action | Optimise | Optimitza |
| The strong mode | Aggressive / Optimise Aggressively | A fons / Optimitza a fons |
| Settings pane | Compression | Compressió |
| Compression levels | Light · Balanced · Strong · Maximum | Suau · Equilibrada · Forta · Màxima |
| Compression headings | Normally / When aggressive | Normalment / A fons |
| Going back | Undo, Undo All | Desfés, Desfés-ho tot |
| After going back | Original restored | Original recuperat |
| Again, after going back | Optimise Again | Torna a optimitzar |
| No gain | Already optimised | Ja estava optimitzat |
| Working | Optimising / Uploading | S'està optimitzant / S'està pujant |
| Failure | Not optimised / 3 not optimised / Retry | No optimitzat / 3 no optimitzats / Torna-hi |
| A change failed | Not converted. The PNG is kept. | No s'ha convertit. Es conserva el PNG. |
| Upload done | Link copied / Copy Link | Enllaç copiat / Copia l'enllaç |
| Tabs | Format · Size · Actions | Format · Mida · Accions |
| Scale | Scale | Escala |
| Size cap, everywhere | Fit under | Com a màxim |
| Crop | Crop / Free… | Retalla / Lliure… |
| Metadata | Remove metadata | Treu les metadades |
| Loudness | Even out loudness | Iguala el volum |
| PDF text | Keep text selectable | Conserva el text seleccionable |
| Rule | Always do this for screenshots | Fes-ho sempre amb les captures |
| Suggestion | As WebP it would be 410 kB / Usually right for screenshots / Convert (spoken: Convert to WebP) | En WebP ocuparia 410 kB / Sol anar bé per a les captures / Converteix (dit: Converteix a WebP) |
| More formats | More formats | Més formats |
| Save | Save As… | Anomena i desa… |
| Shortcut | Run a Shortcut | Executa una drecera |
| PDF pages | Pages as Images | Pàgines com a imatges |
| Clipboard | Put the result back on the clipboard | Torna el resultat al porta-retalls |
| Spoken marks | optimised aggressively / by your rule | optimitzat a fons / segons una regla teva |
| Spoken result | Screenshot, 75 % smaller, 612 kilobytes | Captura, un 75 % més petita, 612 kilobytes |
| Settings panes | General · Automatic · Compression · Results · Uploads · Agents · Advanced | General · Automàtic · Compressió · Resultats · Pujades · Agents · Avançat |
| Gear menu | Settings… · Check for Updates… · Show the Tour · About L'Esclop · Quit L'Esclop | Configuració… · Cerca actualitzacions… · Mostra la visita guiada · Quant a L'Esclop · Surt de L'Esclop |
| Rule names | Screenshots · Photos exports | Captures · Exportacions de Fotos |
| Tiles | pipeline tiles | caselles de fluxos |
| Keep both | Convert and Keep Both | Converteix i conserva tots dos |
| Pipeline | Pipeline / Run a Pipeline | Flux / Aplica un flux |
| Pipeline sentence | Runs for … when copied or dropped on its tile | S'aplica a … quan es copien o es deixen anar a la seva casella |
| Drop tile | Optimise · 3 files | Optimitza · 3 fitxers |
| Panel figure | today, across 14 files | avui, en 14 fitxers |
| Panel status | Watching the clipboard and 2 folders | Vigila el porta-retalls i 2 carpetes |
| Panel, paused | Paused / Resumes at 14:32 / Until you resume / Resume / Watching nothing | En pausa / Es reprèn a les 14:32 / Fins que ho reprenguis / Reprèn / No vigila res |
| Panel, empty | Ready / Nothing optimised yet / Copy a screenshot. It lands here, smaller. | A punt / Encara no s'ha optimitzat res / Copia una captura de pantalla. Apareixerà aquí, més petita. |
| Panel commands | Optimise Files… · Optimise Clipboard · All Results · Pipelines | Optimitza fitxers… · Optimitza el porta-retalls · Tots els resultats · Fluxos |
| Panel, batch | Optimising 7 of 9 / Show | S'està optimitzant, 7 de 9 / Mostra |
| Pause menu | For the Next Copy · For 5 Minutes · For an Hour · Until I Resume | Per a la pròxima còpia · Durant 5 minuts · Durant una hora · Fins que ho reprengui |
| Notice | The next copy won't be optimised | La pròxima còpia no s'optimitzarà |
| Originals kept | The original is kept for 7 days. Put it back from All Results. | L'original es conserva 7 dies. Recupera'l des de Tots els resultats. |
| First run | Copy a screenshot / That is all it does / It lives in the menu bar | Copia una captura / Això és tot el que fa / Viu a la barra de menús |

Voice: sentence case for labels, title case for commands and buttons, as macOS does; a button
states its outcome; a middle dot joins only facts of one kind; an error says what happened and
what was kept, and the way out is a button.

## Accessibility

- **VoiceOver:** a result is one element, "Screenshot, 75 % smaller, 612 kilobytes" (and
  "optimised aggressively" or "by your rule" where the bolt or the pin shows), with its state's
  buttons, Show Details and Dismiss as actions; arrivals are announced once, at low priority.
  Every icon-only button has a name and a tooltip. Everything ⌥ changes is also an action.
- **Keyboard:** everything the pointer does has a key: results (⌃⇧R and the keys above), the
  panel (Tab and arrows), the divider (← →), reordering (⌥↑ ⌥↓), the popover (arrows, Return,
  Esc, the printed shortcuts).
- **Contrast:** as in Tokens, measured on rendered pixels by a test. The two parts of a split
  bar differ by 3:1 in lightness. A dimmed tile's name keeps its contrast.
- **Increase Contrast:** floating surfaces become opaque with a 1 pt border in the label colour.
- **Reduce Transparency:** A's glass becomes the window background colour with a 1 pt border.
  B is already opaque.
- **Reduce Motion:** as in Motion.
- **Text size:** the card, panel and popover widths scale with the system text size
  (`ScaledMetric`), up to 135 %.
- **Colour is never alone:** aggressive has the bolt, a rule the pin, failure the triangle and
  the words, pause the outline.

## Open issues

1. The glyph's three states are still to be drawn as vectors; the renders use stand-ins.
2. The prototype draws its own segmented control so that it fills the row; whether the shipped
   one is `NSSegmentedControl` at full width or this drawing is an implementation choice.
3. In B the green is both the saving and the control colour, as the owner's brief for B says.
   One member proposed wood for B's controls; `wood` is too close to `warm` to carry both, so
   it stays green. This is the owner's call when choosing between A and B.
4. B's wooden clog is a rendered picture beside SF Symbols. It appears only where the app
   speaks as itself (the main drop tile at rest, the empty panel, the first run's stage), never
   as a control.
5. A against B: the owner chooses. Round 2: interaction and visual system preferred A;
   accessibility preferred B before A's glass got its backing.
