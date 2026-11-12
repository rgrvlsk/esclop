# Design proposal

Status: round 1, under review. It answers [critique.md](critique.md). Nothing here is built into
the app yet: the pictures come from prototype views in `Tests/EsclopAppTests/Prototype`, drawn
with real SwiftUI and AppKit and captured as real windows, so glass is the system's Liquid Glass.
Render them with `ESCLOP_RENDER_DIR=<folder> Scripts/test.sh --filter 'PrototypeRenderTests'`;
a render is named `proto-<name>-light.png` or `-dark.png`.

## The owner's four answers

1. **Menu:** a custom glass panel under the glyph, not a native menu.
2. **Voice:** sparse. A label alone, and one sentence only where a choice has a consequence.
3. **Motion:** lively, never kitsch. Alive on the elements that are singular or mean something,
   quiet everywhere else.
4. **Brand:** native Mac with one thread of its own. System materials and controls; the green
   has one job; the clog lives in the glyph and moves when it works.

## Five rules

1. **One material.** Everything that floats (result, menu panel, options, drop zone) is the
   system's Liquid Glass in a continuous rounded rectangle. Every window is stock chrome.
2. **One green, one job.** `saving` green marks the saving and nothing else: the figure "−75 %"
   and the saved part of a bar. At most one green figure per surface. Controls, selection and
   links use the system accent, which the person chose.
3. **The picture is never covered.** Figures sit beside or under a picture, never on it.
4. **One figure per surface.** Each surface has one large figure in SF Pro Rounded semibold.
   Everything else is 13, 12 or 11 pt.
5. **Motion goes where the meaning is.** Four moments are alive: a result arriving, the drop
   zone, the glyph working, the first run. Everything else moves in 150 to 200 ms without bounce,
   or not at all.

## Tokens

| Token | Value | Use |
|---|---|---|
| `saving` | `#1E7F6A` light, `#3DBF9F` dark | the saving figure, the saved part of a bar |
| `warm` | `#B8741C` light, `#E0A040` dark | aggressive mode while it is the current mode |
| `error` | `#C4281C` light, `#FF6961` dark | failure symbol and text |
| accent | system accent | controls, selection, links, the drop target under the drag |
| ink | system label colours | all text; on glass, the system's vibrancy |

Type, all SF Pro, digits always monospaced:

| Role | Size and weight |
|---|---|
| Figure | Rounded semibold: 17 (card), 20 (popover), 24 (panel), 30 (detail), 34 (batch), 44 (first run) |
| Title | 13 semibold; 22 semibold for a document title; 28 semibold for the first run |
| Body | 13 regular |
| Label on glass | 12 medium |
| Caption | 11 regular, secondary. Nothing smaller, anywhere. |

Geometry: a 4 pt grid (4, 8, 12, 16, 24). Radii are concentric, outer = inner + padding:
card 14 around a 10 pt picture with 4 pt padding; detail 22 around 14 with 8; panel and popover
22; drop tiles 18; controls on glass are capsules or circles. Every pointer target is at least
28 × 28 pt. Gaps between floating objects are 8 pt.

## Floating result

`proto-result-states`, `proto-result-stack`, `proto-result-detail`, `proto-result-busy`,
`proto-result-notice`.

One glass card, 208 pt wide, at the chosen corner, 16 pt from the screen edges. The picture is on
top at its own aspect ratio (72 to 190 pt tall); under it a 34 pt footer inside the same glass.
The footer is the only part that changes.

| State | Footer, left | Footer, right |
|---|---|---|
| Working | "Optimising" | time left ("4 s") for jobs over 2 s, else nothing. A 2 pt neutral line where picture and footer meet shows progress. It is the only indicator: no sheen, no rim, no ring, no wing. |
| Done | **−75 %** in `saving` | "612 kB" in secondary |
| Done, aggressive | **−75 %** and a `bolt.fill` in `warm` | "612 kB" |
| Done by a rule | **−75 %** and a `pin.fill` in secondary | "612 kB" |
| Nothing to gain | "Already small" | "612 kB" |
| Undone | `arrow.uturn.backward`, "Original back" | "2.4 MB" |
| Failed | `exclamationmark.triangle.fill` in `error`, "Not optimised" | a **Retry** button. The picture loses its colour. |
| Uploaded | `link`, "Link copied" | "−75 %" in secondary |
| Uploading | "Uploading" with the progress line | "40 %" |

