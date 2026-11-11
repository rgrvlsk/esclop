// SPDX-License-Identifier: GPL-3.0-or-later
//
// The settings esclop ships with. Keys follow the names the original Clop app uses where the
// meaning is the same, so a migration can copy values across. Compression levels are factors from
// 0 to 100 where higher means smaller files, the same scale as `CompressionQuality.factor`.

import Foundation

// MARK: - Enumerated values

/// Where a result goes when the person did not say. Maps onto `OutputLocation`.
public enum FileBehaviour: String, CaseIterable, Codable, Sendable, SettingValue {
    case inPlace, sameFolder, specificFolder, temporary
}

/// A speed change either keeps every frame (the frame rate rises with the speed) or drops frames
/// to keep the source frame rate.
public enum PlaybackSpeedFrames: String, CaseIterable, Codable, Sendable, SettingValue {
    case keepFrames, dropFrames
}

/// What happens to album artwork when an audio file is optimised.
public enum AudioCoverArt: String, CaseIterable, Codable, Sendable, SettingValue {
    case optimise, remove, keep
}

extension VideoEncoder: SettingValue {}

/// The screen corner where floating results stack.
public enum ScreenCorner: String, CaseIterable, Codable, Sendable, SettingValue {
    case bottomRight, bottomLeft, topRight, topLeft

    public var isTop: Bool { self == .topRight || self == .topLeft }
    public var isRight: Bool { self == .bottomRight || self == .topRight }
}

// MARK: - Catalog

public enum EsclopSettings {
    // MARK: General

    public static let stripMetadata = Setting<Bool>(
        "stripMetadata", default: true, title: "Strip metadata",
        description: "Remove EXIF, GPS, XMP and other metadata from optimised files. Orientation and colour profiles are kept so files still look the same.",
        section: .general
    )
    public static let preserveDates = Setting<Bool>(
        "preserveDates", default: true, title: "Keep file dates",
        description: "Give optimised files the creation and modification dates of the original.",
        section: .general
    )
    public static let keepHDR = Setting<Bool>(
        "keepHDR", default: true, title: "Keep HDR",
        description: "Keep HDR gain maps and HDR video when the output format can carry them. Off converts to SDR.",
        section: .general
    )

    // MARK: Updates

    public static let checkForUpdatesAutomatically = Setting<Bool>(
        "checkForUpdatesAutomatically", default: true, title: "Check for updates automatically",
        description: "Look for a newer version of L'Esclop once a day. Nothing about this Mac is sent.",
        section: .updates
    )
    public static let installUpdatesAutomatically = Setting<Bool>(
        "installUpdatesAutomatically", default: false, title: "Download and install updates automatically",
        description: "Download a new version in the background and install it when L'Esclop quits. Off asks first.",
        section: .updates
    )

    // MARK: Interface

    public static let floatingResultsCorner = Setting<ScreenCorner>(
        "floatingResultsCorner", default: .bottomRight, title: "Results corner",
        description: "The screen corner where result cards and the drop zone appear.", section: .interface
    )
    public static let followCursorScreen = Setting<Bool>(
        "followCursorScreen", default: true, title: "Show results on the screen with the pointer",
        description: "Off shows them on the main screen.", section: .interface
    )
    public static let autoHideFloatingResults = Setting<Bool>(
        "autoHideFloatingResults", default: true, title: "Hide results automatically",
        description: "Dismiss result cards after a while unless the pointer is over them.", section: .interface
    )
    public static let autoHideFloatingResultsAfter = Setting<Int>(
        "autoHideFloatingResultsAfter", default: 30, title: "Hide results after",
        description: "Seconds a result card stays on screen.", section: .interface, minimum: 1, maximum: 3600
    )
    public static let autoHideClipboardResultAfter = Setting<Int>(
        "autoHideClipboardResultAfter", default: 10, title: "Hide clipboard results after",
        description: "Seconds the card for a copied image stays on screen.", section: .interface, minimum: 1, maximum: 3600
    )
    public static let batchWindowFrom = Setting<Int>(
        "batchWindowFrom", default: 4, title: "Batch window from",
        description: "Optimising this many files or more at once lists them in the batch window, with their progress and the total saving, instead of a floating result each.",
        section: .interface, minimum: 2, maximum: 1000
    )
    public static let hoverButtons = Setting<[String]>(
        "hoverButtons", default: ["undo", "convert", "downscale", "crop"], title: "Hover buttons",
        description: "The round buttons above a floating result, in order: undo, convert, downscale, crop. \"…\" is always last.",
        section: .interface
    )
    public static let presetZones = Setting<[String]>(
        "presetZones", default: [], title: "Preset zones",
        description: "The targets beside the drop zone that run a pipeline on what you drop, in order. Saved pipelines whose triggers include a preset zone are always shown; the built-in templates named here are added.",
        section: .interface
    )
    public static let enableDragAndDrop = Setting<Bool>(
        "enableDragAndDrop", default: true, title: "Show the drop zone",
        description: "Show a drop zone while dragging files, to optimise whatever is dropped on it.", section: .interface
    )

