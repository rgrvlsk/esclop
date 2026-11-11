// SPDX-License-Identifier: GPL-3.0-or-later
//! Wire types. `engine/PROTOCOL.md` describes them in prose; `engine/schema/` is generated from
//! these definitions (`esclop-engine schema <dir>`), and a test keeps the two in step.

use crate::error::ErrorCode;
use schemars::JsonSchema;
use serde::{Deserialize, Deserializer, Serialize};
use std::path::PathBuf;

/// Bumped on any incompatible change to the wire format.
pub const PROTOCOL_VERSION: u32 = 1;

/// Every op the engine answers, in the order `hello` lists them.
pub const OPS: &[&str] = &[
    "hello",
    "probe",
    "png.optimise",
    "jpeg.optimise",
    "webp.encode",
    "avif.encode",
    "gif.optimise",
    "gif.from_frames",
    "resize",
    "crop",
    "metadata.strip",
    "convert",
    "fit",
    "pdf.optimise",
    "cancel",
];

// MARK: envelope

/// One request line.
#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
pub struct Request {
    /// Ties responses and progress events to the request. Strings are recommended; numbers are
    /// echoed back unchanged. For `cancel`, the id of the request to cancel.
    #[serde(default)]
    #[schemars(with = "Option<String>")]
    pub id: serde_json::Value,
    /// One of the ops listed by `hello`.
    pub op: String,
    /// Absolute path of the input file. Not used by `hello`, `cancel` and `gif.from_frames`.
    #[serde(default)]
    pub input: Option<PathBuf>,
    /// Absolute path of the output file. May equal `input` only with `params.in_place`;
    /// with `in_place` it may be omitted. Not used by `probe`.
    #[serde(default)]
    pub output: Option<PathBuf>,
    /// The op's params (see the per-op schemas). Unknown keys are reported back in
    /// `result.ignored_params`, never silently dropped.
    #[serde(default)]
    pub params: serde_json::Value,
}

/// One response line: exactly one per request (except `cancel`, which has none).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Response {
    #[schemars(with = "Option<String>")]
    pub id: serde_json::Value,
    pub ok: bool,
    /// Present when `ok` is true. `OpResult` for every op but `hello`, which returns `HelloResult`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    /// Present when `ok` is false.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorBody>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ErrorBody {
    pub code: ErrorCode,
    /// For people and agents; do not parse.
    pub message: String,
}

/// Progress line, zero or more per request before its response.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ProgressEvent {
    #[schemars(with = "Option<String>")]
    pub id: serde_json::Value,
    /// Always `"progress"`.
    pub event: String,
    /// 0..=1, non-decreasing for a request.
    pub fraction: f32,
    /// Short machine name of the current stage (`decode`, `quantise`, `encode`, `search`...).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stage: Option<String>,
}

// MARK: shared params

/// Image formats the engine recognises. Decodable: png, jpeg, gif, webp, tiff, bmp.
/// Encodable: png, jpeg, webp, avif, gif. heic, avif and jxl are recognised by `probe` only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    Png,
    #[serde(alias = "jpg")]
    Jpeg,
    Gif,
    Webp,
    Avif,
    Tiff,
    Bmp,
    Heic,
    Jxl,
    /// Only `pdf.optimise` reads and writes it.
    Pdf,
}

impl Format {
    pub fn name(self) -> &'static str {
        match self {
            Format::Png => "png",
            Format::Jpeg => "jpeg",
            Format::Gif => "gif",
            Format::Webp => "webp",
            Format::Avif => "avif",
            Format::Tiff => "tiff",
            Format::Bmp => "bmp",
            Format::Heic => "heic",
            Format::Jxl => "jxl",
            Format::Pdf => "pdf",
        }
    }
    pub fn encodable(self) -> bool {
        matches!(self, Format::Png | Format::Jpeg | Format::Webp | Format::Avif | Format::Gif)
    }
}

/// Metadata that `strip` keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Keep {
    /// The colour profile (ICC, and PNG sRGB/gAMA/cHRM/cICP). Dropping it changes how wide-gamut
    /// images look.
    Icc,
    /// The EXIF orientation tag, rewritten as a minimal EXIF block.
    Orientation,
}

