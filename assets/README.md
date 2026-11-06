# L'Esclop artwork

The approved identity is the carved Dutch wooden clog, with a rounded monochrome version for the menu bar.

- `icon-wood.png`: the approved wood artwork, kept at its original resolution and transparency.
- `icon.svg`: the app icon composition, the wood artwork on the green macOS squircle, scaled to Apple's icon grid (an 824 px squircle centred on the 1024 px canvas) so it matches system icons in the Dock and Finder. It references `icon-wood.png` in this folder.
- `AppIcon.png` and `AppIcon.icns`: the generated app icon. The ICNS holds the standard and Retina sizes from 16 to 1024 pixels.
- `mark.svg`: the scalable monochrome mark, with a transparent foot cavity.
- `menubar.svg`: the rounded 28 × 18 pt optical variant for the menu bar. Its PDF export is `Sources/EsclopAppKit/Resources/MenuBarIcon.pdf`; the app draws it as a template image, so macOS tints it for light and dark menu bars.

`make icons` (`Scripts/build-icons.sh`) regenerates `AppIcon.png`, `AppIcon.icns` and `MenuBarIcon.pdf` on macOS. It needs `rsvg-convert` from librsvg, plus the system `sips` and `iconutil`. Run it on the host: a restricted sandbox can make `iconutil` reject a valid iconset when macOS image services are out of reach. Regenerating gives byte-identical PNG and ICNS files; the PDF differs only in its creation date.

The bundler uses the committed exports and needs no SVG tools. `Scripts/bundle-app.sh` copies `AppIcon.icns` into `Contents/Resources` (the Info.plist names it in `CFBundleIconFile`) and EsclopAppKit's resource bundle, which carries `MenuBarIcon.pdf`. `MenuBarLabel` loads the glyph through `Bundle.module`, in development and in the packaged app alike.
