# Changelog

All notable changes to L'Esclop are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/). `Scripts/release-notes.sh` turns a version's section
into the body of its GitHub release.

## [Unreleased]

The design's floating results, menu bar panel and drop zone; a loupe to compare; copied media
links offered for download; Originals, Open With and settings you can carry to another Mac.
0.1.1 finds this update by itself.

### Added
- The detail says what optimising removed from a photo's metadata (location, camera, date) and
  offers Restore, which runs the file again from its original and keeps the metadata. A crop,
  scale or Fit stays.
- Save for a copied screenshot: one click puts it in Downloads as "Copied image" with the date
  and time, and the button then shows it in Finder. "Save as…" is in the detail's "…".
- Share… and Move to Trash in the detail's "…". Share opens the system's share services; Move to
  Trash takes an optimised file to the Trash (its backup stays) and removes the card. Neither a
  copied image nor an untouched original can be trashed from there.
- Compare in the detail is a loupe for a picture that lost detail: a lens at true size follows
  the pointer; a click shows the original and stays, holding shows it until release. Space,
  the arrows and Esc work from the keyboard.
- Two or more failures share one place in the stack: an amber pill ("3 not optimised") that
  opens into their list, each with why and Retry, and Retry All and Dismiss. They no longer push
  the results off the screen.
- The menu bar opens the design's panel instead of a system menu: the saving today or over the
  last 7 days on an arc, the batch at work or the last one that ended (Restore All and Retry stay
  one click away), the recent results with Copy and Show in Finder on hover, and Optimise Files
  and Optimise Clipboard. The gear holds Settings, Pipelines, Originals…, the backups, Pause
  L'Esclop, the tour, updates and Quit.
- Originals… lists every original L'Esclop keeps, with its folder and thumbnail. Space previews
  it; select several to Restore or Remove them. The list follows new and pruned backups while it
  is open, and says which files it could not remove.
- The batch window selects rows (⌘A, shift-click, arrows) and optimises the selection again with
  another format or compression, crops it, scales it down, restores it or retries it. A row can
  show as a result, be dragged out, or open in Quick Look with Space. Retry All Failed retries
  every failed file.
- Open With L'Esclop and a drop on its Dock icon optimise images, videos, PDFs and audio.
  L'Esclop never becomes their default app.
- Settings › General › Export… and Import…, and `esclop settings export` and `import`, carry your
  settings to another Mac.
