# Design proposal

Status: round 2, under review. It answers [critique.md](critique.md). Nothing here is built into
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
| Floating surface | Liquid Glass (`glassEffect(.regular)`); HUD material before macOS 26 | `#F6F0E8` at 94 % in light, `#2B2521` at 94 % in dark |
| Elevation (both) | shadow y 8, blur 24, black 20 % light and 45 % dark; inner rim 0.5 pt, white 35 % light and 14 % dark | same |
| `saving` | `#176B59` light, `#63D6B8` dark | same |
| `warm` (aggressive) | `#8F5510` light, `#E0A040` dark | same |
| `error` | `#C4281C` light, `#FF6961` dark | same |
| `wood` | not used | `#8A5A33` light, `#D0A077` dark: the kept part of a split bar |
| Controls, selection, lit tile | system accent | `saving` |
| Text | system label colours | same |

`saving` and `warm` were retuned for the surface they sit on: at least 4.5:1 on the floating
surface over a white, a black and a busy desktop, in both appearances. A test
(`PopoverInkTests`, extended) keeps them there.

Type, all SF Pro, digits monospaced, the percent sign after a narrow no-break space (U+202F):

| Role | Size and weight |
|---|---|
| Figure (savings only) | Rounded semibold: 17 (card, compare), 20 (popover), 24 (panel), 30 (detail), 34 (batch, all results), 44 (first run) |
| Title | 13 semibold; 22 semibold for a document; 24 semibold for a panel state ("Paused"); 28 semibold in the first run |
| Body | 13 regular |
| Label on a floating surface | 12 medium |
| Caption | 11 regular, secondary. Nothing smaller, anywhere. |

Geometry: a 4 pt grid (4, 8, 12, 16, 24). Radii are concentric, outer = inner + padding, and
there are five: card 14 around a 10 pt picture (padding 4); detail 22 around 14 (padding 8);
panel and popover 22 around 10 pt children (padding 12); drop tiles 18; capsules and circles
for controls on a floating surface. Every pointer target is at least 28 × 28 pt, 4 pt apart.
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
| Failed | `exclamationmark.triangle.fill` in `error`, "Not optimised" | **Retry** (always shown, 28 pt) | |

Working shows progress as one 2 pt neutral line on the seam of picture and footer, inside the
picture's corners. There is no sheen, rim, ring or wing.

Pointer:

- **Hover:** the footer's right side becomes the state's buttons (fade 120 ms, 200 ms grace on
  leaving), and a 20 pt close button (28 pt target) shows on the card's outer top corner. The
  figure stays; the card keeps its size; no neighbour moves. The buttons stay while a popover,
  a menu or the detail of that card is open.
- **Click** the picture or the footer: opens the detail. Nothing opens because the pointer
  rested.
- **Drag** the picture or the footer: drags the file out; the card dims to 60 %.
- **Two-finger swipe** toward the screen edge: the card follows the fingers 1:1 and leaves past
  40 % of its width or 500 pt/s; otherwise it returns (spring 0.35 / 1.0).
- **Failed, clicked:** the card grows downward by one caption: what went wrong, and that the
  original is untouched.

Keyboard: ⌃⇧R (new, global) moves focus to the newest result, or opens the menu panel when
there is none. Then ↑ ↓ move between results, Return opens the detail, ⌘Z undoes, ⌘C copies,
⌘R reveals, Space is Quick Look, ⌘. stops a working one, Esc dismisses and, on the last, gives
focus back to the app that had it. The focused card draws the system focus ring.

Stack: the newest three. A new result enters at the end away from the corner; slots never
change while the pointer is within the stack (plus 8 pt) or a card is focused, dragged or open,
and settle 400 ms after (spring 0.35 / 1.0). A fourth result removes the oldest that is not
hovered, open or failed. Older results are in All Results.

Auto-hide: 10 s for a copy, 30 s otherwise; paused while hovered, focused, dragged or open, and
at least 5 s remain after the pointer leaves. A failed result stays. With VoiceOver running
nothing hides on its own.

**Detail.** The same card grown to 320 pt from its corner, over its neighbours: the ones it
covers fade out, the others dim to 60 %, none moves. It holds the comparison (the whole picture
drags the divider; ← → move it 5 %), "Original 2.4 MB" and "612 kB Optimised" under their
halves, the figure at 30 pt with "1.8 MB saved", the split bar, one caption of facts, and Undo,
Compare, Options…. Esc, the close button or a click outside closes it.