    // MARK: Images

    public static let imageCompression = Setting<Int>(
        "imageCompression", default: 30, title: "Image compression",
        description: "How hard normal image optimisation compresses, 0 to 100. 30 is visually lossless; higher values make smaller files with visible loss.",
        section: .images, minimum: 0, maximum: 100
    )
    public static let imageAggressiveCompression = Setting<Int>(
        "imageAggressiveCompression", default: 64, title: "Aggressive image compression",
        description: "Compression used for images when optimising aggressively, 0 to 100.",
        section: .images, minimum: 0, maximum: 100
    )
    public static let useAggressiveOptimisationJPEG = Setting<Bool>(
        "useAggressiveOptimisationJPEG", default: false, title: "Always optimise JPEG aggressively",
        description: "Use the aggressive compression for every JPEG.", section: .images
    )
    public static let useAggressiveOptimisationPNG = Setting<Bool>(
        "useAggressiveOptimisationPNG", default: false, title: "Always optimise PNG aggressively",
        description: "Use the aggressive compression for every PNG.", section: .images
    )
    public static let useAggressiveOptimisationGIF = Setting<Bool>(
        "useAggressiveOptimisationGIF", default: false, title: "Always optimise GIF aggressively",
        description: "Use the aggressive compression for every GIF.", section: .images
    )
    public static let adaptiveImageSize = Setting<Bool>(
        "adaptiveImageSize", default: false, title: "Adaptive image format",
        description: "Also try PNG as JPEG (and JPEG as PNG) and keep whichever is smaller by a clear margin.",
        section: .images
    )
    public static let formatsToConvertToJPEG = Setting<[String]>(
        "formatsToConvertToJPEG", default: ["webp", "avif", "heic", "bmp"], title: "Convert to JPEG",
        description: "Image formats (file extensions) converted to JPEG when optimised automatically.",
        section: .images
    )
    public static let formatsToConvertToPNG = Setting<[String]>(
        "formatsToConvertToPNG", default: ["tiff"], title: "Convert to PNG",
        description: "Image formats (file extensions) converted to PNG when optimised automatically.",
        section: .images
    )
    public static let downscaleFactor = Setting<Double>(
        "downscaleFactor", default: 0.5, title: "Default downscale factor",
        description: "How much Downscale shrinks a picture when no size is given: 50 % halves the width and the height.",
        section: .images, minimum: 0.1, maximum: 1,
        schema: ["x-details": "A factor from 0.1 to 1 of the width and height."]
    )
    public static let downscaleRetinaImages = Setting<Bool>(
        "downscaleRetinaImages", default: false, title: "Downscale Retina screenshots",
        description: "Halve the size of 2x screenshots when they are optimised automatically.",
        section: .images
    )
    public static let maxImageSizeMB = Setting<Int>(
        "maxImageSizeMB", default: 50, title: "Largest image to optimise automatically",
        description: "Images above this size in MB are skipped by automatic optimisation.",
        section: .images, minimum: 1, maximum: 10000
    )
    public static let minImageSizeKB = Setting<Int>(
        "minImageSizeKB", default: 50, title: "Smallest image to optimise automatically",
        description: "Images below this size in KB are skipped by automatic optimisation.",
        section: .images, minimum: 0, maximum: 100_000
    )

