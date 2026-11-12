# UI critique, November 2026

A critique of every surface of L'Esclop as it stands on `main` at `cfb7342`, written before the
design overhaul. It is deliberately harsh. The reference point is Clop 3.5 and the bar is a
first-rank macOS studio: a finding stays in even when the current behaviour is defensible.

## Evidence

- **Renders:** 105 PNG, every surface in light and dark, from
  `ESCLOP_RENDER_DIR=<folder> Scripts/test.sh --filter 'RenderTests'`. A finding names a render
  as `render result-hover-dark`. Contact sheets of all of them are in
  [evidence/](evidence): results ([light](evidence/baseline-results-light.jpg),
  [dark](evidence/baseline-results-dark.jpg)), [stack and detail](evidence/baseline-stack-detail.jpg),
  [menu, glyph and drop zone](evidence/baseline-menu.jpg), options
  ([light](evidence/baseline-options-light.jpg), [dark](evidence/baseline-options-dark.jpg)),
  settings ([light](evidence/baseline-settings-light.jpg), [dark](evidence/baseline-settings-dark.jpg)),
  [batch, compare and Finder trigger](evidence/baseline-windows-1.jpg),
  [onboarding and pipelines](evidence/baseline-windows-2.jpg).
- **Live captures:** 309 PNG of the running app from the UI check rig (English, Catalan, dark,
  drop zone, popover, Settings, batch, compare, tour). A finding names one as `live dark-12-detail`.
  They are not in the repository because some show paths of the test machine.
- **Code:** `Sources/EsclopAppKit`, read for sizes, timings and what the keyboard reaches.
- **Limits:** the renders cannot show the real menu (the menu render is the menu's content in a
  window), hover dwell, a drag in flight or Liquid Glass over a live desktop. Findings about
  those come from code and are marked *(code)*.

Severity: **S1** breaks the product's promise or blocks a person; **S2** is a major flaw a
studio would not ship; **S3** is polish.

## The verdict in one paragraph

L'Esclop is four apps in one bundle. The floating result is Liquid Glass with springs and a
sheen. The options popover is a near-opaque custom panel with hand-drawn tiles. The drop zone
is a dashed web upload box. Every window is a stock grouped `Form` with eleven-point
explanations under every row. Nothing but the green ties them together, and the green is on
everything, so it means nothing. The one moment the product exists for, a file getting smaller,
is told by a pill that covers the picture it describes, in two type sizes that do not share a
baseline. The motion budget is spent in one place (sixteen animation sites in `Results`, zero
in the menu, the compare window and the pipeline editor). And the app talks too much: it
explains every switch with the switch's own name in other words.

## System-wide

1. **S1. No shared visual language.** Four materials for four surfaces: glass (result), a 94 %
   opaque custom surface (popover, `PopoverInk.surface`), an opaque dashed card (drop zone),
   stock window chrome (everything else). A person cannot tell these belong to one product.
   Principle: consistency, things that look the same behave the same and things from one app
   look like one app. `render result-hover-dark`, `options-format-dark`, `drop-zone-presets-dark`,
   `settings-search-dark` side by side.
2. **S1. The accent has no meaning.** Green is the saving, the progress bar, the deflate bar,
   every switch, every link, the selected tile, the primary button, the sidebar icons, the step
   glyphs, the status dot of a connected agent and the drop arrow. When everything is accent
   nothing is. DESIGN.md gives it three roles; the app gives it eleven.
   `render options-format-light`, `settings-agents-connect-light`, `pipelines-form-light`.
3. **S1. Two accents on screen at once.** In the real app the Settings sidebar selection, the
   popover's links ("Restore original size (100 %)", "Open the editor…") and several default
   buttons ("Save", "Keep", "Close") are system blue while switches, sliders and other default
   buttons ("Connect") are green. `live r3dark-*-settings` (blue row, green switches),
   `live dark-13-formats` (blue links), `live up14-05-test-upload` (blue Save) against
   `live dark-08-codex-sheet` (green Connect). The renders hide this because a test process
   never becomes active. Principle: one accent, or the system's, never both.
4. **S1. The app narrates itself.** Every Settings row carries a second line that restates its
   title: "Optimise copied videos / Optimise video files when they are copied.", "Optimised
   images go / Where optimised images are written.", "Always optimise PNG aggressively / Use
   the aggressive compression for every PNG." A whole pane is half grey eleven-point filler.
   Principle: every word earns its place; a label that needs a caption is a weak label.
   `render settings-search-light`, `live ca-01-set-general`.