Interaction:

- **Hover:** the right side of the footer (the byte size) gives way to three 28 pt buttons:
  Undo, Copy, Options. The figure stays. The card does not change size and no neighbour moves.
  Fade 120 ms; no delay in, 200 ms grace out.
- **Click the picture:** opens the detail. There is no dwell: nothing opens because the pointer
  rested.
- **Drag the picture:** drags the file out. The card dims to 60 % while it is dragged.
- **Click Options (…):** opens the options popover, anchored to the button.
- **Two-finger swipe toward the edge, or Esc when focused:** dismisses. A flick dismisses by
  velocity, not distance.
- **Keyboard:** a new global hotkey, ⌃⇧R by default, moves focus to the newest result. Then
  arrows move between results, Return opens the detail, ⌘Z undoes, ⌘C copies, ⌘R reveals,
  Space is Quick Look, Esc dismisses. Focus draws the system focus ring on the card.
- **Auto-hide:** 10 s for a copy, 30 s otherwise, paused while hovered, focused, dragged or
  open. A failed result stays until dismissed.
- **Stack:** the newest three, 8 pt apart, newest nearest the corner. Older ones are in the menu
  panel.
- **Failed, clicked:** the card grows downward by one caption: what went wrong and that the
  original is untouched. The retry is a button, not a sentence.

The detail is the same card grown to 320 pt from its corner: the comparison with a draggable
divider and nothing printed on the picture; under it "Original 2.4 MB" at the left and "612 kB
Optimised" at the right, each under its own half; the figure at 30 pt with "1.8 MB saved"; the
split bar; one caption of facts ("PNG · 2940 × 1912 · metadata removed"); three buttons: Undo,
Compare, Options…. Clicking the picture's surroundings or Esc closes it.

**The split bar** replaces the deflate bar. The whole width is the original. The left part, in
ink at 32 %, is what is left; the right part, in `saving`, is what was saved. After a 75 %
saving three quarters of the bar are green. It is used in the detail, the batch header and the
first run.

A notice (the pause hotkey) is a 34 pt glass capsule with a symbol, one line and the keys.

## Menu bar

`proto-glyph`, `proto-menu-panel`, `proto-menu-panel-ca`, `proto-menu-panel-busy`.

**Glyph.** The clog, as now, in three states. Idle: solid. Working: the clog takes steps (it
rocks −9° on its heel, then 5° on its toe, 280 ms each, ease-in-out) for as long as work runs,
and always finishes the step. Paused: the clog as an outline. Reduce Motion: working shows the
solid glyph with no rocking. The dimmed glyph is gone.

**Panel.** Clicking the glyph opens a 320 pt glass panel under it, anchored to the glyph.

- **Header:** the day's saving as the figure ("−38 MB") with "today, across 14 files"; at the
  right a Pause button and a gear. The gear opens a small menu: Settings… ⌘, · Check for
  Updates… · Show the Tour · Quit ⌘Q.
- **Pause** opens a menu: Skip the next copy · For 5 minutes · For an hour · Until I resume.
  The hotkey does the same cycle. Paused, the header reads "Paused / Back at 14:32" with a
  Resume button, and the thumbnails' figures dim.