    // MARK: Video

    public static let videoCompression = Setting<Int>(
        "videoCompression", default: 50, title: "Video compression",
        description: "How hard normal video optimisation compresses, 0 to 100.",
        section: .video, minimum: 0, maximum: 100
    )
    public static let videoAggressiveCompression = Setting<Int>(
        "videoAggressiveCompression", default: 70, title: "Aggressive video compression",
        description: "Compression used for videos when optimising aggressively, 0 to 100.",
        section: .video, minimum: 0, maximum: 100
    )
    public static let videoEncoder = Setting<VideoEncoder>(
        "videoEncoder", default: defaultVideoEncoder, title: "Video encoder",
        description: "Encoder for MP4 and MOV output. The VideoToolbox encoders use the Apple Silicon media engine and fall back to software when it is unavailable.",
        section: .video
    )
    public static let useAggressiveOptimisationMP4 = Setting<Bool>(
        "useAggressiveOptimisationMP4", default: false, title: "Always optimise video aggressively",
        description: "Use the aggressive compression for every video.",
        section: .video
    )
    public static let formatsToConvertToMP4 = Setting<[String]>(
        "formatsToConvertToMP4", default: ["mov", "mpeg", "mpg", "webm", "avi"], title: "Convert to MP4",
        description: "Video formats (file extensions) converted to MP4 when optimised automatically.",
        section: .video
    )
    public static let capVideoFPS = Setting<Bool>(
        "capVideoFPS", default: true, title: "Cap frame rate",
        description: "Drop frames above the target frame rate.", section: .video
    )
    public static let targetVideoFPS = Setting<Double>(
        "targetVideoFPS", default: 60, title: "Target frame rate",
        description: "The highest frame rate optimised videos keep. Half or a quarter of the source follows each video's own rate, never below the minimum.",
        section: .video, minimum: -4, maximum: 240,
        schema: ["x-details": "-2 halves the source frame rate and -4 quarters it."]
    )
    public static let minVideoFPS = Setting<Double>(
        "minVideoFPS", default: 30, title: "Minimum frame rate",
        description: "The lowest frame rate kept when the target is half or a quarter of the source.",
        section: .video, minimum: 1, maximum: 240,
        schema: ["x-details": "Applies when targetVideoFPS is -2 or -4."]
    )
    public static let removeAudioFromVideos = Setting<Bool>(
        "removeAudioFromVideos", default: false, title: "Remove audio from videos",
        description: "Drop every audio track when optimising videos.", section: .video
    )
    public static let convertAudioToAAC = Setting<Bool>(
        "convertAudioToAAC", default: false, title: "Re-encode soundtracks to AAC",
        description: "Re-encode video soundtracks to AAC instead of copying them.", section: .video
    )
    public static let playbackSpeedFrames = Setting<PlaybackSpeedFrames>(
        "playbackSpeedFrameBehaviour", default: .keepFrames, title: "Speed change frames",
        description: "When a video plays faster: keep every frame for smooth motion, or keep the frame rate for a smaller file.",
        section: .video,
        schema: ["x-details": "keepFrames raises the frame rate with the speed; dropFrames keeps the source frame rate."]
    )
    public static let maxVideoSizeMB = Setting<Int>(
        "maxVideoSizeMB", default: 500, title: "Largest video to optimise automatically",
        description: "Videos above this size in MB are skipped by automatic optimisation.",
        section: .video, minimum: 1, maximum: 100_000
    )
    public static let minVideoSizeKB = Setting<Int>(
        "minVideoSizeKB", default: 200, title: "Smallest video to optimise automatically",
        description: "Videos below this size in KB are skipped by automatic optimisation.",
        section: .video, minimum: 0, maximum: 1_000_000
    )
    public static let gifMaxWidth = Setting<Int>(
        "gifMaxWidth", default: 720, title: "GIF width",
        description: "Largest width in pixels of GIFs made from videos.",
        section: .video, minimum: 16, maximum: 4096
    )
    public static let gifFPS = Setting<Int>(
        "gifFPS", default: 15, title: "GIF frame rate",
        description: "Frame rate of GIFs made from videos.", section: .video, minimum: 1, maximum: 50
    )