/// Default for `keep`: what Clop keeps when it strips metadata.
pub const DEFAULT_KEEP: &[Keep] = &[Keep::Icc, Keep::Orientation];

/// Output handling shared by every op that writes a file.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct OutputParams {
    /// Allow `output` to equal `input` (or be omitted). The engine writes a temporary file in the
    /// same folder and renames it over the input, keeping its mode, creation date and extended
    /// attributes.
    pub in_place: bool,
    /// Remove metadata (EXIF, XMP, IPTC, comments, text chunks) except what `keep` lists.
    pub strip: bool,
    /// What `strip` keeps. Default `["icc", "orientation"]`; `[]` strips everything.
    pub keep: Option<Vec<Keep>>,
    /// Write the result even when it is not smaller than the input. Optimise ops default to false
    /// (and answer `already_smaller`); resize, crop, convert and encode ops default to true.
    pub allow_larger: Option<bool>,
}

impl OutputParams {
    pub fn keep_list(&self) -> &[Keep] {
        self.keep.as_deref().unwrap_or(DEFAULT_KEEP)
    }
}

/// Encoder knobs shared by `convert`, `resize`, `crop` and `fit`. Each applies to the formats
/// named in its description and is ignored by the others.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct EncodeParams {
    /// Compression factor 0..=100, higher is smaller: 30 is "normal", 64 "aggressive". Used for
    /// every encoder setting not given explicitly. Default 30.
    #[schemars(range(max = 100))]
    pub compression: Option<u8>,
    /// Encoder quality 0..=100, higher is better. jpeg: libjpeg quality; webp: cwebp `-q`;
    /// avif: heif-enc quality; png: imagequant target quality (minimum 0); gif: gifski quality.
    #[schemars(range(max = 100))]
    pub quality: Option<u8>,
    /// png: quantise to a palette (default true). false keeps every colour (oxipng only).
    pub lossy: Option<bool>,
    /// webp: lossless encoding (default false).
    pub lossless: Option<bool>,
    /// jpeg: progressive scans (default true).
    pub progressive: Option<bool>,
    /// png: imagequant speed 1..=10; avif: encoder speed 1..=10 (default 6).
    #[schemars(range(min = 1, max = 10))]
    pub speed: Option<u8>,
    /// png/gif: maximum palette size 2..=256.
    #[schemars(range(min = 2, max = 256))]
    pub colors: Option<u16>,
    /// webp: libwebp method 0..=6 (default 4).
    #[schemars(range(max = 6))]
    pub method: Option<u8>,
    /// Internal: JPEG probes without mozjpeg's scan search (`fit`). Not part of the protocol.
    #[serde(skip)]
    #[schemars(skip)]
    pub jpeg_fast_scans: bool,
}

// MARK: per-op params

/// `probe` takes no params.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct ProbeParams {}

/// `png.optimise`: imagequant (when lossy) then oxipng. Falls back to lossless oxipng when the
/// palette would miss `quality[0]` or comes out bigger.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct PngParams {
    /// Quantise to a palette. Default true (the PNG path Clop takes). Animated PNGs are always
    /// optimised losslessly.
    pub lossy: Option<bool>,
    /// imagequant `[minimum, target]` quality, 0..=100. Default from `compression`.
    pub quality: Option<[u8; 2]>,
    /// imagequant speed 1..=10 (1 slowest, best). Default from `compression`.
    #[schemars(range(min = 1, max = 10))]
    pub speed: Option<u8>,
    /// Maximum palette size 2..=256. Default from `compression`.
    #[schemars(range(min = 2, max = 256))]
    pub colors: Option<u16>,
    /// Dithering level 0..=1 (default 1, like pngquant).
    pub dither: Option<f32>,
    /// oxipng effort preset 0..=6. Default from `compression`: 0 below 50, 1 below 85, else 2.
    #[schemars(range(max = 6))]
    pub level: Option<u8>,
    /// Compression factor; see `EncodeParams.compression`.
    #[schemars(range(max = 100))]
    pub compression: Option<u8>,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// `jpeg.optimise`: mozjpeg. `quality` is a ceiling, like jpegoptim `--max`: a file whose