5. **S2. Text below the floor.** DESIGN.md says nothing under 11 pt. The drop zone's second line
   and every preset zone label are `.caption` (10 pt), the pipeline step identifier is 10 pt
   monospaced, the compare tags are 10 pt, the detail divider glyph is 10 pt.
   `DropZoneView.swift:47,101`, `StepRowView.swift:32`, `CompareCanvas.swift:191`.
6. **S2. Motion is concentrated, not designed.** `Results` has sixteen animation sites; `Menu`,
   `Compare` and `Pipelines` have none, `Settings`, `Options` and `Batch` three each. Changing
   the compare layout, a popover tab or a pipeline step snaps; a result arriving gets a slide, a
   sheen, a rim, a ring, a deflate keyframe and a counting figure. Principle: motion explains
   change wherever change happens, and frequency sets the amount. *(code)*
7. **S2. Bounce without momentum.** The detail opens with `bounce: 0.15`, the deflate keyframe
   ends on `bounce: 0.3`, the bar on `0.1`. None follows a flick or a drop. Principle
   (Apple, Designing Fluid Interfaces): overshoot only when the gesture carried momentum.
   `Palette.swift` `Motion.detail`, `FloatingResultView.swift:179`.
8. **S2. Hover is doing a click's job.** Holding the pointer still for 600 ms opens the detail
   card (`FloatingResultMachine.dwell`). Resting the pointer on a thumbnail while reading
   something else changes the UI. The dwell also cannot be discovered or cancelled before it
   fires. Principle: agency, a state change needs intent. *(code)*
9. **S2. Nothing scales with the user's text size.** No `ScaledMetric`, no
   `dynamicTypeSize` handling, eleven fixed `font(.system(size:))`, fixed 200 pt, 320 pt and
   360 pt widths. Larger accessibility text will clip the capsule and the format tiles. *(code)*
10. **S2. The keyboard cannot reach a floating result.** The panel is non-activating and there
    are three global hotkeys (pause, clipboard, clipboard harder). No hotkey focuses the newest
    result, so ⌘Z, ⌘C, Return and Esc on the result, all implemented, are reachable only after
    a click. DESIGN.md promises "every hover action is also reachable by keyboard". *(code,
    `Hotkeys.swift`)*
11. **S3. Raw colours beside tokens.** 25 uses of `Color(white:)`, `.white.opacity`, `.red`
    outside the palette (`AgentsSections`, `DetailCard`, `UploadSettings`). System red on glass
    is 3.4:1 in light, which `Palette.error` exists to avoid, yet the error capsule uses `.red`.
    `FloatingResultView.swift:190`.
12. **S3. Confirmation where undo exists.** "Restore the original?" asks before an action whose
    whole point is that it is free and reversible (`CompareFooter.swift:50`); the same action in
    the hover row asks nothing. Principle: confirm only the irreversible.
    `live r9-*-_nsalertpanel`.

## Floating result

The centre of the product and its best surface. Also where the most is wrong, because the most
was attempted.

1. **S1. The capsule covers what it reports on.** A 32 pt glass pill sits on the bottom edge of
   a ~120 pt picture, hiding a quarter of it, and overhangs by 16 pt. The system screenshot
   thumbnail it imitates puts nothing on the picture. On a busy image the glass picks up the
   picture's colours and the figure sits on a rainbow. `live r9-*-results` (the capsule over
   the test pattern turns pink, green and blue), `live dark2-*-results` ("1,9 MB · −51 %" grey
   on dark glass over purple and orange). Principle: content first; a label never competes with
   its subject for the same pixels.
2. **S1. Two type sizes, no shared baseline, one pill.** "✓ 612 kB ·" is callout semibold
   (12 pt), "−75 %" is title2 rounded semibold (17 pt), joined by a middle dot that belongs to
   the small text. The pill reads as two labels glued. Principle: one figure is the hero, the
   rest is caption, and they are set as a pair, not a string. `render result-hover-light`.
3. **S1. Five ways to say "working".** While compressing: a sheen sweeping every 1.1 s, a
   progress hairline on the rim, a capsule saying "Optimising…", and for long jobs a wing with
   a ring and "12 s left". Four indicators at once on a 200 pt object in peripheral vision.
   Principle: one status, one place. `render result-activity-dark`, `result-compressing-dark`.