    // MARK: PDF

    public static let pdfDPI = Setting<Int>(
        "pdfDPI", default: 0, title: "PDF image resolution",
        description: "Resolution images in PDFs are downsampled to. 0 picks one per document from the images it contains; 300 keeps full resolution.",
        section: .pdf, minimum: 0, maximum: 300,
        schema: ["enum": [0, 300, 250, 200, 150, 100, 72, 48]]
    )
    public static let useAggressiveOptimisationPDF = Setting<Bool>(
        "useAggressiveOptimisationPDF", default: false, title: "Always optimise PDF aggressively",
        description: "Go one resolution step lower for every PDF.", section: .pdf
    )
    public static let maxPDFSizeMB = Setting<Int>(
        "maxPDFSizeMB", default: 100, title: "Largest PDF to optimise automatically",
        description: "PDFs above this size in MB are skipped by automatic optimisation.",
        section: .pdf, minimum: 1, maximum: 100_000
    )

    // MARK: Audio

    public static let audioCompression = Setting<Int>(
        "audioCompression", default: 35, title: "Audio compression",
        description: "How hard audio optimisation compresses, 0 to 100. Maps to a bitrate per codec.",
        section: .audio, minimum: 0, maximum: 100
    )
    public static let audioAggressiveCompression = Setting<Int>(
        "audioAggressiveCompression", default: 65, title: "Aggressive audio compression",
        description: "Compression used for audio when optimising aggressively, 0 to 100.",
        section: .audio, minimum: 0, maximum: 100
    )
    public static let formatsToConvertToAAC = Setting<[String]>(
        "formatsToConvertToAAC", default: ["aiff", "aif", "flac"], title: "Convert to AAC",
        description: "Audio formats (file extensions) converted to AAC (M4A) when optimised.",
        section: .audio
    )
    public static let formatsToConvertToMP3 = Setting<[String]>(
        "formatsToConvertToMP3", default: ["wav"], title: "Convert to MP3",
        description: "Audio formats (file extensions) converted to MP3 when optimised.",
        section: .audio
    )
    public static let audioCoverArt = Setting<AudioCoverArt>(
        "audioCoverArt", default: .optimise, title: "Cover art",
        description: "Album artwork in audio files: make it smaller, remove it, or keep it as it is.",
        section: .audio,
        schema: ["x-details": "optimise downscales and recompresses album artwork, remove drops it, keep copies it untouched."]
    )
    public static let normalizeLoudness = Setting<Bool>(
        "normalizeLoudness", default: false, title: "Normalise loudness",
        description: "Normalise audio to the loudness target when optimising.", section: .audio
    )
    public static let loudnessTarget = Setting<Double>(
        "loudnessTarget", default: -16, title: "Loudness target",
        description: "Integrated loudness in LUFS used by loudness normalisation.",
        section: .audio, minimum: -70, maximum: -5
    )
    public static let maxAudioSizeMB = Setting<Int>(
        "maxAudioSizeMB", default: 100, title: "Largest audio file to optimise automatically",
        description: "Audio files above this size in MB are skipped by automatic optimisation.",
        section: .audio, minimum: 1, maximum: 100_000
    )

    // MARK: Output