**Split bar.** The whole width is the original. The left part is what is left (ink at 32 % in
A, `wood` in B); the right part, in `saving`, is what was saved. It is 6 pt tall everywhere, and
is hidden from VoiceOver, which reads the figure.

A notice (the pause hotkey) is a 34 pt capsule with a symbol, one line and the keys.

## Menu bar

`proto-glyph`, `proto-menu-panel`, `-menu-panel-ca`, `-menu-panel-busy`.

**Glyph.** Three states, each drawn as its own vector (the renders stand in with a rotated and
an eroded copy). Idle: solid. Working, after 1 s of work: the clog takes one step (heel −6°,
toe 4°, 280 ms each, ease-in-out), rests 1.4 s, and repeats while work runs; it always finishes
a step. Paused: a 1.5 pt outline. Reduce Motion: working holds the heel pose, so the state
never rests on motion alone.

**Panel.** A 316 pt panel under the glyph. It is a non-activating panel that always becomes
key, so the shortcuts it prints work; Esc or a click outside closes it and gives the key window
back. Pressing the glyph, dragging to a command and releasing activates it, as in a menu.

- **Header:** the day's saving as the figure ("−38 MB") over "today, across 14 files"; a Pause
  pull-down and a gear. The gear's menu: Settings… ⌘, · Check for Updates… · Show the Tour ·
  Quit ⌘Q.
- **Pause** menu: Skip the Next Copy · For 5 Minutes · For an Hour · Until I Resume. The
  hotkey cycles the same. Paused, the header reads "Paused / Resumes at 14:32" with Resume, and
  the status line is gone.
- **Recent results:** the last six as 92 × 64 pt pictures, 8 pt apart, each with its saving
  under it in secondary 11 pt. A picture drags out as the file. Clicking one selects it: a row
  appears under the grid with its name, sizes and Undo, Compare, Show in Finder. Double-click
  opens Compare. Nothing happens at the far corner.
- **Commands:** Optimise Files… ⌘O · Optimise Clipboard ⌃⇧C · All Results… · Pipelines….
  Holding ⌥ turns the first two into "… Aggressively". ⌘Z undoes the newest result.
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
- **Suggestion:** one row, only when there is something to propose: "As WebP it would be
  410 kB / Usually right for screenshots" and **Convert to WebP**. Used or dismissed, it is gone.
- **Format · Size · Actions**; audio has **Sound** in place of Size.

| Kind | Format tab |
|---|---|
| Image | tiles PNG, JPEG, WebP, AVIF and "…" (HEIC, GIF, TIFF), each with its estimated size; Adaptive · Lossless · Aggressive; Quality; Remove metadata; (HDR input: Keep HDR) |
| Video | tiles HEVC, H.264, GIF and "…" (AV1, still frame); Adaptive · Lossless · Aggressive; Frame rate; Speed; Remove audio |
| PDF | tiles Screen, Reading, Print (72, 150, 300 dpi) with a caption for the chosen one; Keep text selectable; Remove metadata |
| Audio | tiles AAC, MP3, Opus and "…"; Bitrate; Even out loudness |

- Under a hairline, the rule: "Always do this for screenshots" (for screen recordings, exported
  PDFs, voice memos…).
- Holding ⌥ over a format tile shows "+ WebP" on it: the click converts and keeps both files.
  The same is in the tile's context menu as "Convert and Keep Both".
- **Size:** Scale with "50 % · 1470 × 956 · 180 kB"; "Fit under" chips; Crop chips. A ratio
  crops from the centre at once; "Free…" opens the crop window. Video and PDF show Scale and
  Fit under only. **Sound** shows Fit under and Speed.
- **Actions:** a list like a menu, so no label wraps in any language: Copy ⌘C · Save As… ⌘S ·
  Show in Finder ⌘R · Quick Look Space · Compare with the Original… | Share… · Open With › ·
  Run a Pipeline › · Upload to (target).
- A tile, chip or switch applies at once; a slider applies on release. A new change cancels the
  one still running. The figure counts to the new value. ⌘Z undoes the last change, or cancels
  it mid-run.
- Estimates carry no "≈"; VoiceOver says "about 410 kilobytes".

## Drop zone

`proto-drop-zone`.

A row of tiles at the results corner, 8 pt beyond the stack: up to three preset tiles (92 × 92
pt: a 20 pt symbol, a 12 pt name on at most two lines) and the main tile (208 × 92 pt: the
clog, "Optimise", "3 files"). Tiles never change size; the gaps between them belong to the
nearest tile, so there is no dead strip.