4. **S2. The hover row is five riddles.** Undo, convert, downscale, crop, more: 28 pt circles,
   icon only. "Convert" is two opposed arrows, "downscale" is arrows pointing inward; neither
   says what it will produce, and both act at once with a default the person never chose (WebP,
   half). Hit targets are 28 pt with 7 pt gaps. Principle: a control states its outcome before
   it is pressed. `render result-hover-light`.
5. **S2. Hover moves the neighbours.** At the bottom corners the results above move up 38 pt to
   make room for the row, on every pass of the pointer over the stack. A high-frequency
   layout shift, animated. Principle: no motion on tens-of-times-a-day interactions; an object
   never moves because the pointer crossed another. `render stack-hover-dark`,
   `FloatingStackView.rowRoom`.
6. **S2. The detail is a crossfade dressed as a morph.** Thumbnail leaves at scale 1.4 while
   the detail enters at 0.62, both fading. Without Liquid Glass (macOS 14–25, and Reduce
   Transparency) two objects overlap for 400 ms. Principle: a state change is one object
   transforming. `FloatingResultView.swift:46-49`.
7. **S2. The detail card repeats the thumbnail and adds little.** Header "✓ Optimised", two
   pills on the picture ("Original", "Optimised"), "2.4 MB → 612 kB", "−75 %", a bar, "PNG →
   PNG", dimensions, then five buttons that are the hover row again as words, in a two-column
   grid with "Crop" orphaned on the third row. "PNG → PNG" says nothing. The buttons are 7 %
   fills with a white hairline and look disabled. `render result-detail-light`.
8. **S2. The deflate bar reads backwards.** After a 75 % saving the bar is 25 % full in green.
   A quarter-full green bar reads as "25 % done" or "saved 25 %". The saving, the thing the
   app celebrates, is drawn as the empty part. Principle: the encoding matches the claim.
   `render result-detail-light`, `batch-finished-light`.
9. **S2. The wing is a second object.** 204 × 76 pt with 38 pt and 15 pt corner radii beside a
   12 pt thumbnail: larger than the thing it annotates, in a shape used nowhere else, and
   after the result it repeats the capsule's figure ("37 MB · −75 %" twice, 60 pt apart).
   `render result-activity-done-light`.
10. **S2. The error is three alarms and a hidden button.** A 1.5 pt red rim on the picture, a
    red title, a capsule under the thumbnail; the retry is the words "Try again" in secondary
    grey at the end of a line, and the whole capsule is the click target. Nothing looks
    pressable. The upload error leaks the server's text: "(403): AccessDenied, Access Denied."
    Principle: an error says what happened and shows the way out as a control.
    `render result-error-light`, `result-upload-failed-light`.
11. **S3. The frame is a mat, not glass.** 3 pt of glass around a picture reads as a white
    photo border in light and a bright rim in dark. `render result-saved-dark`.
12. **S3. "Already optimised · 41 kB"** uses the success tick for a non-event, at the same
    weight as a real saving. `render result-already-optimised-light`.
13. **S3. The notice** ("Skipping the next copy / Press again to pause everything.") is a
    different shape (16 pt rounded rectangle), has no symbol and teaches a hidden three-state
    hotkey by toast. `render result-notice-light`.

## Menu bar: glyph and menu

1. **S1. The menu is a list of commands, not the product.** Thirteen items and three submenus.
   It never says what the app did for you: no savings today, no thumbnails, no state of the
   last result. Recent results are strings: "photo.png  −72 %  1.2 MB → 340 kB", double spaces
   as columns, proportional digits, no picture, in a product about pictures.
   Principle: recognition over recall; show the thing, not its name. `MenuContent.swift:95`,
   `render menu-light`.
2. **S1. Three submenus list the same files.** "Recent Results", "Compare" and "Restore
   Original" are one list of recent files with three verbs. The person picks the verb first and
   the file second, three times over. Principle: object first, then action.
3. **S2. Pause is a checkbox, the hotkey is a cycle.** The menu toggles pause on or off; ⌃⇧P
   cycles skip-next, pause-all, resume. Two models for one feature, and no way to pause for a
   time (Clop: for the next copy, 5 min, 1 h). `MenuContent.swift:41`.
4. **S2. Status is two disabled text rows.** "Watching the clipboard" and "Watching 2 folders"
   in the grey of disabled items, at the top, where the eye lands first.