/// estimated quality is above it is re-encoded at it; the others are only recompressed
/// losslessly (Huffman optimisation, progressive scans), so optimising twice never degrades.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct JpegParams {
    /// 0..=100, or null for lossless recompression only. Absent: from `compression` (85 at 30).
    #[serde(deserialize_with = "double_option")]
    #[schemars(with = "Option<u8>", range(max = 100))]
    pub quality: Option<Option<u8>>,
    /// Progressive scans (default true).
    pub progressive: Option<bool>,
    /// Compression factor; see `EncodeParams.compression`.
    #[schemars(range(max = 100))]
    pub compression: Option<u8>,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// `webp.encode`: libwebp from any decodable input; animated GIF/WebP input stays animated.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct WebpParams {
    /// cwebp `-q` 0..=100. Default from `compression` (60 at 30).
    #[schemars(range(max = 100))]
    pub quality: Option<u8>,
    /// Lossless WebP (default false).
    pub lossless: Option<bool>,
    /// libwebp method 0..=6 (default 4, as cwebp).
    #[schemars(range(max = 6))]
    pub method: Option<u8>,
    /// Compression factor; see `EncodeParams.compression`.
    #[schemars(range(max = 100))]
    pub compression: Option<u8>,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// `avif.encode`: libaom (through libavif) from any decodable still input (animations use the first
/// frame). Builds without an AVIF encoder answer `unsupported`; `hello.features.avif_encoder`
/// says which encoder, if any, this build has.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct AvifParams {
    /// 0..=100 on heif-enc's scale (the one Clop gives `heif-enc -q`). Default from `compression`.
    #[schemars(range(max = 100))]
    pub quality: Option<u8>,
    /// Encoder speed 1..=10 (default 6, as heif-enc).
    #[schemars(range(min = 1, max = 10))]
    pub speed: Option<u8>,
    /// Compression factor; see `EncodeParams.compression`.
    #[schemars(range(max = 100))]
    pub compression: Option<u8>,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// Which GIF optimiser runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum GifBackend {
    /// gifsicle when found (`$ESCLOP_BIN`, next to the engine, then `PATH`), else built-in.
    #[default]
    Auto,
    /// gifsicle, or `unsupported` when it is not found.
    Gifsicle,
    /// The engine's own re-encode (gif decoder + gifski/imagequant).
    Builtin,
}

/// `gif.optimise`.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct GifParams {
    /// gifsicle `--lossy` 0..=200 (0 = lossless). Default from `compression` (30 at 30).
    #[schemars(range(max = 200))]
    pub lossy: Option<u32>,
    /// Maximum palette size 2..=256. Default from `compression`.
    #[schemars(range(min = 2, max = 256))]
    pub colors: Option<u16>,
    /// gifsicle `-O` level 1..=3. Default from `compression`.
    #[schemars(range(min = 1, max = 3))]
    pub level: Option<u8>,
    pub backend: Option<GifBackend>,
    /// Compression factor; see `EncodeParams.compression`.
    #[schemars(range(max = 100))]
    pub compression: Option<u8>,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// `gif.from_frames`: gifski over the PNG frames in `frames_dir`, in file-name order.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct GifFramesParams {
    /// Folder of PNG frames (for example what ffmpeg extracted). Falls back to `input`.
    pub frames_dir: Option<PathBuf>,
    /// Frames per second (default 10).
    pub fps: Option<f32>,
    /// gifski quality 1..=100 (default 90).
    #[schemars(range(min = 1, max = 100))]
    pub quality: Option<u8>,
    /// Maximum output width; height follows the aspect ratio unless given.
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// Loop count; 0 or absent loops forever.
    pub repeat: Option<u16>,
    /// Faster, lower-quality encode.
    pub fast: Option<bool>,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// Resampling filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Filter {
    Nearest,
    Box,
    Bilinear,
    Hamming,
    CatmullRom,
    Mitchell,
    #[default]
    Lanczos3,
}

