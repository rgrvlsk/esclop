# Design brief

This brief describes the planned GUI. The current app is a minimal menu-bar stub.
Results should be easy to read without interrupting work, using native macOS controls.

## Result animation
A file deflating. When a result arrives, the card shows the original size as a full-width bar;
the bar contracts in one spring to the new proportion while the figure counts down and the
saving appears. Nothing else on the card moves on its own. Everything after that answers the
person's action: convert, downscale, crop, undo.

## Color
Use system materials for panels, with one accent colour and one warning colour.

| Token | Light | Dark | Role |
|---|---|---|---|
| `accent` | `#1E7F6A` | `#3DBF9F` | savings, progress, primary actions |
| `warm` | `#B8741C` | `#E0A040` | aggressive mode, "fit under size" |
| `ink` | `#1B1F1E` | `#F2F4F3` | primary text (used only where system label colors cannot) |
| `clog` | `#8A5A33` | `#8A5A33` | app icon wood only, never in UI |
| error | system red | system red | failures |

Never: cream page backgrounds, terracotta, acid green on black, gradient washes.

## Type
System font (SF Pro) everywhere, sizes from the macOS text styles. Byte figures and
percentages use monospaced digits so they do not jitter while counting. The saving percentage
is the one large figure on a card: `title2`, semibold, rounded design. Labels are sentence case,
never all caps, never tracked out.

## Layout
- Result cards: thumbnail left, text right, actions on hover below. Left aligned. Width 300pt,
  stack at a screen corner with 8pt gaps, newest at the bottom.
- Drop zone: a single rounded rectangle at the cursor or screen edge, label "Drop to optimise",
  holding Command changes it to "Drop to optimise harder".
- Settings: sidebar sections, forms with native controls, search at the top.
- Radius: 10pt for floating panels, 6pt for controls. One shadow for floating panels
  (system `NSVisualEffectView` with `.hudWindow` material plus a 1pt hairline border).

## Motion
`reduceMotion` turns the deflate into a crossfade. Durations: 450ms spring for the deflate,
180ms for hover reveals, 220ms for cards entering and leaving. No idle motion.

## Copy
Say what happens: "Optimise", "Convert to WebP", "Fit under 1 MB", "Undo", "Keep original".
Errors say what went wrong and what to do: "ffmpeg is missing. Reinstall esclop or run
Scripts/build-tools.sh".

## Icon
A wooden clog (an *esclop* in Catalan) seen from above, flat, two tones of `clog` wood on a
macOS squircle in `accent`. It is not Clop's mark and must not resemble it.
