# Patches for bundled tools

`Scripts/build-tools.sh` applies `Binaries/patches/<component>/*.patch` (in
name order, `patch -p1` from the unpacked source root) before building. A
component directory is one of: `ffmpeg`, `lame`, `opus`, `libvpx`, `svt-av1`,
`ghostscript`, `gifsicle`.

Patch contents are part of the build cache key, so adding or editing a patch
triggers a rebuild of that tool. Keep patches small and say in a header
comment why each one is needed and when it can be dropped.

There are no patches at the moment.