/// `resize`: fast_image_resize. Give exactly one of `scale`, `long_edge`, or `width`/`height`
/// (both: fit inside the box, keeping the aspect ratio). Sizes are in displayed pixels: EXIF
/// orientation is applied first and the output is written upright.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct ResizeParams {
    /// Factor, 0 < scale <= 4.
    pub scale: Option<f64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// Length of the longer side.
    pub long_edge: Option<u32>,
    pub filter: Option<Filter>,
    /// Never enlarge (default true): a target larger than the image leaves the size unchanged.
    pub only_shrink: Option<bool>,
    /// Output format (default: the input's).
    pub format: Option<Format>,
    #[serde(flatten)]
    pub encode: EncodeParams,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// A rectangle in displayed pixels.
#[derive(Debug, Clone, Copy, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// Where an aspect crop sits when it does not use the whole image.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Gravity {
    #[default]
    Center,
    Top,
    Bottom,
    Left,
    Right,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

/// An aspect ratio: `"16:9"`, `"1:1"` or a number (width / height).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum Aspect {
    Ratio(f64),
    Text(String),
}

/// `crop`. Three forms:
/// 1. `x`, `y`, `width`, `height`: that rectangle.
/// 2. `aspect` (+ `gravity` or `smart`): the largest rectangle of that aspect; then, when `width`
///    or `height` is also given, scaled down to it.
/// 3. `width` and `height` alone: crop to their aspect, then scale to exactly that size (Clop's
///    "crop to size").
///
/// `smart` is a saliency rectangle (from Vision on the Swift side): the crop is centred on it as
/// far as the image allows, and `gravity` is ignored. Coordinates are in displayed pixels.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct CropParams {
    pub x: Option<u32>,
    pub y: Option<u32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub aspect: Option<Aspect>,
    pub gravity: Option<Gravity>,
    pub smart: Option<Rect>,
    /// Output format (default: the input's).
    pub format: Option<Format>,
    #[serde(flatten)]
    pub encode: EncodeParams,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// `metadata.strip`: removes metadata without re-encoding pixels (JPEG segments, PNG chunks,
/// WebP chunks, GIF comments and application extensions).
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct StripParams {
    /// What to keep. Default `["icc", "orientation"]`; `[]` strips everything.
    pub keep: Option<Vec<Keep>>,
    pub in_place: bool,
    /// Write even when nothing was removed (default true).
    pub allow_larger: Option<bool>,
}

/// `convert`: decode anything decodable, encode to `format`.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct ConvertParams {
    /// Target format: png, jpeg, webp, avif or gif. Required.
    pub format: Option<Format>,
    #[serde(flatten)]
    pub encode: EncodeParams,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// `fit`: the best quality, then the largest scale, whose output is at most `target_bytes`.
/// Every probe encodes from the original pixels, so nothing compounds.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct FitParams {
    /// Required, > 0.
    pub target_bytes: u64,
    /// Lowest encoder quality to try (default 10).
    #[schemars(range(max = 100))]
    pub min_quality: Option<u8>,
    /// Highest encoder quality to try (default 95; for a JPEG input, at most its own quality).
    #[schemars(range(max = 100))]
    pub max_quality: Option<u8>,
    /// Downscale when even `min_quality` is too big (default true).
    pub allow_resize: Option<bool>,
    /// Smallest scale to try (default 0.1).
    pub min_scale: Option<f64>,
    /// Output format (default: the input's).
    pub format: Option<Format>,
    /// png: quantise (default true). webp: lossless is never used by fit.
    pub lossy: Option<bool>,
    /// avif speed (default 6).
    #[schemars(range(min = 1, max = 10))]
    pub speed: Option<u8>,
    #[serde(flatten)]
    pub out: OutputParams,
}

/// `pdf.optimise`: recompresses a PDF's streams without touching fonts, text, annotations, forms,
/// outlines or structure. Encrypted PDFs answer `unsupported`, damaged ones `decode`.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(default)]
pub struct PdfParams {
    /// Highest image resolution kept, in dots per inch of the page: 48..=300. Images drawn
    /// denser are downsampled to it. 0, 300 or absent: no downsampling.
    #[schemars(range(max = 300))]
    pub dpi: Option<u32>,
    /// Compression factor 0..=100 (30 normal, 64 aggressive): the JPEG ceiling images are
    /// re-encoded at, as for `jpeg.optimise`. JPEGs are re-encoded only when downsampled or, with
    /// a `dpi`, above the ceiling; otherwise they are only re-coded losslessly. At 0 no image is
    /// touched (only streams, fonts and, with `strip`, metadata change). Default 30.
    #[schemars(range(max = 100))]
    pub compression: Option<u8>,
    /// `strip` removes the document information, the catalog's XMP, page thumbnails and
    /// application data (`/PieceInfo`); `keep` does not apply.
    #[serde(flatten)]
    pub out: OutputParams,
}