5. **S2. "Optimise Clipboard Harder".** "Harder" is the app's private word for aggressive
   compression; it also appears as "Drop to optimise harder" and "Hold ⌘ for harder". The
   settings say "aggressive". Two names for one mode. Principle: one name per concept.
6. **S2. Housekeeping at the same level as the product.** "Welcome to L'Esclop…", "Check for
   Updates…", "Pipelines…", "Settings…", "Quit" are five flat rows; the tour stays in the menu
   for ever.
7. **S2. The glyph says nothing while working.** Paused is the glyph at 45 % opacity, which is
   also how macOS draws every menu bar item on an inactive display. Working has no state at
   all. `MenuBarLabel.swift`, `render menu-bar-glyph-light`.
8. **S3. The glyph is heavy.** A 28 × 18 pt solid silhouette, wider than any system item and
   blacker than the SF Symbols beside it. The foot cavity closes up at 1x.
   `render menu-bar-glyph-dark`.

## Options popover

1. **S1. The controls are behind a fold.** The popover opens on a "Suggestion" card and a
   collapsed "Format and options". The person who clicked "…" to change the format sees no
   format. Principle: the common path first; do not hide the reason the surface exists.
   `render options-suggestion-light`.
2. **S1. The suggestion card is upside down.** Reading order: a grey caption "Screenshot (PNG)",
   then bold "Suggestion", then "PNG · Adaptive · strip metadata", then "✓ Applied" or an
   "Apply" button. The label "Suggestion" is the loudest word and carries no information; the
   proposal is the quietest. When it is already applied the card proposes nothing.
   `render options-suggestion-light`, `options-rule-light`.
3. **S2. A popover that scrolls.** The Size tab with the crop preview is taller than 560 pt and
   scrolls inside the popover. `live dark-*-_nspopoverwindow` (scroll bar at the right).
   Principle: a popover is one glance; what needs scrolling is a window.
