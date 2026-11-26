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
2. **Detail.** Opened by a click, Return, or VoiceOver's action; never because the
   pointer rested. The card grows to 320 pt: the picture, the name with format and
   dimensions, the saving at the next size up, and the actions as 1 + 2 + "…": the most likely
   action in charcoal with what it acts on (Show in Finder and the folder, or Copy for a copied
   screenshot), up to two round buttons (Copy, Undo), and "…" for the rest: Convert… (the
   options: format, size, crop), Compare where there is an original, Pages as Images for a PDF
   and Extract Cover for audio with cover art (a file of the person's only), Share…, then Save
   as… for a copied image or Move to Trash for a file of the person's. Pages as Images writes the
   optimised pages into a new "<name> pages" folder beside the PDF and shows a card that stands
   for the folder ("28 pages"); Extract Cover writes the cover beside the file and optimises it
   as a result of its own. × sits in its own band above the
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
   out while the loupe is on. A round button at the hint's start opens the Compare window (split,
   difference, zoom). When a file cannot be read, the lens goes and the hint says so ("Can't read
   one of the files"); nothing swaps. Other files compare in the Compare window.

Hover shows three round buttons over the picture's corner (Copy for a copied screenshot, Show
in Finder for a file, then Undo and "…") and a close button over its outer corner, so the
object never changes size under the pointer. The card glows in the picture's tone. The picture
drags out as the file (the original after a restore). Undo never deletes: when it moved a
version edited after optimising to the Trash, the restored card says "Your edited version is in
the Trash". Errors keep the original and say so in
plain words ("This file isn't a video L'Esclop can read. It may be damaged.").
Several results in a row: show the newest three, newest at the bottom, older ones go to the
menu-bar history; never stack expanded details. A file at work keeps its place, with its Stop,
while newer results arrive; a result that lands behind newer ones comes to the front, and so
does a result chosen in Recent. Two or more failures share one of the three
places (`pr2-failures`): an amber pill, "3 not optimised" ("not uploaded" for uploads, "failed"
for a mix), that a click opens into their list, 320 pt wide, under an amber header in the serif:
each file with its picture, why, and Retry, or no button when the file is gone ("The file was
moved or deleted."); four rows show, more scroll; Retry All and Dismiss close it. An open list
stays while one failure is left, headed with the single card's words ("Not optimised"), and a
failure under the pointer, focused or open stays its own card until it is left, so nothing
changes under the pointer. Failures never hide on their own.
Dismissal pauses while the object is hovered, focused, dragged or open.
A copied web address of media is offered, never fetched on its own (owner's decision,
2026-11-20): a cream notice with the file name, its host and "Download and optimise" in charcoal,
for 4 s, once per address a session, with no sound and no focus. Its click, like any download,
shows the aqua working card from the start ("Downloading…", the share received, Stop), which
gives its place to the file's own card when the file arrives.

## Menu bar panel

The glyph in the menu bar is the clog, always the same: there is no paused or working state on
it. A click opens a 316 pt cream panel under it (`pr3-menu-panel`), with a notch pointing to the
glyph; a second click, a click anywhere else, Esc or a command closes it. It never activates
the app, so the app in front keeps its windows, but it takes the keys, so ⌘O works.

- **Header:** "Today" in the serif, and a round gear: Pause L'Esclop ⌃⇧P (Resume L'Esclop while
  paused), Settings… ⌘, Pipelines…, Originals… (every
  kept original, newest first, with its date, size, Restore and Show in Finder; the total and
  Remove All under them), Show Backups in Finder, Welcome to L'Esclop…, Check for Updates…, Quit
  L'Esclop ⌘Q.
- **Saved:** TODAY and 7 DAYS chips (charcoal when chosen); an arc from the original size (brick
  red, at its left end) to the new size (grey, at its right), with the saving's figure between
  them, and the other range under it ("Last 7 days −19.6 GB", or "Today −2.8 GB"). The sums come
  from the shared results log, cleared results included; the log keeps every result from the
  last eight days for them.
- **Working** (aqua), only while a batch runs: "6 of 8", a straight bar and the file at work.
  When it ends, **Last batch** in the tile's cream: its saving and its counts ("5 optimised ·
  1 failed"), until the next batch, so Restore All and Retry stay reachable. A click shows the
  batch window.
- **Recent:** the files being optimised, each with Stop (also those with no floating result;
  more than five of those share one row, "200 files", with Stop All); the arrows reach them and
  ⌫ stops one;
  then the last twelve results, five in view: the
  picture, the name, "2.4 MB → 612 kB · 9:41" and the saving. On hover, Copy and Show in Finder;
  a click shows the result's card again; the context menu adds Compare and Restore Original.
  The arrows move through the rows and on into the commands, and Return runs the row; the
  pointer moves the same highlight, as in NSMenu, so one row is washed. VoiceOver has every action.
  Clear (privacy) forgets the names: the shared log keeps only sizes and dates, so the saving
  stays, and the CLI and MCP no longer list them. Files, backups and cards are not touched.
  Empty: "Copy a screenshot. You'll find it here, lighter."