- **Recent results:** the last six as pictures, three to a row, each with its saving under it
  in ink (the header holds the panel's one green figure). A picture drags out as the file.
  Clicking one brings its floating result back at the corner, where undo, compare and options
  are. A context menu has Undo, Compare, Show in Finder. There are no submenus.
- **Commands:** Optimise Files… ⌘O · Optimise Clipboard ⌃⇧C · Pipelines…. Holding ⌥ turns the
  first two into "… Aggressively".
- **Status:** one caption, "Watching the clipboard and 2 folders".
- **Empty:** "Ready / Nothing optimised yet" and "Copy a screenshot. It lands here, smaller."
- **Keyboard:** the panel takes focus when opened from the keyboard; arrows move through
  pictures and commands, Return activates, Esc closes. VoiceOver reads each picture as "name,
  75 % smaller, 612 kilobytes" with Undo and Compare as actions.

## Options popover

`proto-options`, `proto-options-ca`.

340 pt glass, anchored to the result's Options button. It opens on the controls. It never
scrolls.

- **Header:** a 60 × 42 pt picture, the name (click to rename), "2.4 MB → 612 kB", and the
  figure at the right.
- **Suggestion:** one row, only when there is something to propose: "As WebP it would be
  410 kB / Usually right for screenshots" and a **Use WebP** button. Used or dismissed, the row
  is gone.
- **Format · Size · Share** (segmented). Audio shows **Sound** in place of Size.
- **Format:** four format tiles, each with its estimated size, and "…" for the rest. The
  selected tile has the system accent ring. Then compression (Adaptive · Lossless ·
  Aggressive, plain segments), quality with its number, "Remove metadata", and under a
  hairline the rule: "Always do this for screenshots". Estimates carry no "≈": the header of
  the tiles is understood as an estimate and VoiceOver says "about".
- **Size:** scale with "50 % · 1470 × 956 · 180 kB"; "No larger than" chips; crop chips. A crop
  ratio applies a centred crop at once; "Free…" opens the crop window, where the crop is drawn
  on the picture at a usable size. The popover holds no crop editor.
- **Share:** a list like a menu, so no label wraps in any language: Copy ⌘C · Save As… ⌘S ·
  Show in Finder ⌘R · Quick Look Space · Compare with the Original… | Share… · Open With › ·
  Run a Pipeline › · Upload to (target).
- Every change runs at once from the original and the figure counts to the new value. ⌘Z
  undoes the last change.
- "Keep visible" and "Customise buttons" leave the popover for Settings › Results.

## Drop zone

`proto-drop-zone`.

While files are dragged, a row of glass tiles rises at the results corner: up to three preset
tiles (92 × 92 pt: a 20 pt symbol and a 12 pt name on at most two lines) and the main tile
(the clog, "Optimise", "3 files"). No dashes, no boxes in boxes, one row.

- The tile under the drag grows to 105 % and takes the system accent; the others dim to 60 %.
- Holding ⌘ turns the main tile into "Optimise Aggressively" in `warm`.
- Dropping: the tile pulses once (100 % → 108 % → 100 %) and the result card appears in its
  place.
- Preset names are the pipelines' names, shown in sentence case. A name that does not fit two
  lines is cut in the middle.

## Batch window

`proto-batch`, `proto-batch-running`.

A window titled with the count ("9 files"), with a real toolbar: Pause and Stop while running;
Undo All and Show in Finder always.

- **Header:** the figure ("−71 %"), "29 MB → 8.4 MB", and the split bar. While running, "7 of
  9" with a spinner at the right: progress is a count, and the bar keeps one meaning.
  Finished with failures, a red "1 failed" at the right scrolls to the first.
- **Rows:** a 40 pt picture, the name, "4.8 MB → 1.2 MB" and the saving at the right in ink.
  On hover, three buttons (Undo, Compare, Show in Finder) arrive beside the saving; the saving
  stays. A failed row says why in `error` and has a Retry button. No per-row bars.

## Compare window

`proto-compare`.

A real toolbar: the file name as the title; Split · Side by Side · Flip in the middle;
Differences, Zoom to Fit, Try Another and Undo at the right. The canvas is a checkerboard in the
appearance's own greys. A 34 pt bar under it: "Original PNG · 4.8 MB" at the left, the saving in
the middle, "JPEG · 1.2 MB Optimised" at the right. No "Keep" button: closing the window keeps.
Undo asks nothing.

## Settings

`proto-settings-general`, `proto-settings-automatic`, `proto-settings-quality`.

Seven panes, grouped by decision, in place of ten grouped by registry section:

| Pane | Holds |
|---|---|
| General | open at login; where optimised and converted files go, once, with "Different for video, PDF or audio… Set…"; metadata, dates, HDR; the four shortcuts |
| Automatic | what is optimised when copied (four switches); watched folders; rules; ignored apps; size limits |
| Quality | Light · Balanced · Strong per kind, for normal and for aggressive; "Always aggressive for"; "Fine-tune…" opens the exact numbers |
| Results | corner, screen, how long results stay, footer buttons, batch threshold, drop zone and preset tiles (reordered by dragging) |
| Uploads | targets and automatic uploads |
| Agents | connected agents first; "Add an agent…" lists the rest; what agents may do |
| Advanced | updates, backups, path templates, reset |

Voice: a row is its label. A second line appears only where the choice has a consequence the
label cannot carry ("The original is kept for 7 days and can be put back from the menu."). Search
stays at the top of the sidebar and still finds every registry setting, including those behind
"Set…" and "Fine-tune…".

## First run

`proto-onboarding-1-try`, `proto-onboarding-2-tried`, `proto-onboarding-3-menu-bar`.

Three steps in a 600 × 480 pt window.

1. **Copy a screenshot.** "Press ⌃⇧⌘4 and drag over anything." The stage waits; "Use a Sample
   Instead" is there for whoever would rather not. Continue is disabled until one or the other
   happens. macOS asks for clipboard access here, at the moment it is needed.
2. **That is all it does.** The person's own screenshot, its saving as the figure, "2.4 MB →
   612 kB" and the split bar filling. "It was smaller before you could paste it. The original
   is kept for 7 days."
3. **It lives in the menu bar.** The clog, three shortcuts as key caps, and one link: "Connect
   an AI Agent…". Done.

What is optimised on its own, folders and agents are not in the tour; they are in Settings, with
the defaults already right.

## Pipeline editor

`proto-pipeline`.

- The sidebar lists "Yours" and "Examples" (the built-in templates, in sentence case, with no
  padlocks; opening one offers "Make It Mine").
- The document has its name as a title, and one sentence of chips: "Runs for [PNG screenshots]
  when [copied] [dropped on its zone] ⊕".
- Steps are a flow: a symbol per kind of step in a 30 pt circle, joined by a line; the step's
  name and its settings as one line of plain words ("Long edge 1600 px"). Clicking a step opens
  its settings in a popover. Steps reorder by dragging. "Add a step" ends the flow.
- Problems are written for people: "A size has to be more than zero." No identifiers.
- Toolbar: Steps · Text, and "Try It…" with its name.

## Motion

Springs are given as response and damping ratio. Reduce Motion replaces every row with a
150 ms crossfade and shows final figures without counting.

| Moment | Motion | Why it may be alive |
|---|---|---|
| Result card enters | slides 24 pt from the screen edge and fades, spring 0.35 / 1.0 | |
| **Result arrives** | the picture deflates 100 % → 94 % → 100 % (spring 0.30 / 0.70) while the figure counts from 0 to its value in 450 ms, ease-out | the signature: the one moment the product exists for |
| Footer buttons on hover | fade 120 ms | |
| Detail opens and closes | the card itself resizes from its corner, spring 0.35 / 1.0; content fades in over the last 150 ms | |
| Split bar | the green grows from the right in 450 ms, ease-out, 100 ms after it appears | it draws the claim |
| **Drop tiles rise** | each tile scales 90 % → 100 % and fades, 30 ms apart from the main tile outward, spring 0.30 / 0.85 | a drag has momentum |
| **Tile under the drag** | 100 % → 105 %, spring 0.25 / 0.80; others dim in 120 ms | it answers the hand |
| **Drop** | the tile pulses to 108 % and back, spring 0.30 / 0.65 | a drop is a release |
| **Glyph working** | rocks heel and toe, 280 ms each, ease-in-out | the brand's one gesture |
| Menu panel | scale 96 % → 100 % from the glyph and fade, 160 ms ease-out; closes in 100 ms | |
| Options popover | the system's | |
| Options change | the figure counts to the new value in 300 ms | |
| Compare: flip | crossfade 120 ms | it is how the difference is seen |
| Compare: layout | crossfade 180 ms | |
| Batch row finishes | its figure fades in, 150 ms | |
| Pipeline step moves | follows the pointer; settles with spring 0.30 / 1.0 | |
| First run, step 2 | the deflate and the count, as on a result | the same signature, once |
| Settings, tabs, lists | none | |

## Words

One name per thing, in both languages.

| Concept | English | Catalan |
|---|---|---|
| The action | Optimise | Optimitza |
| The strong mode | Aggressive / Optimise Aggressively | A fons / Optimitza a fons |
| Going back | Undo (one file), Undo All | Desfés, Desfés-ho tot |
| After going back | Original back | Original recuperat |
| No gain | Already small | Ja era petit |
| Failure | Not optimised / Retry | No s'ha optimitzat / Torna-hi |
| Upload done | Link copied | Enllaç copiat |
| Scale | Scale | Escala |
| Size cap | No larger than | Que no passi de |
| Crop | Crop / Free… | Retalla / Lliure… |
| Metadata | Remove metadata | Treu les metadades |
| Rule | Always do this for screenshots | Fes-ho sempre amb les captures |
| Suggestion | As WebP it would be 410 kB / Use WebP | En WebP faria 410 kB / Fes-ho |
| Share tab | Share | Envia |
| Pipeline | Pipeline | Flux |
| Run a pipeline | Run a Pipeline | Passa-ho per un flux |
| Drop tile | Optimise · 3 files | Optimitza · 3 fitxers |
| Panel status | Watching the clipboard and 2 folders | Mira el porta-retalls i 2 carpetes |
| Panel, paused | Paused / Back at 14:32 / Resume | En pausa / Torna a les 14:32 / Reprèn |
| Panel, empty | Copy a screenshot. It lands here, smaller. | Copia una captura de pantalla. Apareixerà aquí, més petita. |
| Pause menu | Skip the next copy · For 5 minutes · For an hour · Until I resume | Salta la pròxima còpia · 5 minuts · Una hora · Fins que jo ho digui |
| Notice | Skipping the next copy | Se salta la pròxima còpia |
| First run | Copy a screenshot / That is all it does / It lives in the menu bar | Copia una captura / Això és tot el que fa / Viu a la barra de menús |

Rules of the voice: sentence case for labels, title case for commands and buttons as macOS
does; no sentence ends a label; a middle dot joins only facts of the same kind ("PNG · 2940 ×
1912"); errors say what happened and what was kept, and the way out is a button.

## Accessibility

- **VoiceOver:** each result is one element: "Screenshot, 75 % smaller, 612 kilobytes", with
  Undo, Copy, Options, Show Details and Dismiss as actions, announced once on arrival. Panel
  pictures and batch rows read the same way. Split bars are hidden; their figure is read.
- **Keyboard:** everything the pointer does has a key (see Floating result and Menu bar).
- **Contrast:** text on glass uses the system's vibrant label colours. `saving` on glass is
  checked at 4.5:1 over white and over black desktops in both appearances, as `PopoverInk` is
  today; where it fails the figure gets the regular label colour and keeps its weight.
- **Reduce Transparency:** glass becomes the window background colour with a 1 pt border.
- **Reduce Motion:** as in Motion.
- **Text size:** the card, panel and popover widths scale with the system text size setting
  (`ScaledMetric`), up to 135 %.

## Open questions for this round

1. Does the card's footer read as part of the picture's object, or as a caption strip?
2. Is "one green figure per surface" too strict for the menu panel's grid?
3. Is the working glyph (a rocking clog) charming or twee at 18 pt?
4. Does the panel need more than three commands?
5. Catalan: "A fons", "Flux", "Envia".
