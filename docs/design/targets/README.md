# Visual targets

Generated mockups of the look the build should reach, one or more per build PR. They borrow the
visual language of public UI work by @uiuxjosh on X, applied to our own surfaces, refined by a
design council and then ranked and annotated by the owner.

They set the look. Where one disagrees with `../proposal.md`, the proposal wins, **except for the
owner's decisions below, which win over both**. Pictures, filenames, dates and sizes are filler.

## Owner's decisions (2026-11-13)

- **Result card actions depend on where the file came from:** a copied screenshot and a dragged
  file get different actions (`pr2-result-card-contextual`). Draw them as icons, and choose them
  for what the person most likely wants next.
- **No blue focus outline on the card;** on hover a halo in the picture's tone that grows brighter
  near the pointer (`pr2-result-card-hover-halo`).
- **Failures:** the grouped pill expands into the list, with the reason and Retry on each
  (`pr2-failed-expanded`).
- **Compare is a loupe:** original and optimised swap on click, and also while the mouse button is
  held. Offer it only when the loss is visible (lossy formats) (`pr6-compare-loupe`).
- **First run is three steps** (`pr8-first-run-step1..3`). Never show compression as the image
  getting smaller: it is the same image, lighter.
- **Pipelines** as in `pr9-pipeline-editor`.
- **Settings** (`pr7-settings`) is the direction, but needs more hierarchy: too many equal blocks.
- **The menu-bar glyph stays the existing one;** no glyph-state sheet. **No paused state in the
  menu panel.** The panel needs a quick Clear for recent results (privacy).
- Still open, to be redrawn: the options popover tabs, the menu panel, the saving figure with the
  original size, the detail card.

## Known disagreements to ignore

- **All:** the generator only approximates SF Pro Compressed; the proposal's type and the
  `saving` teal (#176B59 light, #63D6B8 dark) stand.
- **pr2-result-card-dark-stack:** the light desktop behind the dark card is wrong; the amber
  stroke is over-saturated.
- **pr4-options-popover:** the saving figure appears twice; the popover header shows sizes only.
- **pr2-failed-not-uploaded:** the Finder thumbnail strip under the failed card is filler.