- **Commands:** Optimise Files… ⌘O and Optimise Clipboard ⌃⇧C; with ⌥ held it is Optimise
  Clipboard Harder ⌃⇧A.

Pausing is a setting (the gear, the ⌃⇧P hotkey as in Clop, Settings, Shortcuts, `esclop settings
set`); there is no paused state on the glyph. The hotkey says what it did in a notice for two
seconds ("Paused" with the key to resume, or "Resumed"). While it is on, the panel shows one
line under Saved, "Paused · Resume", and Resume turns the setting off (owner's decision,
2026-11-14).

## Options popover
Opens from the "…" button of the floating result, anchored to it with a popover arrow, and acts
on that one file. It replaces a long context menu. It is not the menu-bar menu. Width about
360 pt, never taller than 560 pt.

- **No header:** the card beside it shows the file. Rename is a click on the detail's name.
- **Tabs** (`pr4-options-popover-tabs`, measured against the owner's reference, Intellecta's
  tabs): 40 pt round tabs in the panel's tone, raised from the recessed bar, thin 14 pt symbols;
  the chosen one is the same circle fused with the panel under it like a folder's tab with an
  11 pt fillet, and its name in small caps at the end: Format · Size · Crop · Actions. Audio has
  Format · Sound · Actions.
- **One elevation** (owner: one geometry, one elevation): what you press and has a shape (tabs,
  tiles, chips, action rows, Crop and Fit) is raised by one token, a 0.5 pt edge and a 1 pt
  shadow (in dark a light edge, since a shadow does not show); a row that holds a control is
  flat, 44 pt; a field you type in is inset; nothing raised sits on something raised. The chosen
  tile or chip is charcoal at the same height. Text actions are flat.
- **Format:** the suggestion first, only while it is not the one applied, as an amber card:
  "WebP would be 410 kB", "33 % lighter, …" and Convert. Then four format tiles with their
  sizes (the file's own size on its tile, estimates on the others, an amber dot on the
  suggested one; the file's own format is always one of the four, the rest are in "More
  formats"). A click on an image's tile converts at once; a video's tile arms "Convert to MP4"
  (owner's decision). ⌥ or the tile's context menu converts and keeps both. One line says what
  the format is good for; Quality (teal) for lossy formats and video; Remove metadata (and HDR to
  SDR for HDR input) as a charcoal switch; the kind's own controls (video speed and audio, PDF
  DPI, audio bitrate and loudness); Restore original (⌘Z) and Optimise harder; the rule.
  Compression's Adaptive · Lossless · Aggressive is a setting, not a popover choice: Optimise
  harder runs the file again aggressively (as Clop offers it), and Lossless lives in Settings.
- **Size** (`pr4-options-popover-size-actions`): "Original 2.4 MB" in the serif, then tiles
  Original, 2000 px and 1280 px (only those smaller than the picture, and not nearly half) and
  Half, the owner's tile, always, each with its size (Half's from the real pixels, "Half, 3000 px"
  for VoiceOver). Custom: width × height that keep the aspect ratio, Return applies; "Never enlarges. Keeps
  the aspect ratio." Then Fit under 500 kB · 1 · 2 · 5 MB · Custom…. A PDF has Fit under only.
- **Crop:** its own tab, opening on the picture itself with its frame (owner's request: a crop
  must be seen), the aspect chips over it and the size in pixels under it, Reset and Crop. After
  the ratios: the chosen paper size or device, the last five typed sizes (`cropSizes`), and
  "Paper and devices", the CLI's `--paper-size`/`--for-device` list, portrait. A picture also
  has Framing, Centre or Smart: Smart moves the frame onto what the engine's smart crop finds,
  so the frame shown is the one cut. A PDF crops each page's box to a ratio, paper size or
  device. Chips are cream, the chosen one charcoal.
- A crop and a scale stay with the file, as Clop keeps its steps: every other choice runs them
  again from the original, until Original (both) or Reset (the crop) takes them off.
- **Actions:** rows, each with a round symbol, what it does and what it gives, and a play button:
  the person's pipelines ("Your pipeline"), Upload ("Copies a link"; Set Up Uploads… without a
  target, with a chevron since it opens Settings), Copy Link after an upload, Share… ("AirDrop, Mail, Messages"), shelf and upload apps
  when installed; then flat rows Copy ⌘C, Save as… ⇧⌘S, Quick Look ⌘Y and Show in Finder ⌘R
  with their keys, Run a Shortcut › and Open with ›, and a dashed "Edit Pipelines…". Pipelines
  are listed only for the kinds they do something for. The keys work from every tab;
  Compare is the detail's loupe; how long results stay visible is in Settings.
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
tooltip "Rule: PNG screenshots → WebP", and the popover opens with the box ticked. The line under
a ticked box says what the stored rule does; trying another choice leaves the rule as it is,
and a "Use this from now on" link under it stores the new choice. Rules are
listed and edited in Settings › Automation › Clipboard rules.