- Watched folders can skip formats, and images or videos by their size in pixels, each folder on
  its own. An `.esclopignore` (or Clop's `.clopignore`) file in the folder skips the names it
  lists.
- The Crop tab has paper and device sizes (the CLI's list), the last five sizes you typed, and
  Centre or Smart framing that shows where a smart crop cuts.
- Pages as Images on a PDF result saves every page, optimised, in a folder beside the PDF.
  Extract Cover on an audio result saves its cover art beside the file and optimises it.
- Settings › General › Menu bar: Show menu bar icon, and Show L'Esclop in screenshots. The second
  is off by default, so result cards, the drop zone and the panel stay out of screenshots and screen
  recordings.
- Open at login is also in Settings › General.
- "Show floating results" in Settings, and a "Show the last result" hotkey.
- "Gather clipboard results" (Settings › Clipboard, off by default): each new result joins the
  ones L'Esclop last put on the clipboard, so one paste gives them all. It starts again after
  30 seconds without a new result.
- Recent › Clear forgets the names of recent results and the last finished batch, in the panel
  and in the shared log the CLI and MCP read: only sizes and dates stay, so the saving still
  counts. Files and backups are not touched.
- Recent in the menu bar panel brings back a card that newer results hid, a copied image with
  its Copy. It works with the arrow keys, Return and VoiceOver.
- "Go to the newest result" (⌃⇧N by default, in Settings › General) gives the newest result the
  card keys, so a copied screenshot can be undone from the keyboard alone. Esc gives the keys
  back to the app you were in.
- The drop zone takes photos from Photos, attachments from Mail, and images and videos dragged
  from a browser. A tap on ⌥ during a drag opens the zone under the pointer; "Show the drop zone
  only after tapping ⌥" shows it only then.
- Pipelines with the clipboard or drop-zone trigger run in the app on what you copy or drop,
  for the kinds of file they have steps for. A pipeline's `hotkey` runs it on the clipboard. In
  the app, pipeline steps copy to the clipboard, open the file with an app, hand it to Yoink,
  Dropover, Dockside, Atoll or Dropshare, and show a `fork` as a result of its own.
- "Downscale Retina screenshots" works: automatic optimisation halves a 2x (144 dpi)
  screenshot, saved or copied. Other 144 dpi pictures keep their size.
- `esclop recent` lists the recent results and `esclop restore <file>` puts an original back.
- `esclop optimise https://…` downloads the address first, writes the result into the working
  directory and prints its path (with `-o` or `--behaviour temp`, it goes there instead). It
  warns about plain-http addresses; other schemes are refused.
- `esclop optimise image|video|pdf|audio` takes one kind of file only. `--bitrate` sets the
  bitrate of videos and audio in `optimise` and `convert`. `--adaptive` and `--no-adaptive`
  override the "Adaptive image format" setting. `esclop recent` shows where each result came
  from (`origin` in `--json`).
- Shortcuts: Crop PDF, Change Playback Speed and Optimise from URL actions. Every file action
  can choose where results go, the compression, removing a video's audio, hiding the floating
  result and copying the results to the clipboard. Many files from one Shortcut open one batch
  window.
- Finder's Quick Actions work on folders, and Optimise has a key equivalent.
- The CLI says on stderr when `--pdf-dpi`, `--remove-audio` or `--playback-speed-factor` do not
  apply to a file.
- MCP `esclop_restore_backup` lists the files it set aside in the Trash (`movedToTrash`).
- MCP: progress notifications for tool calls that send a progress token. `esclop mcp install`
  also knows Antigravity, Kimi Code, Crush and VS Code Insiders.
- Settings › Uploads warns when a Cloudflare R2 target has no public link, and Test Upload
  checks that the copied link opens without the keys.

### Changed
- Copying the web address of an image, video, PDF or audio file offers to download it. Nothing
  is fetched until you click. Settings › Clipboard › Copied web addresses can download on its own
  or do nothing instead (`optimiseURLClipboard`: `offer`, `download` or `ignore`). Other links
  are never opened.
- Every download shows its progress on a card from the start, with Stop. Downloads stop at 2 GB
  and after an hour, and refuse an answer that is not an image, video, PDF or audio file (also a
  web page at an image's address). Downloads from a copy also send no cookies, wait for Low Data
  Mode to end, run one at a time, keep to the kind's size limit, and never reach this Mac or the
  local network.
- ⌃⇧P pauses or resumes at once and says which in a short notice; it no longer skips the next
  copy first. Pause L'Esclop and Resume L'Esclop are in the panel's gear.
- Copying an image file in Finder no longer changes it on disk: L'Esclop optimises a copy and
  puts that copy on the clipboard, as Clop does. A clipboard pipeline also works on a copy.
- Hold ⌥ while dropping to keep the originals: the results go beside them, also on a preset
  zone. Its pipeline runs on a copy beside the original, which goes again when the pipeline
  writes its result elsewhere.
- Result cards take Clop's keys while the pointer rests on them, with no click: Space Quick
  Look, ⌘Z Undo, ⌘C Copy, ⌘F or ⌘R Show in Finder, ⌘D Compare, ⌘K Crop, ⌘S Save to Downloads,
  ⇧⌘S Save As, ⌘A optimise harder, ⌘O open, ⌘U upload, ⌘X playback speed, ⌘⌫ Dismiss, ⌘- and
  ⌘1–⌘9 to downscale. Space on a focused card or a Recent row opens Quick Look; Return opens the
  detail. "Card keys under the pointer" (Settings › General › Keyboard shortcuts) turns them off.
- Images dropped from Safari or Photos get Copy, Save to Downloads and Save as…, not Show in
  Finder on a temporary folder.
- Converted files keep their plain name (`photo.webp`), and new JPEGs use `.jpg`. With no place
  chosen for the job, a conversion goes where "Converted images/videos/audio go" says (next to
  the original for images), in the app, the CLI and for agents (MCP). An agent still never
  replaces an original without the person's permission.
- JPEG XL is no longer offered as an output on a Mac that cannot write it (macOS 26 reads JPEG
  XL only).
- Undo takes a result out of Recent Results, and it no longer counts in "Saved".
- Audio keeps its title, artist and album when optimised; only "Remove metadata" strips them.
- Apple Lossless files stay lossless unless you convert them or add `alac` to "Convert to AAC".
  Lossless output keeps its bit depth and sample rate.
- Video optimisation and Strip keep every video and audio track, track languages, chapters
  (except after a speed change) and the subtitles the format can carry. MKV to MP4 keeps text
  subtitles.
- Crops, resizes and conversions keep the picture's density (Retina screenshots, print photos).
  Titles and keywords (XMP) reach WebP, AVIF and PNG when metadata is kept.
- A crop larger than the picture or video never enlarges it, and says so. GIFs follow the
  playback speed; fitting a GIF to a size is refused instead of making an MP4. Audio downscale
  lowers the bitrate by the factor.
- Multi-page TIFFs and animated images are never flattened to their first page or frame, and
  are not converted automatically. Asked to become a single-image format, they stay as they are
  with a reason.
- Compression matches Clop at every stop: "Adaptive image format" encodes from the original, an
  alpha channel without transparent pixels no longer keeps a picture in PNG, and the strongest
  stops cap the PNG palette and drop GIF frames. A lossy re-encode replaces the original only
  when it saves at least 3 %. JPEG optimisation is about a third faster.
- Cropping or uncropping a signed PDF is refused, so its signature stays valid.
- A crop and a scale stay with the result: another format or quality runs them again from the
  original, until Original or Reset.
- The options popover does what it shows: Save As never deletes the file, Keep Both saves its
  copy beside the file and keeps a crop, scale or Fit, the rule line says what the rule does,
  and Actions shows only the pipelines for the file's kind.
- Watched folders work each on their own: a burst of files in one no longer skips files in
  another, and folders that are renamed, deleted or created later are noticed at once. A
  screenshot or other file that arrives whole starts at once; a file still being written must
  stay unchanged for 1.5 s first, so a network copy that pauses is not taken half-written. The
  "More than N at once" notice offers Optimise Them Anyway.
- ⌃O and the Finder actions ask once before they work through a folder with many files.
- Running a pipeline on many files from the pipeline editor, or on a burst of new files in a
  pipeline's watched folder, shows one batch window, like Finder and the drop zone.
- A Shortcuts action whose file fails names every failed file and says how many others were
  optimised.
- `esclop pdf pages` and a pipeline's `extractPagesAsImages` optimise the pages they write and
  name them after the PDF, the number padded to the page count (`doc-1.jpg` of 3 pages,
  `doc-01.jpg` of 12). `esclop pdf pages` makes a page that is one photo a JPEG, and `--format`
  offers only png and jpeg.
- With Keep HDR off, an HDR video stays HDR and says why: this build cannot convert HDR to SDR.
  Before, it was 8-bit but still tagged HDR.
- Settings hides the software video encoders the bundled ffmpeg does not have, and the details
  name the encoder that ran.
- Over a preset zone, the drop zone names the pipeline that will run and no longer offers ⌘. A
  dropped folder counts the media inside it and offers only the zones that fit it.
- CLI: a file already as small as it gets, and a file L'Esclop already optimised, are listed as
  unchanged and exit 0. `--force` optimises an already optimised file again; `-a` and a
  `--compression` above 30 do so without it.
- CLI: a relative `-o` starts in the working directory. `-o` with `--behaviour
  inplace|samefolder|temp` is a usage error.
- CLI: `esclop upload` takes only the options it honours and refuses `-o`, `--behaviour` and
  `--in-process`. `--copy` copies every link, one per line.
- `ESCLOP_SUPPORT_DIR` also moves the settings (into a suite of their own) and the engine's
  backups, so scripted runs leave the person's own alone.
- At launch, L'Esclop clears what it left in its temporary folder that is older than the backup
  retention (downloads, dropped files, work folders), and hidden half-written files that a crash
  left beside a result. Old downloads and clipboard copies go every hour, after a week at most.
- A public upload link must contain `{path}`, and files over 5 GB are refused before uploading.
- `hideResult` also hides the floating result when a trigger, Finder or the hotkey runs the
  pipeline.
- The app keeps its charcoal for default buttons, switches and checkboxes whatever the accent
  colour. Catalan uses one verb for optimising and macOS's own names for System Settings panes,
  and wording is fixed in English and Catalan.
- Results do not hide on a timer while VoiceOver is on. With Differentiate without colour, work in
  progress and suggestions carry a symbol.
- On the first run, folder watching starts at the tour's Permissions page, which shows whether
  L'Esclop can read the Desktop. The tour names the screenshot folder when it is not the Desktop
  and offers to watch it.
- Settings search ignores accents, and the reset arrow sits beside the control.
- Fit under stays with the file across other choices, as a crop does; a kept Fit that a new
  choice cannot make is dropped with a notice. A custom Fit shows as its own chip, and a click
  takes it off.
- Recording a result no longer blocks the interface, and the menu opens without reading the
  whole results log. Tool errors go to the system log as private data.
- The options popover takes the design's shell: round tabs with the
  chosen one fused into the panel, Format · Size · Actions, and no file header. Format shows the
  suggestion as a card with Convert, then the format tiles with their sizes up front: a click
  converts an image at once, a video's tile arms Convert. Rename moved to a click on the detail's
  name. Size has tiles for Original, 2000 px, 1280 px and Half with their sizes, a custom width
  and height and Fit under; Crop is a tab of its own; Actions lists the pipelines, Upload and
  Share… as rows, with Run a Shortcut and Open with. Copy, Save as, Show in Finder and Quick Look
  are the popover's keys; Compare is the detail's loupe; "Keep visible" is in Settings only.
- The drop zone is the design's row of tiles: "Optimise" with the file count and the preset
  zones beside it, raised like the options popover's tiles, the one under the drag in charcoal,
  and "Drop to optimise · Hold ⌘ to optimise harder" under them. No more dashed outlines.
- The options popover stays open while a choice in it runs the file again, so sizes and formats
  can be tried one after another. The Crop tab shows the picture with its frame from the start.
  Its tabs, tiles, chips, rows and fields share one geometry and one elevation, in light and
  dark.
- Compression's Adaptive · Lossless · Aggressive left the popover: the default stays in
  Settings, Lossless lives in Settings only, and "Optimise harder" in Format runs the file again
  aggressively.
- Every size in the app comes from one formatter in the app's locale, so the panel's figure and
  its rows agree on the decimal separator.
- A failed card says what did not happen ("Not optimised", "Not uploaded") with Retry beside it,
  and why across the card, with "The original is untouched." or "The file is kept."
- The saving figure's sizes come from one token: 17 pt in the card's ring, 20 pt in the detail's.
- The detail's × has its own band above the picture, and the picture is at most 200 pt tall.
- The detail's "…" opens the design's own menu instead of a system menu: a cream panel beside
  the card, joined to "…" by a liquid neck, that opens as a drop and sinks back when it closes.
  It is the design's short menu: Convert… (the options popover), Compare, Share… and Move to
  Trash, or Save as… for a copied image.
  It works from the keyboard (arrows, Return, Esc), and Share… shows the system's share
  services. In a right-hand corner the detail's buttons run the other way, so "…" faces the
  screen and its menu has room.
- An agent (MCP) can ask for metadata to be stripped but never kept: `stripMetadata: false`
  follows the "Strip metadata" setting.
- The CLI and MCP server talk to the app on IPC protocol 2. A CLI or app of the other version
  is refused with a version message, never left waiting. Update the CLI and the app together.
- The result card and the detail take the targets' proportions: the picture sits in a 9 pt mount
  with softer corners, the saving ring is thinner with a hairline track, the detail's type and
  buttons are smaller, and the surfaces are lit from above with a lighter shadow. Copy uses the
  two-squares symbol everywhere.
- The floating result is a cream card: the picture over a footer with the saving's ring, the
  original size in red beside the new one, and the file's name. Work in progress tints it aqua
  with a straight bar and the time left; a failure tints it amber with Retry. On hover, three
  round buttons lie over the picture (Copy for a copied screenshot, Show in Finder for a file,
  then Undo and "…") with a close button in its corner, and the card glows in the picture's
  tone. The activity capsule beside long jobs is gone.
- The detail opens on a click, Return or Space, never because the pointer rested on the card.
  It shows the picture, the name with format and dimensions, the saving at a larger size, and
  the actions as one charcoal button (Show in Finder with the folder, or Copy for a copied
  screenshot), up to two round buttons (Copy, Undo) and "…" for the rest. The before/after
  slider moves to the Compare window, in "…". In the open detail Return or Space runs the
  charcoal button; when the file runs again from it, the detail turns aqua and the charcoal
  button is Stop. The detail shows the whole picture, never a crop.

### Fixed
- Undo puts back the original of that exact result, also when the file was optimised again
  later or Recent was cleared. Restoring no longer loses work: a file changed since, and a
  converted copy, go to the Trash instead of being overwritten. A failed restore no longer
  compresses the file again. Restore All stops the batch first and asks.
- A job with several files lists, restores and counts every file, not only the last one.
- Restoring a file from a card, Compare, Recent or Originals and then from the batch window no
  longer sends the original to the Trash as an edited version. After Recent › Clear, Originals
  no longer calls a long encode's result an edited version. Restoring the same result twice at
  once restores it once.
- A re-run or a batch restore that moves your edited version to the Trash says so. A failed Save
  to Downloads or Move to Trash says why. Compare no longer offers Restore Original for a
  conversion that kept its original.
- Removing metadata now also removes the location, camera and EXIF of a resized or cropped HDR
  photo, and the camera and author tags (Make, Model, Artist, Copyright, date) of HEIC and HDR
  photos.
- With metadata kept, converting or resizing a rotated photo keeps its XMP (title, keywords,
  rating), and JPEG crops and resizes keep IPTC keywords. WebP and AVIF made from a PNG or JPEG
  with a density but no EXIF keep its dpi.
- An audiobook (`.m4b`) stays `.m4b`. An audio speed change leaves out the chapters, whose times
  would be wrong, and the details say so. Remove audio no longer drops a video's subtitles.
- With "Adaptive image format" on, a PNG that cannot shrink as PNG is tried as JPEG. A lower
  `--pdf-dpi` never makes an image that it does not downsample larger.
- Something copied while a file is being optimised is no longer replaced by the result. Copying
  several files puts all of them back, in order. `esclop optimise --copy` is no longer optimised
  a second time by the app.
- A pipeline hotkey's `if(copiedBy:)` matches the app the copy came from. The pipeline log no
  longer says adaptive compression "is not available yet".
- Pipelines no longer delete a file at a `copy`, `move` or `rename` destination before the new
  one is written. A step that fails after earlier ones changed the file reports what they did
  and keeps the backup. "Try it" keeps every file in its own folder and runs no scripts or
  Shortcuts.
- Converting in place no longer replaces an unrelated file with the new name: the result takes
  the next free name (`IMG 2.jpg`). An output name whose extension names another format is
  refused.
- Exporting PDF pages no longer replaces files that are already there, and a page that cannot be
  rendered fails the export instead of being skipped.
- Stripping metadata keeps a JPEG's DPI and its EXIF colour space, so Adobe RGB photos keep
  their colours. Keep HDR applies to fit-to-size and to same-size HEIC.
- A stuck ffmpeg is stopped after five minutes without progress, and not after the Mac sleeps. A
  file that crashes the image engine no longer fails the other files, or gets another file
  blamed. Tools stop when L'Esclop quits unexpectedly.
- Cancelling an MCP tool call stops the job in the app too.
- `esclop restore` on a file with no recent result points at `esclop recent` and exits 1. A file
  command whose every file was an invalid request exits 64. `esclop convert --help` no longer
  offers `jxl`, and `esclop settings reset` prints the new value. Audio and video say "Removed
  metadata" when they did, and a lossless pass "Optimised without loss". A video crop no longer
  prints a resize that does nothing.
- The detail stays open while its file changes in place, a file at work keeps its place among
  the floating results, and a result never lands out of sight.
- Recent › Clear reports a failure when the log cannot be read, instead of clearing the list
  while names stay on disk.
- An automatic upload's link, or a pipeline upload step's, no longer replaces something copied
  after the file started: the card says "Link ready" and Copy Link puts it on the clipboard. A
  batch copies all its links at once. The test upload no longer leaves its file in the bucket.
- Download errors are in Catalan when the app is. Optimise Clipboard on L'Esclop's own link says
  there is nothing to optimise.
- The drop zone accepts a drag with ⌘ or ⌘⌥ held. Long preset zone names keep their start and
  end, with the full name in a tooltip.
- In the menu bar panel, the arrow keys reach the commands when Recent is empty, and Resume and
  the last batch. The panel's saving counts the recent results as soon as it opens.
- A link or search result to a setting low in Settings › General scrolls to it and marks it.
  Turning off Open at login says so when macOS refuses.
- The welcome window no longer reopens at every launch, and its permissions refresh after a visit
  to System Settings. "Kept for 0 days" reads "always kept".
- Turning "Strip metadata" off in a file's options now keeps its metadata while the setting is
  on. A request's `stripMetadata` is now optional: `true` strips, `false` keeps, and leaving it
  out follows the setting. For MCP, `stripMetadata: false` used to be ignored and now keeps
  metadata.

### Removed
- The dimmed glyph while paused: the menu bar panel says "Paused · Resume" instead.
- The `hoverButtons` setting and "Customise buttons…": the card's buttons now follow where the
  file came from. Convert, downscale and crop are in "…".

## [0.1.1] - 2026-11-12

Preset zones beside the drop zone, uploads to your own S3-compatible storage, and a PDF engine
of L'Esclop's own in place of Ghostscript. 0.1.0 installs this update by itself.

### Added
- Preset zones: while files are dragged, up to four targets beside the drop zone, in a 2 × 2
  grid facing the screen, each running a pipeline on what is dropped on it, through the usual
  floating results or the batch window. A saved pipeline is one when its triggers include "A
  preset zone while dragging"; the built-in templates are turned on in Settings › Floating
  results › Preset zones, which also orders them all. A drag shows the first four that do
  something for every kind of file in it. `esclop://dropzone` shows the drop zone without a drag
  for a minute (`?kind=image|video|pdf|audio` for that kind's zones, `?hide` to hide it). The
  drop zone's text and icons now use the popover's explicit inks.
- Uploads: after optimising, upload the result to your own S3-compatible storage (AWS S3,
  Cloudflare R2, Backblaze B2, MinIO) and get its link on the clipboard. From a result's Share
  tab ("Upload to …"), from a pipeline step (`upload(to: "R2")`), automatically for the sources
  you choose (copied files, the drop zone, watched folders, Finder's Quick Actions), with
  `esclop upload` and with the MCP tool `esclop_upload`. Targets are set up in Settings ›
  Uploads (endpoint, bucket, region, path template, public link template, Test Upload); their
  keys are kept in the Keychain only, never in the settings, logs, `esclop settings` or MCP
  output, and only the app reads them: the command line and agents upload through it. An upload
  takes its turn with the other jobs, shows its progress on the result, can be stopped, and on
  failure keeps the file, says why and offers Upload Again. Agents may upload only when "Agents
  may upload files" (`allowUploads`, off by default) is on.
- Agents' uploads and pipelines' upload steps take only images, videos, PDFs and audio whose
  first bytes (at most 4 KB are read) show the kind their extension names: a key or a text file
  renamed to `.png`, `.mp4`, `.pdf` or `.mp3` is refused, while a PNG named `.jpg` goes through.
  Uploads the person starts are not checked.

### Changed
- PDFs are optimised by esclop-engine's `pdf.optimise` instead of Ghostscript: streams
  recompressed, images re-encoded and downsampled only where a fidelity check (SSIM at 150 dpi)
  passes, embedded TrueType and CFF fonts subset with their glyph ids kept (fonts a form field
  types with stay whole), large inline images moved to shared objects, unused objects dropped.
  Text, links, outlines, form fields and permissions stay as they were; JPEGs are re-encoded
  only when downsampled, and "Strip metadata" touches no image. Encrypted PDFs are re-encrypted
  with the same keys and permissions or left alone (and always left alone over 64 MB); signed
  and Reader-extended PDFs, damaged files and ones that would need more than 256 MB of memory
  besides their own size are left as they are, and the result says why. A PDF still being
  optimised 30 minutes after it started (time spent waiting behind others does not count) is
  stopped. On 1,576 real PDFs (the pdf.js test files and
  GovDocs) the engine failed none of the checks, where Ghostscript failed 506 at the default
  setting; on the files Ghostscript handled cleanly, the engine's output is 0.98x
  Ghostscript's at the default setting and 1.01x at the aggressive one. Its memory stays under
  512 MB per file. See `engine/bench/pdf/RESULTS.md`.

### Removed
- Ghostscript is no longer bundled (32 MB): the bundled tools go from 96 MB to 76 MB
  (universal). Scripts in pipelines that called `$ESCLOP_BIN/gs` need a Ghostscript of their own.

## [0.1.0] - 2026-11-10

The first public beta: the menu bar app, the `esclop` command line and the MCP server for AI
agents, in one download for Apple Silicon and Intel (macOS 14 or later). The app is signed ad
hoc and not notarised yet.

### Added
- Compare window: judge an optimisation before keeping it. Opens from a floating result's
  detail, the options popover, a batch row, the menu's Compare submenu and
  `esclop://compare/<result id>`; one window, reused. Before and after split by a draggable
  divider, side by side, or flipped in place (Space); zoom to 100 % and up to 800 % with
  pan kept in step on both sides; the pixel difference marked in red with the share of pixels
  that differ. Videos play, scrub and step a frame at a time together; audio plays one side at
  a time from the same moment; PDFs go page by page on both sides. From the window: keep,
  restore the original, try another compression or format (the window follows the new
  result), copy and show in Finder. It works from the backup, so it opens long after the
  floating result is gone, and says so plainly when the backup has been pruned.
- Finder Quick Actions: right-click images, videos, PDFs or audio files in Finder and choose
  "Optimise with L’Esclop", "Optimise Harder with L’Esclop", "Convert to WebP with L’Esclop"
  (images) or "Run a Pipeline with L’Esclop…", which offers the pipelines whose triggers
  include Finder's right-click menu. Nothing opens: the files go through the usual floating
  results, or the batch window from `batchWindowFrom` files. Made with macOS Services, as Clop
  does; the titles are in English and Catalan.
- Shortcuts actions (App Intents): Optimise Files (optionally harder), Convert Files (to any
  format the engines write), Downscale Files (a factor between 1 % and 100 %), Crop Files
  (width and height, or one of them with the aspect kept), Run a Pipeline (the saved
  pipelines), Get a Setting and Change a Setting (every setting in the registry, checked as
  `esclop settings set` checks it) and Pause or Resume. File actions return the new files and
  run as the app's usual jobs, with floating results. Titles and summaries in English and
  Catalan. The actions' metadata is generated without an Xcode project by
  `Scripts/appintents-metadata.sh`, which `bundle-app.sh` runs.
- Automatic updates with Sparkle 2: the app checks once a day (and at once from "Check for
  Updates…" in the menu), shows what is new from the changelog and installs the new version.
  Settings › General › Updates has "Check for updates automatically" (on) and "Download and
  install updates automatically" (off), also in `esclop settings`. Updates are DMGs signed with
  an EdDSA key, from an appcast the release workflow signs and publishes when a release is
  published, at an address that never changes; no Apple Developer account is needed, and the
  updated app opens without macOS asking again. `Scripts/update-e2e.sh` proves on CI that an
  installed app updates itself.
- Catalan: the whole app speaks Catalan when macOS does (or with `ESCLOP_LANGUAGE=ca`): the
  menu, the floating results and their options, the batch window, the Settings window with
  every setting and its search, the Agents and MCP pane, the first-run tour, the pipeline
  editor and the parser's messages in it. The command line and the MCP server stay in English.
- Pipeline editor: a window (menu → Pipelines…, Settings → Advanced, a result's Share tab,
  `esclop://pipelines` and `esclop://pipelines/<name>`) to create, edit, duplicate, delete and
  run pipelines without a text file. Saved pipelines and the built-in templates (read-only,
  with Duplicate) are listed on the left. On the right: the steps for each kind of file, with a
  control for each argument and the parser's message on the step it belongs to; a filter
  ("Only some files") checked live against a file you choose; what runs the pipeline on its own
  (clipboard, drop zone, preset zone, Finder, command line, agents, watched folders); a text
  view of the same pipeline, kept in step with the form, that marks the lines with errors; and
  Try it, which runs the pipeline on a copy of a file and shows each step and the saving. What
  it saves is what `PipelineSerializer` writes. Script steps are shown as code, with a note
  that agents only run such a pipeline when "Agents may run scripts" is on.
- Watched folders: new images, videos, PDFs and audio files in the folders listed in Settings
  (the Desktop for screenshots and recordings by default) are optimised as they appear, with a
  floating result, or in the batch window when enough arrive. As in Clop, hidden, temporary and
  partial downloads are left alone, and so are files already optimised, files L'Esclop itself
  wrote in the last three seconds, and files outside the size limits. A file still being written
  waits until it stops changing. When more files of one kind than its count (`maxImageFileCount`
  4, `maxVideoFileCount` 1, `maxPDFFileCount` 2, `maxAudioFileCount` 2) appear at once, none of
  them is touched and a notice says so. A pipeline with a `folder(...)` trigger runs instead of
  the plain optimisation for the kinds it has steps for, also in folders no list names. Pause
  stops the watching; the menu says how many folders are being watched.
- Settings: each folder list has its own editor in its kind's pane: Add Folder… with the folder
  picker, Show in Finder and Stop Watching per folder, a line under a folder that no longer
  exists or that macOS does not let L'Esclop read (with a button to the privacy settings), and
  the folder macOS saves screenshots to offered when it is not in the list.
- Batch window: a job with four files or more (`batchWindowFrom`) lists them in one window
  instead of a floating result each, from the drop zone, "Optimise Files…" in the menu (files
  or folders), several copied files, and the CLI or MCP. The header shows the aggregate saving
  with the deflate bar and the counts; rows show each file's progress, sizes, bar and saving.
  Pause, Stop, Restore All and Show in Finder act on the batch; restore, try again, stop, copy
  and Show in Finder on a row.
- Settings window: a sidebar of panes (General, Images, Video, PDF, Audio, Clipboard, Floating
  results, Agents and MCP, Advanced) built from the settings registry, search across every
  setting and hotkey, `esclop://settings/<key>` links that open the pane and mark the row,
  values checked as they are typed, a reset arrow per changed setting and Reset All. It reads
  and writes the same settings as `esclop settings` and follows changes made from the command
  line while it is open. Replaces the minimal settings window. Agent refusals now carry the
  link to the switch that would allow the request, for example
  `esclop://settings/agents/allowRunScripts`, and name it as the Settings window does.
- `esclop settings reset <key>` puts one setting back to its default.
- Settings → Agents and MCP: lists the agents on this Mac (the ones `esclop mcp install`
  supports) with whether each runs L'Esclop, connects, updates and disconnects them in one
  click after showing the exact change to their config file as a diff, keeps a backup, refuses
  to write a file that changed after the preview or any file but the agent's own config, tests
  the server live (initialize, tools/list, `esclop_status`) and offers JSON, TOML and
  `claude mcp add` snippets.
- First-run tour: welcome, what is optimised on its own (the same switches as Settings), what
  macOS will ask and why (clipboard access with its current status, files in Desktop,
  Documents and Downloads, open at login), connecting an agent, and where the app lives. Every
  step can be skipped; the menu's "Welcome to L'Esclop…" opens it again.
- Floating result redesigned for Liquid Glass (DESIGN.md): a ~200 pt thumbnail with a capsule
  that counts down to "612 kB · −75 %", round hover buttons (Undo, Convert, Downscale, Crop,
  "…"), a 320 pt detail with a before/after divider opened by the capsule or a still pointer,
  an activity capsule with the time left for jobs over two seconds, errors in the capsule with
  retry, the newest three stacked, two-finger swipe to dismiss. VoiceOver announces each result.
- Options popover from the "…" hover button (DESIGN.md): Optimise (a suggestion from where the
  file came from, compression, format tiles with size estimates, quality, metadata, HDR, encoder,
  video, PDF and audio controls), Size (downscale in 10 % steps, fit under a size, crop presets
  and a crop editor with a free or locked rectangle and the size in pixels) and Share (Copy,
  AirDrop, Save as, Finder, Quick Look, Share, Open with, Shortcuts, pipelines, shelf and upload
  apps when installed). Audio gets Sound in place of Size. Choices run again on the same card.
- Clipboard rules: "Always apply to PNG screenshots" stores the current choice for that origin
  and format; the next copy of that kind uses it and the capsule shows a pin. Rules live in the
  `clipboardRules` setting and are listed, with a delete button, in Settings › Clipboard.
- `hoverButtons` setting, switches in Settings › Floating results and "Customise buttons…" in
  the popover, for the round buttons above a result.
- `CropSize.rect`: a free crop region for images and videos, in the engine and the contracts.
- Catalan localisation of the floating result, the popover and the rules (String Catalog).
- App icon and menu bar glyph: the carved wooden clog on the green squircle, and a rounded
  template clog for the menu bar that dims while paused. `make icons` regenerates them.
- Menu-bar app: optimises copied images (and copied videos, PDFs and audio when enabled), shows
  a floating card per file whose bar deflates to the new size, offers Restore, Show in Finder
  and Copy, and a drop zone while files are dragged (Command optimises harder). Hotkeys
  ⌃⇧P (pause cycle), ⌃⇧C (optimise clipboard) and ⌃⇧A (harder); a backups menu to restore
  originals. When it runs, the CLI and MCP server send their jobs
  to it and they show cards too.
- Settings for floating results and the drop zone: `floatingResultsCorner`,
  `followCursorScreen`, `autoHideFloatingResults`, `autoHideFloatingResultsAfter`,
  `autoHideClipboardResultAfter`, `enableDragAndDrop` (section `interface`).
- `esclop` command line: `optimise`, `convert`, `downscale`, `crop`, `fit`, `strip`,
  `pdf crop|uncrop|pages`, `pipeline list|show|run|write|delete`, `settings get|set|reset|schema`,
  `status`, `logs`. It runs without the app.
- MCP server (`esclop mcp serve`) with the `esclop_*` tools, resources and prompts, and
  installers that add it to Claude Code, Claude Desktop, Codex, Cursor, Windsurf, Zed, Gemini
  CLI, Copilot CLI, OpenCode, pi and Warp. Agents cannot overwrite originals unless permission is enabled.
- Message-port IPC library for the command line, MCP server and planned app integration,
  with timeouts and concurrency guards.
- Pipelines: a model, a text language compatible with Clop's so existing pipelines carry over,
  a runner, a store of `.pipeline` files and built-in presets.
- `esclop-engine`, the Rust image engine: PNG (imagequant, oxipng), JPEG (mozjpeg), WebP, AVIF
  (libaom through libavif, with optional rav1e), GIF (gifski and its own optimiser), resize,
  crop, metadata and fit-under-size behind a JSON-lines protocol. The
  [synthetic benchmarks](engine/bench/README.md) compare reference tools using Clop 3.5's
  flags. All listed operations stay under 300 MB on the 24-megapixel JPEG fixture; AVIF
  and aggressive PNG have small quality shortfalls against the reference.
- Video, audio and PDF engines on ffmpeg (LGPL build with VideoToolbox), Ghostscript and
  gifsicle, which `Scripts/build-tools.sh` builds from pinned, checksummed upstream source.
- Settings registry shared by the app, the command line and the MCP server; tool locator;
  process runner; backups of originals with pruning.
- Licence policy: `cargo deny` allowlist for the engine, generated notices for the engine's
  crates (`engine/THIRD_PARTY-engine.md`) and the bundled tools (`THIRD_PARTY.md`).
- Release engineering: continuous integration, a licence gate over every bundled Mach-O file,
  release packaging with the complete corresponding source, and this changelog.

### Changed
- The four "Watch folders for …" switches and the folder lists moved from Automation to the
  Images, Video, PDF and Audio panes.
- Watched folders no longer read inside a folder when they start: macOS asks for access to a
  protected folder such as the Desktop when the first new file lands there, as with Clop, and
  the first-run tour says so. If access is refused, the folder leaves the watch without a
  notice or another attempt until the folder lists change or the app restarts, and its
  Settings row says why.

### Fixed
- Release builds no longer carry the path of the machine that built them: looking for tools
  beside the source file is for debug builds only. The release workflow checks the app's
  binaries for such paths, as it did the command line's, and now builds the DMG.
- Floating results and the options popover, from a live UI check:
  - the popover header shows the result's size after a crop or a downscale;
  - a result's row of buttons no longer covers the result above, and results no longer touch;
  - a damaged or unreadable file says so plainly ("This file isn't a video L'Esclop can read.
    It may be damaged.") in the card, the batch window, the CLI and MCP (`unreadable`, exit
    code 65); the tool's own output goes to the log;
  - "Optimise Clipboard" on a result L'Esclop just wrote shows that result again instead of
    making a second one, and the app recognises its own clipboard writes by their bytes too;
  - a result with no saving reads "Already optimised", never "−0 %";
  - copied images are "Copied image" in the popover, and an unknown origin is named;
  - default buttons use the app's accent; the Share row's labels line up;
  - closing a detail gives the result its whole hide delay again.
- Settings: descriptions written for people (the values the CLI takes stay in the schema's
  `x-details`), left-aligned footers in Agents and MCP, a "Not found on this Mac" list that
  VoiceOver can open, a change preview that shows the whole change, and copied commands in
  double quotes when that is all they need.
- `esclop mcp status` and the install messages printed the command line unquoted when its path
  has an apostrophe (the app lives in `L'Esclop.app`), so the line could not be pasted into a
  shell.
