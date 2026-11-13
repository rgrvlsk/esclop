# Visual targets

Generated mockups of the look the build should reach, one or more per build PR. They borrow the
visual language of public UI work by @uiuxjosh on X, applied to our own surfaces, refined by a
design council and then ranked and annotated by the owner.

They set the look. Where one disagrees with `../proposal.md`, the proposal wins, **except for the
owner's decisions below, which win over both**. Pictures, filenames, dates and sizes are filler.

## Owner's decisions (2026-11-13)

### Visual grammar

Each signal has one meaning. Keep it on every surface.

- **Arc or ring with a white dot:** a finished saving, from the original size to the new one. Only
  a finished result gets one.
- **Aqua tint with a straight 4 pt bar:** work in progress. Progress is never a ring, so it cannot
  be mistaken for a saving (`pr2-progress-vs-saving`).
- **Amber:** needs a decision (a suggestion, a failure, a missing permission).
- **Cream tile:** resting content. **Circular pill:** pressable. **Charcoal fill:** selected or on.
- **Small caps:** one section label per tile, never data. **New York serif:** one heading per
  surface, never data or buttons.
- **No system blue:** switches are charcoal when on, text buttons charcoal semibold, buttons white
  pills with charcoal text. No phone-style tab bars.
- **The saving figure** is SF Pro Compressed Bold in `saving` teal, unit on the same baseline. The
  original size is brick red (#B83A2B light, #E0705E dark), the new size grey.

### Surfaces

- **Result card actions depend on where the file came from:** a copied screenshot and a dragged
  file get different actions (`pr2-result-card-contextual`). Draw them as icons, and choose them
  for what the person most likely wants next.
- **Result card states** as in `pr2-result-card-states`, with progress drawn as above.
- **No blue focus outline on the card;** on hover a halo in the picture's tone that grows brighter
  near the pointer (`pr2-result-card-hover-halo`).
- **Detail card:** smaller metadata box; actions are 1 + 2: the most likely action stands out, two
  more beside it, and a small menu button for the rest (`pr2-detail-card`).
- **Failures:** the grouped pill expands into the list, with the reason and Retry on each
  (`pr2-failures`).
- **Menu panel** (`pr3-menu-panel`): no per-day history. The saving switches between Today and
  7 days, with "Last 7 days" under it. The menu-bar glyph stays the existing one; no paused state.
  Recent results have a quick Clear (privacy).
- **Options popover:** fused round tabs (`pr4-options-popover-tabs`); Size and Actions tabs as in
  `pr4-options-popover-size-actions`. Clicking an image format converts at once; for video the
  tile arms Convert.
- **Drop zone** is a shelf that drops from the menu-bar glyph (`pr5-drop-zone`).
- **Batch** (`pr6-batch`) and **results window** (`pr6-results-window`).
- **Compare is a loupe:** original and optimised swap on click, and also while the mouse button is
  held. Offer it only when the loss is visible (lossy formats) (`pr6-compare-loupe`).
- **Settings** use expandable panels: each panel turns a feature on or off and opens its
  sub-options (`pr7-settings`).
- **First run is three steps** (`pr8-first-run`). Never show compression as the image getting
  smaller: it is the same image, lighter.
- **Pipelines** as in `pr9-pipeline-editor`.

## Known disagreements to ignore

- **All:** the generator only approximates SF Pro Compressed; the proposal's type and the
  `saving` teal (#176B59 light, #63D6B8 dark) stand.
- **pr2-result-card-dark-stack:** the light desktop behind the dark card is wrong; the amber
  stroke is over-saturated.
- **pr2-failures:** the sizes on the failed card are in the wrong order; original comes first.
- **pr4-options-popover-size-actions:** "Half ≈ 610 kB" is wrong; compute it from the real size.
- **pr2-failed-not-uploaded:** the Finder thumbnail strip under the failed card is filler.