## Batch window
When a job brings more files than the stack of three floating results can show (four by
default, `batchWindowFrom`), they go to one window instead: a dropped folder, "Optimise Files…",
many copied files, or a list from the CLI or an agent. It comes forward without taking focus.

- **Header:** "Optimising 7 of 9 files", "48 MB → 12 MB" and the saving as the one large figure
  ("−75 %", in the figure face, in the saving colour), the bar (progress while running, then the deflate bar at
  the new proportion), the counts ("5 optimised · 1 already optimised · 1 failed") and Pause,
  Stop, Restore All, Show in Finder.
- **Rows:** thumbnail, name, sizes or status, the file's own deflate bar and its saving. On hover
  the saving gives way to 28 pt round buttons (restore, try again, stop, copy, Show in Finder);
  the same actions are in the context menu and are VoiceOver actions, with Show as Result (the
  file's floating result and its options) and Quick Look. A finished row drags out as its file;
  Space shows the row under the pointer in Quick Look. A restore that sent an edited version
  to the Trash says so on the row. With rows selected, a bar under them offers Restore, Try
  again and Remove from the List, as Originals does; ⌘C copies them and ⌫ restores them,
  after asking when there are more than one.
  Retry All Failed runs the failed rows only: stopped ones stay stopped.
- Pause holds the files still waiting; the ones running finish. Stop keeps every original. New
  files join a batch that is still running. VoiceOver announces the batch once, when it ends.

## First run
One 600 × 480 window with a transparent title bar (`pr8-first-run`), three steps under numbered
circles joined by a line (the current one charcoal), each with one heading in New York:

1. **Copy or drop an image.** A picture going to the clog in the menu bar. When macOS asks before
   every clipboard read, an amber "Asks each time" with Privacy Settings…; otherwise nothing.
2. **Same image. Lighter file.** The saving as the figure, the arc from the original size (brick
   red) to the new one (grey), and the picture twice at the same size: compression never shows
   as the image getting smaller. It is the person's own first image optimised while the tour is
   open; before there is one, an example that says it is one.
3. **Ready when you are.** The clog in the menu bar, a result with Copy, Show in Finder and Undo,
   where results appear and how long originals are kept, the Desktop question macOS asks next,
   Open at login and Connect an AI Agent… (Settings › Agents).

Skip (every step but the last) and Back are flat; Continue and Get Started sit at the trailing
edge. Steps slide in the direction of travel (350 ms spring); Reduce Motion makes it a 180 ms
crossfade. The folders are watched from the last step, or when the tour closes, so macOS's
Desktop question never covers the first steps. What the tour no longer shows lives in Settings:
the automatic switches, each folder's access and the agents.

## Color
Use system Liquid Glass materials for floating surfaces, with one accent colour and one warning
colour.

| Token | Light | Dark | Role |
|---|---|---|---|
| `accent` | `#1E7F6A` | `#3DBF9F` | savings, progress, primary actions |
| `warm` | `#8F5510` | `#E0A040` | aggressive mode, "fit under size"; `#B8741C` on a charcoal tile |
| `ink` | `#1B1F1E` | `#F2F4F3` | primary text (used only where system label colors cannot) |
| `clog` | `#8A5A33` | `#8A5A33` | app icon wood only, never in UI |
| error | `#C4281C` | `#FF6961` | failures (system red is 3.4:1 on light) |

Never: cream page backgrounds, terracotta, acid green on black, gradient washes. Dark glass
stays translucent; it must not become an opaque slab.

## Type
System font (SF Pro) everywhere, sizes from the macOS text styles, nothing below 11 pt. Byte
figures and percentages use SF Pro with monospaced digits (`monospacedDigit()`), never a
monospaced typeface. The saving is the one large figure, set by `Figure`: SF Pro
Compressed, bold, at one of its four sizes. Labels are sentence case, never all caps, never tracked out. Icons are SF
Symbols; checkmarks are symbols, not text glyphs.

## Layout
- Floating result: non-activating `NSPanel` placed against `NSScreen.visibleFrame`; it never
  takes focus from the working app. SwiftUI content in a `GlassEffectContainer` with
  `glassEffect`, sharing glass identity so thumbnail, detail and activity morph into each other.
  On macOS 14–25, which lack Liquid Glass, fall back to `NSVisualEffectView` with the
  `.hudWindow` material and a 1 pt hairline border; geometry and motion stay the same.
- Radii: the 208 pt result card is 20 pt with a 14 pt picture inset 9 pt, a photo in a mount
  rather than concentric corners; 24 pt detail card with a 12 pt picture, 22 pt popover. Controls use capsules or the system's control radius.
- Drop zone (`pr5-drop-zone`): at the results corner, above the result cards, so a drop lands
  where its result appears; it works with the menu bar hidden, in full-screen apps and on any
  display. One row of raised tiles on the popover's surface (22 pt radius): "Optimise" with the
  file count (124 × 104 pt), then up to four preset zones (100 × 104 pt, symbol in a flat circle,
  name in two lines at most) toward the screen. The tile under the drag turns charcoal at the
  same height. Under the row: "Drop to optimise · Hold ⌘ to optimise harder"; with ⌘ the tile
  reads "Optimise harder" and the hint "With the aggressive settings" in the warm colour. Over a
  preset zone the line names its pipeline ("Drop to run “to WebP”") without the ⌘ hint, which a
  pipeline does not use. ⌥ held at the drop keeps the originals, as ⌥ means copy in a Finder
  drag: a plain optimisation writes beside the original, a pipeline runs on a copy made beside
  it, and the hint reads "The originals stay as they are" in the
  primary ink. It takes files, folders (the count is the media inside, which also picks the
  preset zones), files promised by Photos or Mail, and image and video addresses from a browser,
  which are fetched into the temporary folder first. A tap on ⌥ during a drag opens the zone just
  below the pointer (hint "Tap ⌥ to hide"), and the next tap hides it; with "Show the drop zone
  only after tapping ⌥" that tap is the only way it shows. While results follow the pointer, the
  zone follows the drag to the display under it.
- Settings: sidebar panes with the search at the top of the sidebar, grouped forms with native
  controls (switches, menus, sliders with their figure, fields with a stepper and unit). Each
  row has its title and a one-line explanation; a reset arrow appears at the trailing edge,
  beside the control, while the value differs from the default. The search folds accents. A typed value is checked as it is typed, and a refused one
  keeps the field and says why under the row in red. A deep link scrolls to its row and marks
  it with an accent wash that fades after 2.5 s (no scroll animation with Reduce Motion).
- First run: see First run above.

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
once ("Optimised, 612 kB, 75 % smaller"). While VoiceOver is on, or a card has the keyboard
focus, results do not hide on a timer. With Differentiate without colour on, work in progress
(aqua) and a decision to make (amber) also carry a symbol.

## Keys
A result takes Clop's keys, with Clop's modifiers, where it has the action: on the card the
pointer moved onto and rests on (after 200 ms, with no click, and the app in front keeps its
window; a card that appears or moves under a still pointer waits for it to move), and on the
card with the keys (a click, or the "Go to the newest result" hotkey, ⌃⇧N by default, in
Settings › General and on the last onboarding page). "Show the last result" (unset by default)
brings back the newest result that is not on screen; pressed again it goes further back, never
round to one it pushed off the three places, and beeps at the oldest. The hotkey lends the keys:
Esc on the card, or Undo, Copy or Save (by key or by click), gives them back to the app in
front and the card stays. Space alone: Quick Look (again to close). With ⌘: ⌘Z Undo · ⌘C Copy ·
⌘R or ⌘F Show in Finder (⌘R, Finder's own, is the one shown) · ⌘D Compare · ⌘K Crop · ⌘S Save ·
⌘A Optimise harder · ⌘O Open · ⌘U Upload (Settings › Uploads while there is no target) · ⌘X the
playback speed, in the options (video and audio) · ⌘⌫ Dismiss (the file stays) · ⌘− smaller
(75 %, 50 %, then a tenth at a time to 10 %) · ⌘1–⌘9 that size (10 %–90 %), each from the
original. Clop's ⌘R Rename and ⌘E Edit are not taken: ⌘R is Show in Finder, and there is no
editor setting. A card key that does nothing on the card with the keys, or in its options (⌘S
with no Save), beeps. Letters never go alone: a pointer resting on a card must not take what the person
types into the app in front. While it rests there, ⌘Z, ⌘C, ⌘S and the rest act on the card,
not on that app. On the card with the keys also Return (detail, then its charcoal button) and Esc
(innermost first). The resting pointer holds no key while any card's
menu, options, name, loupe or drag has the keys, or while a field of L'Esclop is being typed
in. The "…" menu shows a row's key at its end (Compare ⌘D), and a button's tooltip names its key
("Undo  ⌘Z"); a control in the options whose key works on the result says so ("(⌘A on the
result)"). Quick Look is also a VoiceOver action, and Space on a Recent row in the menu bar
panel is Quick Look too. The hover keys are Carbon hotkeys
held only while the pointer rests, so they need no permission; a key the layout types only with
Shift or Option (the digits on AZERTY) is skipped.

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
