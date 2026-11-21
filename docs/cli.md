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

## Settings on another Mac

```sh
esclop settings export ~/esclop-settings.json   # standard output without a file
esclop settings import ~/esclop-settings.json
esclop settings import --allow-permissions ~/esclop-settings.json   # also the agent permissions
```

The file holds only the settings you set, as JSON (`{"format": "esclop-settings", "version": 1,
"settings": {...}}`), so the other Mac keeps its own defaults for the rest. Import checks every
value first: one that its setting does not take changes nothing. Keys this version does not know
are skipped and named, and a file from a newer version says so. Agent permissions the file turns on
(`allowRunScripts`, `allowUploads`, …) are skipped and named unless `--allow-permissions` is given;
Settings › General › Import… asks, with Import Without Permissions as the default. Pipelines,
hotkeys and upload keys are not in the file and stay where they are. Settings › General › Export…
and Import… do the same.