    public static let optimisedImageBehaviour = Setting<FileBehaviour>(
        "optimisedImageBehaviour", default: .inPlace, title: "Optimised images go",
        description: "Where optimised images are written.", section: .output
    )
    public static let optimisedVideoBehaviour = Setting<FileBehaviour>(
        "optimisedVideoBehaviour", default: .inPlace, title: "Optimised videos go",
        description: "Where optimised videos are written.", section: .output
    )
    public static let optimisedPDFBehaviour = Setting<FileBehaviour>(
        "optimisedPDFBehaviour", default: .inPlace, title: "Optimised PDFs go",
        description: "Where optimised PDFs are written.", section: .output
    )
    public static let optimisedAudioBehaviour = Setting<FileBehaviour>(
        "optimisedAudioBehaviour", default: .inPlace, title: "Optimised audio goes",
        description: "Where optimised audio files are written.", section: .output
    )
    public static let convertedImageBehaviour = Setting<FileBehaviour>(
        "convertedImageBehaviour", default: .sameFolder, title: "Converted images go",
        description: "Where images converted to another format are written.", section: .output
    )
    public static let convertedVideoBehaviour = Setting<FileBehaviour>(
        "convertedVideoBehaviour", default: .inPlace, title: "Converted videos go",
        description: "Where videos converted to another format are written.", section: .output
    )
    public static let convertedAudioBehaviour = Setting<FileBehaviour>(
        "convertedAudioBehaviour", default: .inPlace, title: "Converted audio goes",
        description: "Where audio files converted to another format are written.", section: .output
    )
    public static let sameFolderNameTemplate = Setting<String>(
        "sameFolderNameTemplate", default: "%f-optimised", title: "Same folder name",
        description: "File name for results written next to the original. %f is the original name without extension.",
        section: .output
    )
    public static let specificFolderTemplate = Setting<String>(
        "specificFolderTemplate", default: "%d/optimised/%f", title: "Specific folder path",
        description: "Path template for results written to a specific folder. %f is the name, %e the extension, %d the original's folder, ~ the home folder.",
        section: .output
    )

    // MARK: Backups

    public static let backupRetentionDays = Setting<Int>(
        "backupRetentionDays", default: 7, title: "Keep backups for",
        description: "Days to keep originals in the backup folder before they are pruned. 0 keeps them for ever.",
        section: .backups, minimum: 0, maximum: 3650
    )

    // MARK: Clipboard

    public static let enableClipboardOptimiser = Setting<Bool>(
        "enableClipboardOptimiser", default: true, title: "Optimise copied images",
        description: "Optimise images as soon as they are copied.", section: .clipboard
    )
    public static let optimiseVideoClipboard = Setting<Bool>(
        "optimiseVideoClipboard", default: false, title: "Optimise copied videos",
        description: "Optimise video files when they are copied.", section: .clipboard
    )
    public static let optimisePDFClipboard = Setting<Bool>(
        "optimisePDFClipboard", default: false, title: "Optimise copied PDFs",
        description: "Optimise PDF files when they are copied.", section: .clipboard
    )
    public static let optimiseAudioClipboard = Setting<Bool>(
        "optimiseAudioClipboard", default: false, title: "Optimise copied audio",
        description: "Optimise audio files when they are copied.", section: .clipboard
    )
    public static let optimiseImagePathClipboard = Setting<Bool>(
        "optimiseImagePathClipboard", default: false, title: "Optimise copied image paths",
        description: "When a copied text is the path of an image file, optimise that file.", section: .clipboard
    )
    public static let clipboardIgnoredAppBundleIds = Setting<[String]>(
        "clipboardIgnoredAppBundleIds", default: [], title: "Ignored apps",
        description: "Bundle identifiers of apps whose copies are never optimised.", section: .clipboard
    )
    public static let clipboardRules = Setting<[String]>(
        "clipboardRules", default: [], title: "Clipboard rules",
        description: "Choices saved with \"Always apply\" in a file's options. Each one applies to the next copies of one kind, such as PNG screenshots.",
        section: .clipboard,
        schema: ["x-details": "One JSON object per rule: origin, inputType (a UTType identifier) and choice."]
    )
    public static let autoCopyToClipboard = Setting<Bool>(
        "autoCopyToClipboard", default: true, title: "Copy results to the clipboard",
        description: "Put the optimised file back on the clipboard after optimising a copied one.",
        section: .clipboard
    )

    // MARK: Automation

