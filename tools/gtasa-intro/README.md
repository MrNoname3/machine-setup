# gtasa-intro — GTA San Andreas's intro videos under Proton

The Steam release of GTA San Andreas (3.0) starts at the main menu: the Rockstar
logos, the title sequence and the loading screens before it never play. Two
things stand in the way, and [gtasa-intro.sh](gtasa-intro.sh) changes both:

- **The game skips them at 32-bit colour depth.** One byte in `gta-sa.exe` is
  the depth it compares against; the script sets it to 0, which never matches.
  It only touches the build whose SHA-256 it knows, and leaves any other alone.
- **Wine's default video renderer draws nothing over the game.** DirectShow
  picks `VideoRendererDefault`, which Wine implements as VMR7, and its window
  stays white over a wined3d OpenGL window. The script marks that filter
  `MERIT_DO_NOT_USE` in the prefix's registry, so the graph falls back to the
  GDI Video Renderer, which draws correctly. VMR9 is no way out: it renders
  through a second Direct3D device from another thread.

Nothing from the game is in this directory — only an offset, a byte value and
the hashes of the two builds.

## Use

As a Steam launch option (Properties → General → Launch Options), in front of
`%command%` and after any variables already there:

```
PROTON_USE_WINED3D=1 ~/Projects/machine-setup/tools/gtasa-intro/gtasa-intro.sh %command%
```

It applies both changes before every start, so a file check in Steam (which
restores the executable) costs nothing. Proton does not re-register the filter
on an update, but a new prefix does: the first start after deleting
`compatdata/12120` runs before there is a registry to change, and the intro
plays from the second.

By hand, with the game closed:

```
gtasa-intro.sh status|apply|revert GAME_DIR COMPATDATA
```

`GAME_DIR` holds `gta-sa.exe`; `COMPATDATA` is `steamapps/compatdata/12120` in
the same library. `revert` restores the original byte and Wine's merit.

## Skipping the videos on nouveau

On nouveau, a key press that cuts a video short can kill the game's GPU channel
(`ILLEGAL_MTHD` / `EMPTY_SUBC` in the kernel log, a black screen): the renderer
thread and the game's render thread race in Mesa's nouveau driver. Let the
videos run to the end there.