- **It appears quietly.** When a drag of files the app can optimise starts anywhere, the row
  fades in at full size in 120 ms, and out in 100 ms when the drag ends. Most drags are going
  to Finder; they get no show. It never appears for a drag that started on one of the app's own
  cards.
- **It comes alive when the drag comes near** (within 120 pt): the tile under the drag lights
  in the control colour and grows to 104 % from its centre; the others dim to 60 %.
- **⌥** turns the main tile into "Optimise Aggressively" in `warm` (⌘ is Finder's Move).
- **Drop:** the tile becomes the result card (it morphs into the card's frame, spring 0.35 /
  0.85, carrying the drop's momentum).
- Preset names are the pipelines' names. A name that does not fit two lines is cut in the
  middle. Presets reorder in Settings by dragging, or with ⌥↑ and ⌥↓.

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
the saving, "JPEG · 1.2 MB Optimised". No "Keep": closing keeps. Undo asks nothing. Flip is a
cut with no fade, because the eye needs the edge.

## Settings

`proto-settings-general`, `-settings-automatic`, `-settings-quality`.

Seven panes, by decision:

| Pane | Holds |
|---|---|
| General | Open at login; where optimised and converted files go, once, with "Different for video, PDF or audio · Set…"; Remove metadata, Keep file dates, Keep HDR; the four shortcuts |
| Automatic | what is optimised when copied; watched folders per kind; rules; ignored apps; size limits per kind; "most new files at once" |
| Quality | "Normally" and "When aggressive": Light · Balanced · Strong per kind; "Always aggressive for"; then one row per kind (Images… · Video… · PDF… · Audio…) holding its conversions and exact numbers: formats converted automatically, Retina downscale, encoder, frame rate cap, GIF width, PDF dpi, loudness, cover art |
| Results | corner, screen, how long results stay, the footer's buttons, batch threshold, drop zone and preset tiles |
| Uploads | targets and automatic uploads |
| Agents | connected agents first; "Add an Agent…" lists the rest; what agents may do |
| Advanced | updates, backups, path templates, reset |

Every registry setting has a place in this table; the implementation carries a test that fails
when a setting has none. Search finds every one, including those behind "Set…" and the per-kind
sheets, and opens the sheet on the row. A row is its label; a second line appears only where
the choice has a consequence ("The original is kept for 7 days. Put it back from All Results.").
Lists reorder by dragging, with ⌥↑ and ⌥↓ and with VoiceOver's Move Up and Move Down.

## First run

`proto-onboarding-1-try`, `-2-tried`, `-3-menu-bar`.

Three steps, 600 × 480 pt.

1. **Copy a screenshot.** "Press ⌃⇧⌘4 and drag over anything." The stage waits; "Use a Sample
   Instead" for whoever would rather not. macOS asks for clipboard access here; if it is
   refused the stage says so and offers "Open Privacy Settings" and the sample. The corner card
   is held back during this step: the stage is the result.
2. **That is all it does.** The person's own screenshot, the figure, "2.4 MB → 612 kB", the
   split bar. "It was smaller before you could paste it. The original is kept for 7 days."
3. **It lives in the menu bar.** The clog (B: the wooden one), three shortcuts as key caps, and
   one link: "Connect an AI Agent…". Done.

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
- Toolbar: Steps · Text, and "Try It…".

## Motion

Springs are response / damping ratio. Every spring retargets from its current value and
velocity, so every row is interruptible; durations are not. Reduce Motion turns every row into
a 150 ms crossfade, shows final figures without counting, and holds the glyph's heel pose.

| Moment | Motion | How often |
|---|---|---|
| Card enters | slides 24 pt from the screen edge and fades, 0.35 / 1.0 | every result |
| **Result arrives** | the picture dips to 95 % in 120 ms and returns on 0.35 / 0.80; the figure counts to its value in 300 ms, ease-out | the signature. Only when the previous result is more than 3 s old; in a burst, figures appear set |
| Fast job (under 400 ms) | the card enters already done, then plays the arrival once; at rest within 450 ms | |
| Footer buttons, close button | fade 120 ms | every hover |
| Detail opens, closes | the card resizes from its corner, 0.35 / 1.0; content fades in over the last 150 ms; the split bar draws with it, once per result, in 250 ms | on click |
| Swipe away | tracks 1:1; leaves or returns on 0.35 / 1.0 | |
| Stack settles | 0.35 / 1.0, 400 ms after the pointer leaves | |
| Drop row | fades in 120 ms, out 100 ms | every file drag |
| **Tile under the drag** | 100 → 104 %, 0.25 / 0.80; the others dim in 120 ms | a drag has momentum |
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

Two rows overshoot without a gesture before them: the arrival and the tile under the drag. They
are kept, with a damping of 0.80, because the owner asked for the singular elements to be alive;
the arrival is rate-limited so it cannot repeat in a burst.

## Words

One name per thing, in both languages. Catalan uses the comma for decimals ("2,4 MB").

| Concept | English | Catalan |
|---|---|---|
| The action | Optimise | Optimitza |
| The strong mode | Aggressive / Optimise Aggressively | A fons / Optimitza a fons |
| Quality levels | Light · Balanced · Strong | Suau · Equilibrada · Forta |
| Quality headings | Normally / When aggressive | Normalment / A fons |
| Going back | Undo, Undo All | Desfés, Desfés-ho tot |
| After going back | Original restored | Original recuperat |
| Again, after going back | Optimise Again | Torna a optimitzar |
| No gain | Already optimised | Ja estava optimitzat |
| Failure | Not optimised / Retry | No s'ha optimitzat / Torna-hi |
| Upload done | Link copied / Copy Link | Enllaç copiat / Copia l'enllaç |
| Tabs | Format · Size · Sound · Actions | Format · Mida · So · Accions |
| Scale | Scale | Escala |
| Size cap, everywhere | Fit under | Com a màxim |
| Crop | Crop / Free… | Retalla / Lliure… |
| Metadata | Remove metadata | Treu les metadades |
| Loudness | Even out loudness | Iguala el volum |
| PDF text | Keep text selectable | Conserva el text seleccionable |
| Rule | Always do this for screenshots | Fes-ho sempre amb les captures |
| Suggestion | As WebP it would be 410 kB / Usually right for screenshots / Convert to WebP | En WebP faria 410 kB / Sol anar bé per a les captures / Converteix a WebP |
| Keep both | Convert and Keep Both | Converteix i conserva tots dos |
| Pipeline | Pipeline / Run a Pipeline | Flux / Aplica un flux |
| Pipeline sentence | Runs for … when copied or dropped on its tile | S'aplica a … quan es copien o es deixen a la seva casella |
| Drop tile | Optimise · 3 files | Optimitza · 3 fitxers |
| Panel figure | today, across 14 files | avui, en 14 fitxers |
| Panel status | Watching the clipboard and 2 folders | Vigila el porta-retalls i 2 carpetes |
| Panel, paused | Paused / Resumes at 14:32 / Resume | En pausa / Es reprèn a les 14:32 / Reprèn |
| Panel, empty | Ready / Nothing optimised yet / Copy a screenshot. It lands here, smaller. | A punt / Encara no s'ha optimitzat res / Copia una captura de pantalla. Apareixerà aquí, més petita. |
| Panel commands | Optimise Files… · Optimise Clipboard · All Results… · Pipelines… | Optimitza fitxers… · Optimitza el porta-retalls · Tots els resultats… · Fluxos… |
| Pause menu | Skip the Next Copy · For 5 Minutes · For an Hour · Until I Resume | Salta la pròxima còpia · Durant 5 minuts · Durant una hora · Fins que ho reprengui |
| Notice | Skipping the next copy | Se salta la pròxima còpia |
| Originals kept | The original is kept for 7 days. Put it back from All Results. | L'original es conserva 7 dies. Recupera'l des de Tots els resultats. |
| First run | Copy a screenshot / That is all it does / It lives in the menu bar | Copia una captura / Això és tot el que fa / Viu a la barra de menús |

Voice: sentence case for labels, title case for commands and buttons, as macOS does; a button
states its outcome; a middle dot joins only facts of one kind; an error says what happened and
what was kept, and the way out is a button.

## Accessibility

- **VoiceOver:** a result is one element, "Screenshot, 75 % smaller, 612 kilobytes", with its
  state's buttons, Show Details and Dismiss as actions; arrivals are announced once, at low
  priority. Every icon-only button has a name and a tooltip.
- **Keyboard:** everything the pointer does has a key: results (⌃⇧R and the keys above), the
  panel (Tab and arrows), the divider (← →), reordering (⌥↑ ⌥↓), the popover (arrows, Return,
  Esc, the printed shortcuts).
- **Contrast:** `saving`, `warm` and secondary text hold 4.5:1 on the floating surface over
  white, black and busy desktops; a test keeps them there.
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
3. The arrival keeps a damped overshoot (0.80) against one member's advice, at the owner's
   request for lively singular elements; it is rate-limited instead.
4. A against B: the owner chooses. Members may say which serves the product better and why.