// MARK: results

/// `result` of every op except `hello`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct OpResult {
    /// Size of the input file.
    pub bytes_before: u64,
    /// Size of the output file (equal to `bytes_before` for `probe`).
    pub bytes_after: u64,
    /// Width of the output (stored pixels; for `probe`, of the input).
    pub width: u32,
    pub height: u32,
    /// Format of the output (for `probe`, of the input).
    pub format: Option<Format>,
    /// Where the result was written.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<PathBuf>,
    /// Encoder quality used (jpeg/webp/avif/gif quality, png target quality); for `fit`, the
    /// quality chosen. Absent for lossless paths.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quality: Option<u8>,
    /// Whether pixels changed (false for lossless recompression and `metadata.strip`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lossy: Option<bool>,
    /// `fit` and `resize`: the scale applied to the input's displayed size.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
    /// `fit`: whether the output is at most `target_bytes`. When false the output is the smallest
    /// the search reached.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fitted: Option<bool>,
    /// `gif.*`: `gifsicle` or `builtin`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backend: Option<String>,
    /// Frame count of the output (or for `probe`, of the input).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frames: Option<u32>,
    /// Params the op did not recognise and ignored.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ignored_params: Vec<String>,
    /// `probe` only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe: Option<ProbeInfo>,
}

/// What `probe` found out about the input.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct ProbeInfo {
    /// Whether the engine can decode this format (heic, avif and jxl: false).
    pub decodable: bool,
    /// `rgb`, `gray`, `cmyk`, `ycck` or `indexed`.
    pub color_space: Option<String>,
    pub bit_depth: Option<u8>,
    pub has_alpha: bool,
    pub has_exif: bool,
    pub has_icc: bool,
    pub has_xmp: bool,
    /// EXIF orientation 1..=8 (1 when absent).
    pub orientation: u8,
    /// Size as displayed, after orientation.
    pub display_width: u32,
    pub display_height: u32,
    pub frames: u32,
    pub animated: bool,
    /// JPEG: estimated libjpeg quality of the luminance table.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jpeg_quality: Option<u8>,
    /// JPEG: progressive scans.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progressive: Option<bool>,
    /// JPEG: has an MPF index of secondary images (an HDR gain map, a depth map). The engine
    /// drops those when it rewrites the file; route such files to ImageIO to keep them.
    #[serde(default)]
    pub multi_picture: bool,
}

/// `result` of `hello`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct HelloResult {
    /// Engine version (semver).
    pub version: String,
    /// Wire protocol version; see `PROTOCOL_VERSION`.
    pub protocol: u32,
    pub ops: Vec<String>,
    pub features: Features,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Features {
    pub decode: Vec<Format>,
    pub encode: Vec<Format>,
    /// The JPEG codec behind `jpeg.*` (`mozjpeg`).
    pub jpeg_codec: String,
    /// The AVIF encoder of this build, e.g. `"libaom 3.15.3 (tune=iq)"`, or null when the build
    /// has none: then `avif.encode` answers `unsupported` and the client encodes AVIF itself
    /// (ImageIO).
    pub avif_encoder: Option<String>,
    /// Path of the gifsicle `gif.optimise` would run, or null.
    pub gifsicle: Option<PathBuf>,
    /// Requests that run at the same time in `serve`; the rest wait in order.
    pub workers: usize,
    /// The compression factor anchors.
    pub compression_normal: u8,
    pub compression_aggressive: u8,
    /// Extra protocol capabilities: `cancel`, `progress`, `in_place`, `ignored_params`.
    pub capabilities: Vec<String>,
}

/// Deserialises a field that distinguishes absent (outer `None`) from `null` (`Some(None)`).
fn double_option<'de, D, T>(d: D) -> Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(d).map(Some)
}
