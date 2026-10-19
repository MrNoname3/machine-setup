# browser-test — video decoding and freezes in Brave

Tests for the two things that keep coming up with a browser on these
machines' GPUs: whether Brave decodes video in hardware with a given set of
flags, and whether its picture freezes or the GPU faults under ordinary use.
Each run starts its own Brave, with a fresh profile and the debugging port
open, as a systemd user unit, so the browser the user has open is not
touched. It runs on X11, and on Cinnamon's Wayland session.

[run.py](run.py) has three commands:

- **`video NAME`** — plays each test clip and records the decoder Chromium
  chose (`VaapiVideoDecoder` is hardware, `FFmpegVideoDecoder` and
  `VpxVideoDecoder` software), the CPU of the whole browser, and whether the
  picture is white, black or moving; plus the GPU features `chrome://gpu`
  would show. Then it pauses the clip at `REF_T` and compares the picture,
  cell by cell on a grid, with the clip's reference frame from
  [make-media.sh](make-media.sh): `picture` is `ok`, `WRONG` or
  `no reference`, and `wrong_cells` the share of cells that differ. Into
  `results/NAME.json`.

  Only `picture: ok` shows that video plays right. A picture that moves can
  still be garbage: a decoder or a buffer import that gets the layout wrong
  moves just as a right one does, and a hardware decoder that is picked says
  nothing about what reaches the screen.
- **`quality SECONDS`** — per clip, frames shown and dropped over the window,
  and the CPU of the browser and of the compositor. It reads no screen, so it
  disturbs the timing least; this is how a dropped-frame problem shows.
- **`stress NAME MINUTES`** — a freeze hunt: rounds of one action each, with
  real input, after which the page colour in the middle of the screen must be
  the one expected. It stops when the picture does not follow, recording where
  the GPU process waits with [freeze-diag.sh](freeze-diag.sh) (with
  passwordless `sudo`), or when the kernel logs a GPU error, and records the
  round and the action either way. Into `results/stress-NAME.json`.

A run keeps the machine from suspending or going idle while it lasts: through
the desktop's session manager (Cinnamon's or GNOME's, also from an SSH login),
or else through logind, which allows it only from the local session.
Everything after `--` goes to Brave, and `--env K=V` sets its environment:

```
tools/browser-test/run.py video vaapi -- --enable-features=VaapiOnNvidiaGPUs
tools/browser-test/run.py quality 20 --env LIBVA_DRIVER_NAME=nvidia
ACTIONS=appmenu,select,context,bookmarks tools/browser-test/run.py stress menus 10
```

## Setting up

- The clips: [make-media.sh](make-media.sh) encodes them with ffmpeg (H.264
  at 720p and at 1080p in 25, 30 and 60 fps, VP9 at 1080p). Where ffmpeg is
  not installed, run it in a throwaway container.
- On X11: `xwd` and `xprop` (Debian's `x11-apps` and `x11-utils`) and libXtst.
- On Wayland: the virtual input device, from root, for the uid that runs the
  tests, and stopped afterwards:

  ```
  sudo systemd-run --unit=uinputd python3 "$PWD/tools/browser-test/uinputd.py" "$(id -u)"
  sudo systemctl stop uinputd
  ```

  Screen reads go through Cinnamon's `ScreenshotArea` D-Bus call, so the
  Wayland side needs Cinnamon.
- Reading the kernel log needs membership in `adm` or `systemd-journal`;
  without it, `stress` only watches the screen.

The profile, the results and the clips live in `work/browser-test/` of this
repository, or in `BT_STATE`; so does the test browser's `XDG_DATA_HOME`, where
web apps installed by policy put their launchers instead of next to the user's. The test pages in [www/](www/) are served on
`127.0.0.1:8765` by [serve.py](serve.py), which `run.py` starts as the
`browser-test-www` user unit when it is not running.

## Settings

| Variable | Effect |
|---|---|
| `CLIPS` | comma-separated clips for `video` and `quality`, as `media/NAME` |
| `BT_PAGE` | the video page: `video.html`, or `video-anim.html`, which keeps a tiny animation running so the compositor redraws every frame |
| `ACTIONS` | the `stress` actions, comma-separated, picked at random with a fixed seed |
| `BT_LOG=1` | the coloured test pages carry a log panel that appends and scrolls continuously, as a CI job page does |
| `BT_WAYLAND` | `1` or `0` overrides the choice from `XDG_SESSION_TYPE` |
| `BT_NO_OZONE=1` | on Wayland, Brave runs through Xwayland instead of as a Wayland client |
| `BT_STDERR` | a file for Brave's log |
| `BT_BRAVE` | the Brave binary, `/opt/brave.com/brave/brave` by default |
| `BT_NETWORK=1` | lets the test browser reach the internet; by default only `127.0.0.1` resolves, so web apps a browser policy installs do not load in the background and skew the CPU figures |

The `stress` actions:

| Action | What it does |
|---|---|
| `click` | clicks the page, which links red to blue and back |
| `newtab`, `switch`, `close` | Ctrl+T to a red page, Ctrl+Tab, Ctrl+W |
| `appmenu`, `menuclick` | opens and closes the main menu, by Alt+F and by its button |
| `context` | opens and closes the page's context menu |
| `select` | opens and closes a `<select>` list |
| `bookmarks` | opens the folder on the bookmarks bar (Shift+Alt+B, Right, Space), then closes it or opens its first page |
| `tooltip` | hovers a toolbar button until its tooltip shows |
| `video` | plays one of `CLIPS` in the current tab for a few seconds, then goes back to a red page |
| `focus`, `minimise` | another window to the front and back, minimise and restore (X11 only) |

## What it has shown

- On the Tesla cards Brave picked the hardware decoder, the picture moved and
  no frame dropped, yet it was noise or blocks of stale video: Mesa never
  drew the progressive copy it exports, as the export patch gave the copy's
  regions in the wrong field order. The picture check reports such a picture
  as `WRONG`, and `ok` with the fix
  ([tesla notes](../mmiotrace-live/tesla/README.md#video-decoding)).

- On the Phenom's GT 1030 with the NVIDIA driver on X11, Brave froze after
  opening and closing the main menu whenever it rendered through ANGLE's
  EGL backend, which is the only one that decodes video in hardware there.
  On Cinnamon's Wayland session it does not, and the machine moved there.
- Muffin before 6.8 has no presentation-time protocol, and `quality` showed a
  30 fps clip losing about every eighth frame on Wayland; the patched Muffin
  of [tools/patched-deb](../patched-deb/) fixes it.