4. **S2. Share is a ragged grid.** Six 44 pt buttons with labels that wrap ("Save as…", "Quick
   Look") and a third row of shortcuts that only four have. In Catalan "Comparteix…" breaks
   mid-word as "Compart / eix…" and "Desa com a…" truncates. `render options-share-light`,
   `live ca-*-_nspopoverwindow`.
5. **S2. Six formats, four plus two.** The tile grid orphans HEIC and GIF on a second row and
   prints "≈" five times. The selected tile is a green outline on a green wash with green text.
   `render options-format-light`.
6. **S2. Colour as a label.** "Aggressive" is orange text inside a native segmented control;
   the other two segments are black. A segment that shouts before it is chosen.
   `render options-format-dark`.
7. **S2. The rule sentence is machine-made.** "Always apply to PNG copied files", "Always apply
   to MOV screen recordings", "Always apply to PDF exported documents". The Catalan is
   "Aplica-ho sempre als fitxers PNG copiats". And under a ticked box: "Next PNG screenshots
   will become WebP · Adaptive". `render options-rule-light`, `options-pdf-light`.
8. **S2. Settings disguised as footnotes.** "Keep visible · 10 s ›" and "Customise buttons…"
   are 11 pt grey text at the bottom of Share. They are settings of the app, not of this file.
   `render options-share-light`.
9. **S3. The header thumbnail is 40 pt.** In a popover about one picture, the picture is the
   size of a list icon, and the name beside it is not visibly editable.
10. **S3. "⌥ keeps both"** teaches a modifier with three words and no state: nothing changes on
    screen while ⌥ is held. *(code)*
11. **S3. The arrow.** In live captures the popover's arrow is a small notch at the bottom-right
    corner, clipped by the custom surface. `live dark-14-popover`.

## Drop zone and preset zones

1. **S1. It is a web upload box.** A dashed rounded rectangle inside a rounded rectangle, an
   arrow in a tinted square, "Drop to optimise". The dashed border is the oldest cliché of file
   upload on the web and exists nowhere in macOS. It is also the only surface that is not
   glass. `render drop-zone-light`.
2. **S1. Preset zones are unreadable at drag speed.** 92 × 64 pt dashed cells with 10 pt labels
   that are pipeline file names ("to WebP", "fit under 1 MB", "pdf for sending", lower case),
   two lines at most, so "Screenshots for the blog post" wraps at 10 pt. A drag gives the
   person a second or less. Principle: Fitts, and legibility in motion.
   `render drop-zone-presets-light`, `live zones13-en-04-show-image`.
3. **S2. Boxes in boxes, and a hole.** Three presets leave an empty cell in the 2 × 2 grid; the
   main zone stretches to twice its height to match and is mostly empty. Five dashed rectangles
   nested in a sixth. `live zones13-en-12-show-all`.
4. **S2. A modifier taught mid-drag.** "3 files. Hold ⌘ for harder" in 10 pt, read while
   holding a mouse button and aiming.
5. **S2. The hover state is a darker dash.** The target under the drag changes from 45 % to
   90 % dash opacity and a faint fill. No growth, no magnetism, no confirmation on drop.
   `render drop-zone-hover-light`, `DropZoneView.swift:58`.
6. **S3. Light preset cells nearly vanish.** 35 % green dashes on a 97 % white card.
   `render drop-zone-presets-light`.

## Batch window

1. **S1. One bar, two meanings.** While running, the header bar is progress. When finished the
   same bar, same colour, same place, is the deflate bar at the new proportion. At 71 % saved
   it sits at 29 % and looks like a batch that stalled. `render batch-running-light` against
   `batch-finished-light`.
2. **S2. Row bars are stubs.** Each row has a 180 pt bar under the name, unrelated in length to
   the row, far from its figure at the right edge, and backwards as in the detail.
   `render batch-finished-dark`.
3. **S2. Hover erases the figure.** On hover the saving is replaced by round buttons: the
   number being read disappears under the pointer that came to read it.
   `live roundB2-*-batch` (row 4).
4. **S2. A restored batch is a ghost.** After Restore All the header keeps an empty bar track,
   a disabled "Restore All" and, in one capture, "0 de 6 fitxers optimitzats · 16 MB → 16 MB"
   with a full green bar. `render batch-restored-light`, `live ca-*-lot`.
5. **S2. Failure is grey.** "5 optimised · 1 already optimised · 1 failed": the failure has the
   weight of the rest and no way to jump to it.
6. **S3. Generic chrome.** Window title "Batch"; four stock bordered buttons with icons; grey
   placeholder squares where thumbnails load.

## Compare window

1. **S2. A hand-made toolbar under the title bar.** File name and saving at the left, a
   segmented control, a zoom cluster of borderless green icons and a text button "Fit" at the
   right, then a second row at the bottom with two captions, two metadata lines and five
   buttons. The title bar says "Compare shot-1.png" and the row below says "shot-1.png" again.
   A real `NSToolbar` would give this for free. `render compare-split-light`.
2. **S2. "Keep" is the default button and does nothing.** It closes the window. The default
   action of a compare window should not be a synonym for the close button.
3. **S2. The canvas is one grey for both appearances** and has no checkerboard, so transparent
   areas and letterbox look the same. The empty states put dark grey 11 pt text on that grey:
   "The original is no longer kept". `live c10-*-compare-shot-2-png`.
4. **S3. No motion at all.** Split to side-by-side to flip snaps. Flip is the one place a
   120 ms crossfade is information (it is how you see the difference). *(code)*
5. **S3. Tags** are 10 pt black pills over the picture's corners, where artefacts hide.

## Settings

1. **S1. Ten panes of identical rows.** General lists eight pickers that are one decision per
   media kind ("Optimised images go", "Optimised videos go", "Optimised PDFs go", "Optimised
   audio goes", then four "Converted … go"). Images has three "Always optimise JPEG / PNG / GIF
   aggressively" switches in a row. These are matrices drawn as lists. Principle: group by
   decision, not by registry key. `render settings-search-light`, `live ca-01-set-general`.
2. **S1. Registry vocabulary on the surface.** "Same folder name · %f-optimised", "Specific
   folder path · %d/optimised/%f", "Convert to JPEG · webp, avif, heic, bmp" as a free text
   field, "Image compression · 45" with no unit and a caption that explains the scale. This is
   a config file with switches. `render settings-search-light` (General and Images panes).
3. **S2. Reordering by chevrons.** Preset zones and pipeline steps move with ⌃ and ⌄ buttons.
   macOS lists reorder by drag. `render settings-preset-zones-light`.
4. **S2. The Agents pane is a wall.** Sixteen agents, each with a status dot, a path in grey, a
   sentence and one or two buttons; then three paragraphs of explanation. It is correct and
   honest, and nobody will read it. `render settings-agents-connect-light`.
5. **S2. The upload sheet wastes its height.** Labels at the left, values right-aligned 300 pt
   away, then 150 pt of nothing, then a footnote of path tokens. `render settings-upload-editor-light`.
6. **S3. System alerts mix languages.** "Delete "scripted"?" with "Cancel·la" beside "Move to
   the Trash". `live r5-*-_nsalertpanel`.
7. **S3. Sidebar icons are tinted green**, the titles sit in secondary grey: decoration louder
   than text.

## Onboarding

1. **S1. The tour never shows the product working.** Five screens and the person has not seen
   one file get smaller. The most convincing ten seconds the app has (copy a screenshot, watch
   it shrink) are described in a bullet. Principle: show, then tell.
   `render onboarding-1-welcome-light`.
2. **S1. Three of five steps are Settings.** "What happens on its own" is six setting rows,
   "What macOS will ask" three more, "Connect an AI agent" the whole Agents list with sixteen
   entries and file paths. A first run that opens on a preferences form.
   `render onboarding-2-automatic-dark`, `onboarding-4-agents-dark`.
3. **S2. Inconsistent stage.** Steps 1 and 5 are centred with a hero; 2 to 4 are left-aligned
   forms with 40 % of the window empty below them.
4. **S2. The last screen is a stock success screen.** A 56 pt green tick, "L'Esclop is in the
   menu bar", the glyph inline in a sentence and off its baseline, three hotkeys as loose
   glyphs ("⌃⇧P") not key caps, and three buttons. `render onboarding-5-done-light`.
5. **S3. A feature list as a welcome.** Four icon-title-sentence rows: the template every app
   ships.

## Pipeline editor

1. **S1. The form does not look like a pipeline.** A pipeline is a sequence, yet the steps are
   form rows separated by hairlines, each with the same sparkle glyph, a number, up and down
   chevrons and a minus. No flow, no connection, no sense of a file travelling.
   `render pipelines-form-light`.
2. **S2. Identifiers leak.** Each step shows its title and under it its code name in monospace
   ("Crop / crop", "Convert / convert", "Run a script / runScript"); errors name parameters in
   code ("`longEdge` must be a whole number…"); the text mode's error says "See the list of
   steps in docs/pipelines.md", a file in the repository.
3. **S2. "Steps for [Any file] … Steps for a Kind ⌄".** A grey pill that looks selected, a
   label, and a green link, three controls for one idea. In the live app the pill is a
   full-width green bar. `live r5-12-p-open`.
4. **S2. Unlabelled toolbar.** Play, undo and save as three grey icons at the top right; add,
   duplicate and delete as three 11 pt icons at the bottom left of the sidebar.
5. **S3. Template names are file names** ("to WebP", "pdf for sending") beside the person's own
   capitalised ones, each with a padlock.

## Copy, English and Catalan

1. **S2. One concept, several names.** Harder / aggressive; Undo / Restore original / Restore
   All / "The original is back"; Downscale / Size / "Downscale to half"; Optimise / Compress
   ("comprimir més" in the Catalan drop zone against "optimitza més" in the menu).
2. **S2. Catalan is a translation, not a voice.** "Deixa anar per optimitzar", "Zona per
   deixar anar", "Passa per un pipeline", "Finestra del lot a partir de": literal, long and
   stiff. Labels grow 30–40 % and break the Share grid and the drop zone
   (`live zones13-ca-12-show-all`: the hint wraps to two lines).
3. **S3. Middle dots carry everything.** "2.4 MB → 612 kB · −75 %", "PNG · 2940 × 1912",
   "Original kept · Try again", "5 optimised · 1 already optimised · 1 failed". A dot joins a
   figure to a figure, a fact to a button and a count to a count.

## What is good and must survive

- The floating result as an object at the corner that never takes focus, with the gesture of
  the system screenshot thumbnail.
- Origin-aware suggestions and "Always apply" rules: clever, and unlike Clop.
- Honest, reversible actions: originals kept, undo everywhere, a diff before an agent's
  config is written.
- Contrast computed and tested (`PopoverInk`), Reduce Motion and Reduce Transparency handled,
  VoiceOver actions on the result.
- The clog. The icon has more character than anything in the UI, and the UI uses none of it.

## Where the overhaul should spend

1. One material and one geometry for every floating surface (result, popover, drop zone).
2. The result figure as typography, off the picture.
3. An accent with one job.
4. A menu that shows results, not commands.
5. Settings cut by half in words, grouped by decision.
6. A first run that makes one file smaller.