    public static let pauseAutomaticOptimisations = Setting<Bool>(
        "pauseAutomaticOptimisations", default: false, title: "Pause automatic optimisation",
        description: "Stop watching the clipboard and folders until resumed.", section: .automation
    )
    public static let enableAutomaticImageOptimisations = Setting<Bool>(
        "enableAutomaticImageOptimisations", default: true, title: "Watch folders for images",
        description: "Optimise new images in the image folders.", section: .images
    )
    public static let enableAutomaticVideoOptimisations = Setting<Bool>(
        "enableAutomaticVideoOptimisations", default: true, title: "Watch folders for videos",
        description: "Optimise new videos in the video folders.", section: .video
    )
    public static let enableAutomaticPDFOptimisations = Setting<Bool>(
        "enableAutomaticPDFOptimisations", default: true, title: "Watch folders for PDFs",
        description: "Optimise new PDFs in the PDF folders.", section: .pdf
    )
    public static let enableAutomaticAudioOptimisations = Setting<Bool>(
        "enableAutomaticAudioOptimisations", default: false, title: "Watch folders for audio",
        description: "Optimise new audio files in the audio folders.", section: .audio
    )
    public static let imageDirs = Setting<[String]>(
        "imageDirs", default: ["~/Desktop"], title: "Screenshot folders",
        description: "New images in these folders are optimised as they appear. Screenshots land on the Desktop unless you moved them.", section: .images
    )
    public static let videoDirs = Setting<[String]>(
        "videoDirs", default: ["~/Desktop"], title: "Recording folders",
        description: "New videos in these folders are optimised as they appear, screen recordings included.", section: .video
    )
    public static let pdfDirs = Setting<[String]>(
        "pdfDirs", default: [], title: "PDF folders",
        description: "New PDFs in these folders are optimised as they appear.", section: .pdf
    )
    public static let audioDirs = Setting<[String]>(
        "audioDirs", default: [], title: "Audio folders",
        description: "New audio files in these folders are optimised as they appear.", section: .audio
    )

    /// How many new files of a kind may appear in the watched folders at once (within a second)
    /// before L'Esclop leaves them all alone and says so: Clop's limits.
    public static let maxImageFileCount = Setting<Int>(
        "maxImageFileCount", default: 4, title: "Most new images at once",
        description: "When more images than this appear in a watched folder together, as when a folder is copied or unzipped there, none of them is optimised.",
        section: .images, minimum: 1, maximum: 100
    )
    public static let maxVideoFileCount = Setting<Int>(
        "maxVideoFileCount", default: 1, title: "Most new videos at once",
        description: "When more videos than this appear in a watched folder together, none of them is optimised.",
        section: .video, minimum: 1, maximum: 100
    )
    public static let maxPDFFileCount = Setting<Int>(
        "maxPDFFileCount", default: 2, title: "Most new PDFs at once",
        description: "When more PDFs than this appear in a watched folder together, none of them is optimised.",
        section: .pdf, minimum: 1, maximum: 100
    )
    public static let maxAudioFileCount = Setting<Int>(
        "maxAudioFileCount", default: 2, title: "Most new audio files at once",
        description: "When more audio files than this appear in a watched folder together, none of them is optimised.",
        section: .audio, minimum: 1, maximum: 100
    )

    // MARK: Agents

    public static let allowOverwriteOriginals = Setting<Bool>(
        "allowOverwriteOriginals", default: false, title: "Agents may overwrite originals",
        description: "Let AI agents (MCP) write results over the original file. A backup is kept either way.",
        section: .agents
    )
    public static let allowDeleteBackups = Setting<Bool>(
        "allowDeleteBackups", default: false, title: "Agents may delete backups",
        description: "Let AI agents delete backups of originals.", section: .agents
    )
    public static let allowRunScripts = Setting<Bool>(
        "allowRunScripts", default: false, title: "Agents may run scripts",
        description: "Let AI agents run pipelines that contain script steps.", section: .agents
    )
    public static let allowSettingsChanges = Setting<Bool>(
        "allowSettingsChanges", default: false, title: "Agents may change settings",
        description: "Let AI agents change esclop's settings.", section: .agents
    )
    public static let allowUploads = Setting<Bool>(
        "allowUploads", default: false, title: "Agents may upload files",
        description: "Let AI agents upload images, videos, PDFs and audio to your upload targets, and get their links. Anyone with a link can open the file if the bucket is public.", section: .agents
    )

    // MARK: Uploads

