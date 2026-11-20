# Command line

`esclop --help` lists every command and `esclop <command> --help` its options. The CLI runs its
jobs through the app when it is open, and in its own process otherwise (`--in-process` forces it).
This page covers the parts that are easy to miss.

## One kind of file

```sh
esclop optimise image ~/Desktop/shots     # only the images in the folder
esclop optimise video talk.mov            # refused if any file named is not a video
```

`esclop optimise image|video|pdf|audio <files>` takes the plain command's options for one kind.
A file of another kind is refused before anything runs; a folder gives only its files of that
kind. A file named `image` (or `video`, `pdf`, `audio`) in the working directory is still that file.

## Bitrate

```sh
esclop optimise talk.mov --bitrate 2500   # the video stream's bitrate, in kbit/s
esclop convert -t m4a song.wav --bitrate 128
```

`--bitrate <kbps>` (optimise and convert) sets the video stream's bitrate for videos and the
audio bitrate for audio files. When one command has both, it sets the videos' only: give audio
files a command of their own. The encoder follows the settings.