    public static let uploadTargets = Setting<[String]>(
        "uploadTargets", default: [], title: "Upload targets",
        description: "Where files are uploaded: S3-compatible storage such as AWS S3, Cloudflare R2, Backblaze B2 or MinIO. The keys are kept in the Keychain, never here.",
        section: .uploads,
        schema: ["x-details": "One JSON object per target: name, endpoint, bucket, region, path (a path template such as %y/%m/%f), publicURL (a template where {path} is the uploaded path; empty uses the endpoint) and pathStyle. Keys are set in the app only."]
    )
    public static let uploadTarget = Setting<String>(
        "uploadTarget", default: "", title: "Upload to",
        description: "The target used when none is named. Empty uses the first one.", section: .uploads
    )
    public static let uploadAutomatically = Setting<[String]>(
        "uploadAutomatically", default: [], title: "Upload automatically",
        description: "Sources whose results are uploaded as soon as they are optimised, with the link put on the clipboard.",
        section: .uploads,
        schema: ["x-details": "Any of: clipboard, dropZone, watchedFolder, finder."]
    )

    // MARK: -

    /// VideoToolbox on every Mac: the bundled ffmpeg has no x264, and the engine falls back to
    /// VideoToolbox's software encoder where there is no hardware one.
    public static var defaultVideoEncoder: VideoEncoder { .h264VideoToolbox }

    public static let all: [AnySetting] = [
        stripMetadata.erased, preserveDates.erased, keepHDR.erased,
        floatingResultsCorner.erased, followCursorScreen.erased, autoHideFloatingResults.erased,
        autoHideFloatingResultsAfter.erased, autoHideClipboardResultAfter.erased, batchWindowFrom.erased, hoverButtons.erased, enableDragAndDrop.erased, presetZones.erased,
        imageCompression.erased, imageAggressiveCompression.erased,
        useAggressiveOptimisationJPEG.erased, useAggressiveOptimisationPNG.erased, useAggressiveOptimisationGIF.erased,
        adaptiveImageSize.erased, formatsToConvertToJPEG.erased, formatsToConvertToPNG.erased,
        downscaleFactor.erased, downscaleRetinaImages.erased, maxImageSizeMB.erased, minImageSizeKB.erased,
        videoCompression.erased, videoAggressiveCompression.erased, videoEncoder.erased,
        useAggressiveOptimisationMP4.erased, formatsToConvertToMP4.erased, capVideoFPS.erased, targetVideoFPS.erased,
        minVideoFPS.erased, removeAudioFromVideos.erased, convertAudioToAAC.erased, playbackSpeedFrames.erased,
        maxVideoSizeMB.erased, minVideoSizeKB.erased, gifMaxWidth.erased, gifFPS.erased,
        pdfDPI.erased, useAggressiveOptimisationPDF.erased, maxPDFSizeMB.erased,
        audioCompression.erased, audioAggressiveCompression.erased, formatsToConvertToAAC.erased,
        formatsToConvertToMP3.erased, audioCoverArt.erased, normalizeLoudness.erased, loudnessTarget.erased,
        maxAudioSizeMB.erased,
        optimisedImageBehaviour.erased, optimisedVideoBehaviour.erased, optimisedPDFBehaviour.erased,
        optimisedAudioBehaviour.erased, convertedImageBehaviour.erased, convertedVideoBehaviour.erased,
        convertedAudioBehaviour.erased, sameFolderNameTemplate.erased, specificFolderTemplate.erased,
        backupRetentionDays.erased,
        enableClipboardOptimiser.erased, optimiseVideoClipboard.erased, optimisePDFClipboard.erased,
        optimiseAudioClipboard.erased, optimiseImagePathClipboard.erased, clipboardIgnoredAppBundleIds.erased,
        clipboardRules.erased, autoCopyToClipboard.erased,
        pauseAutomaticOptimisations.erased, enableAutomaticImageOptimisations.erased,
        enableAutomaticVideoOptimisations.erased, enableAutomaticPDFOptimisations.erased,
        enableAutomaticAudioOptimisations.erased, imageDirs.erased, videoDirs.erased, pdfDirs.erased, audioDirs.erased,
        maxImageFileCount.erased, maxVideoFileCount.erased, maxPDFFileCount.erased, maxAudioFileCount.erased,
        allowOverwriteOriginals.erased, allowDeleteBackups.erased, allowRunScripts.erased, allowSettingsChanges.erased, allowUploads.erased,
        uploadTargets.erased, uploadTarget.erased, uploadAutomatically.erased,
        checkForUpdatesAutomatically.erased, installUpdatesAutomatically.erased,
    ]
}
