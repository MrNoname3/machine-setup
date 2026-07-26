# appimages role — Gear Lever's AppImage set and their update sources

A handful of apps ship only as AppImages (no Flathub build, or the Flathub build
lags). [Gear Lever](https://github.com/mijorus/gearlever) (`it.mijorus.gearlever`,
installed by the **flatpaks** role) integrates them: it moves the binary into
`~/AppImages`, extracts the icon, writes a desktop entry — and, per app, knows
where to look for a new version.

That last part is what this role manages. The app *set* is recorded in
`host_vars/<host>/main.yml`; the binaries themselves are not in git (they are
hundreds of MB each) and are integrated once by hand — see below.

## Why this role exists: updates had silently stopped working

Gear Lever 4.x moved per-app update settings out of `apps.json` (v1) into
`gearlever.conf` (v2), with a one-shot migration on first start. The migration
reads the old manager name from the wrong key:

```python
# main.py, migrate_to_v2_config()
update_url_manager = app_conf.get('manager', None)   # apps.json stores it as
                                                     # 'update_url_manager'
if update_url_manager:                               # -> always None, never runs
    ...
    update_manager.migrate_v2()                      # -> never called
```

So the migration wrote only `{'website': ...}` for each app and **dropped every
update source**. The app's own log shows it happening, in one second:

```
17:14:39 INFO Setting app config for MQTT Explorer (app.<md5>): {'website': ''}
17:14:39 INFO Setting app config for Logic (app.<md5>):         {'website': ''}
17:14:39 INFO Setting app config for LM-Studio (app.<md5>):     {'website': ''}
17:14:39 INFO Setting app config for FlightCore (app.<md5>):    {'website': ''}
---- Application startup | version 4.5.3
```

(The real log prints the full md5 of each AppImage's absolute path. Those hashes
are derived from `/home/<user>/…`, so they are elided here — this repo is public.)

The failure is quiet by design: with no `manager` key Gear Lever falls back to
the AppImage's *embedded* update info (`.upd_info`, which none of these four
have) and then simply lists the app as `UpdatesNotAvailable` — indistinguishable
from "no update source was ever configured".

```sh
flatpak run it.mijorus.gearlever --list-installed   # before: all UpdatesNotAvailable
```

A second, independent breakage hit **LM Studio**: `apps.json` is keyed by
base64 of the app name, and its entry was written as `LM Studio` while the
integrated app is named `LM-Studio`. Even a correct migration would have missed
it, so its URL had to be re-entered rather than recovered.

The role rewrites those sections from host_vars, so the state is reproducible
and a future migration bug is a `./scripts/apply.sh` away from being fixed.

## How the config is written

Gear Lever keys each app's update config by the **md5 of the AppImage's absolute
path**:

```ini
[app.<md5 of file_path>.update_manager]
manager = GithubUpdater
repo = R2NorthstarTools/FlightCore
repo_filename = FlightCore_*_amd64.AppImage
allow_prereleases = False
```

The role computes that hash (`hash('md5')` over `appimages_dir` + `file`) and
sets each key with `ini_file`. The equivalent supported command is:

```sh
flatpak run it.mijorus.gearlever --set-update-source ~/AppImages/flightcore.appimage \
  --manager GithubUpdater repo=R2NorthstarTools/FlightCore \
  repo_filename='FlightCore_*_amd64.AppImage' allow_prereleases=false
```

`ini_file` is used instead because the CLI rewrites the whole section on every
invocation (so it can never report `changed=0`), and because it needs no
`flatpak run` per app. Both produce byte-identical keys — this was verified by
writing the config with the CLI first and diffing.

Because the key is the *path*, `file:` in host_vars must match the filename Gear
Lever actually gave the AppImage (it derives it from the AppImage's own desktop
entry, lower-cased with `_`). A mismatch is silent: the config lands under a
hash nothing looks up.

## What silently drops the update source — re-run the role afterwards

**"Reload metadata" in the GUI wipes an app's update source.** That button
(`AppDetails.py` → `AppImageProvider.reload_metadata()`) copies the AppImage aside
and calls:

```python
self.uninstall(el, remove_configuration=False)
```

but that argument is **dead code**: `uninstall()` ends with an unconditional
`Config.delete_app_config(el)` + `Config.delete_app_update_config(el)`, and
`delete_app_config` removes the `.update_manager` section too. The re-install that
follows restores only `[app.<md5>]`, never the update source. So the app goes back
to `UpdatesNotAvailable` — the same silent failure mode as the migration bug.

Verified from the log: Logic lost its section at 15:32:54 on 2026-07-26, right
after `Reloading metadata for …/logic.appimage`.

**Ordinary updates are fine.** In the same session both Logic (2.4.44 → 2.4.45)
and LM Studio (0.4.7+4 → 0.4.20+1) updated without touching their config —
no `uninstall` in the log for either. The GUI's update path does contain an
`uninstall(old_version)` call, but it did not fire here, so updating through the
GUI is not the thing to avoid. There is no need to prefer the CLI for safety.

Either way the repair is the same — re-run the role and it puts everything back:

```sh
./scripts/apply.sh desktop-bazzite --tags appimages -e ansible_become=false
```

**The role checks its own work.** Writing the config is not proof that Gear Lever
accepts it, so the last step asks (`--list-installed --json`) which manager it
actually resolves for each declared app, and fails with an actionable message if
an integrated app resolves no manager, a different one, or a different path than
host_vars declares. That last check matters as much as the first: because the
config is keyed by md5 of the AppImage's path, a `file:` value that has drifted
from the name Gear Lever gave the file writes a perfectly valid section under a
hash nothing ever reads — silent, and otherwise indistinguishable from working.
Apps that are not integrated yet are skipped, and reported separately.

## The desktop entry, and the icon that vanished with it

Gear Lever regenerates an app's desktop entry from the AppImage's *internal* entry
on every update, copying whatever it finds there — including nothing. Saleae Logic
2.4.45 ships this as its complete internal entry:

```ini
[Desktop Entry]
Version=1.5
Type=Application
Name=Logic
Exec=Logic %U
X-AppImage-Name=logic
X-AppImage-Version=2.4.45
X-AppImage-Arch=x86_64
```

No `Icon`, no `Comment`, no `Categories`, and the archive contains no icon file at
all (no `.DirIcon`, nothing under `usr/share/icons` — verified by extracting it).
2.4.44 had all of them, so this is an upstream packaging regression, and the entry
looks machine-generated rather than authored. Gear Lever behaved correctly on that
input and fell back to `Icon=applications-other`, which is how the icon vanished.

This is upstream-specific, not a Gear Lever problem: LM Studio updated in the same
session kept its `Comment`, `Categories`, `StartupWMClass` and a freshly extracted
icon, because its AppImage ships a complete internal entry. Only apps that regress
their own packaging need a `desktop:` block.

The `desktop:` mapping in host_vars puts the missing keys back. Two details make it
survive:

- **icons are referenced by name, never by path.** `uninstall()` also does
  `if '/' in icon and os.path.isfile(icon): os.remove(icon)` — a path-referenced
  icon is *deleted*, not merely dereferenced. So the icon ships in
  `roles/appimages/files/icons/`, is installed into
  `~/.local/share/icons/hicolor/256x256/apps/`, and the entry names it
  (`Icon=logic-appimage`). Gear Lever cannot reach it there;
- **the repair switches itself off.** It only applies while the entry's `Icon` is
  *not* an absolute path. Gear Lever writes a path whenever it did extract an icon,
  so the day upstream fixes its packaging, the guard goes false, the role stops
  overriding the entry and prints a note saying the `desktop:` block can be
  dropped. Testing for `applications-other` instead would misfire on the second
  run, once the role's own icon name is in place.

## The update managers, and why each app uses the one it does

| App | Manager | Source |
|-----|---------|--------|
| FlightCore | `GithubUpdater` | `R2NorthstarTools/FlightCore`, `FlightCore_*_amd64.AppImage` |
| MQTT Explorer | `GithubUpdater` | `thomasnordquist/MQTT-Explorer`, `MQTT-Explorer-*.AppImage`, **pre-releases on** |
| Logic (Saleae) | `StaticFileUpdater` | `https://logic2api.saleae.com/download?os=linux&arch=x64` |
| LM Studio | `StaticFileUpdater` | `https://lmstudio.ai/download/latest/linux/x64?format=AppImage` |

**`StaticFileUpdater`** does a `HEAD` (following redirects) and compares
`content-length` against the local file's size. Both vendor URLs above are
`302`s to a versioned file and answer with a `content-length`, which is what
makes them usable — a redirect target without one would make the app look
permanently up to date.

**`GithubUpdater`** queries the releases API and glob-matches asset names:

- `allow_prereleases: false` uses `/releases/latest`, which also returns a
  `sha256` digest per asset — an exact comparison rather than a size heuristic.
  Right for FlightCore, which publishes only full releases.
- `allow_prereleases: true` lists *all* releases and takes the newest match.
  **Required** for MQTT Explorer: its entire 0.4.x line is tagged pre-release, so
  `/releases/latest` returns 0.3.5 and Gear Lever would offer a **downgrade**.
- When a glob matches several assets (MQTT Explorer publishes arm64 and armv7l
  AppImages under the same pattern), Gear Lever drops the ones whose names look
  like another architecture and keeps the plain x86_64 build. Verified in its log:

  ```
  found 3 possible file targets
   - MQTT-Explorer-0.4.0-beta.6-arm64.AppImage
   - MQTT-Explorer-0.4.0-beta.6-armv7l.AppImage
   - MQTT-Explorer-0.4.0-beta.6.AppImage
  found possible target: MQTT-Explorer-0.4.0-beta.6.AppImage
  ```

Other managers Gear Lever supports, if an app ever needs one:
`GitlabUpdater`, `CodebergUpdater`, `ForgejoUpdater`, `FTPUpdater`.

## Manual steps (the GUI/app owns these)

**Integrating the declared AppImages.** A normal run never downloads anything —
it only reports which declared entries are missing. Bootstrapping a fresh machine
is opt-in, because the current set is about 1.5 GB (LM Studio alone is over 1 GB):

```sh
./scripts/apply.sh desktop-bazzite --tags appimages \
  -e ansible_become=false -e appimages_install_missing=true
```

That resolves each app's download URL — the vendor URL for `StaticFileUpdater`
apps, the newest matching release asset from the API for `GithubUpdater` ones,
using the same glob and architecture filtering Gear Lever itself applies — stages
it in `/var/tmp` (**not** `/tmp`, which is a tmpfs), and hands it to
`--integrate … -y`.

It decides what is missing from the **app name** Gear Lever reports
(`--list-installed --json`), never from the file name: Gear Lever derives the file
name from the AppImage's own desktop entry, so a filename check would re-download
on every run after an upstream rename.

Note that this installs whatever is *current* upstream, not the version recorded
here — the role reproduces a working machine, not an exact set of versions.

Adding a new app by hand instead:

```sh
flatpak run it.mijorus.gearlever --integrate ~/Downloads/Whatever.AppImage -y
flatpak run it.mijorus.gearlever --list-installed     # confirm the file name
```

Then add it to `appimages:` in host_vars with that exact `file:` value.

**Background update checks** (`gearlever_fetch_updates_in_background`) are off,
Gear Lever's own default. The role only mirrors the value into the config file;
the effective switch is a GSettings key that the GUI sets *together with* a
background-portal autostart permission, which Ansible cannot grant. To turn it
on: Gear Lever → Preferences → Updates management → *Check updates on system
startup*. Everything else in Gear Lever's GSettings is at its schema default on
this host (including `appimages-default-folder = ~/AppImages`), so there is
nothing else to record.

Note that the check only *notifies*; it never installs. Also worth knowing before
enabling it: the notification carries an "Open Gear Lever" action and Gear Lever
waits on it, so the fetch process lingers for up to its 10-minute expiry on every
session start.

### Why Bazzite's automatic updater does not cover these

Asked and answered, so it does not need re-deriving: `uupd` (the `ublue-update`
successor, `uupd.timer`, daily 04:00, `Persistent=true`) has exactly four
modules — `system` (bootc/rpm-ostree), `flatpak` (system *and* per-user), `brew`
and `distrobox`. **There is no AppImage module**, and `uupd` is a fixed-module Go
binary whose config schema only accepts `disable` plus binary paths, so unlike its
predecessor's TOML it takes no custom hooks or user scripts. AppImages sit outside
every package manager by design — which is exactly why Gear Lever exists, and why
their update sources could go missing without anything noticing.

Deliberately **not** added here: a systemd user timer running `--update --all -y`
(or `--fetch-updates`). It would work, and it would match how the rest of the
machine updates, but AppImage updates stay a manual, deliberate step by choice.
The commands are in the next section.

## Checking and applying updates

```sh
flatpak run it.mijorus.gearlever --list-updates          # what is out of date
flatpak run it.mijorus.gearlever --update --all -y       # update everything
```

Updates are never applied by this role — it configures *where* to look, and
leaves the "when" to you.

## Troubleshooting

- **App shows `UpdatesNotAvailable`** — its `[app.<md5>.update_manager]` section
  has no `manager` key. Re-run the role; if it comes back, the AppImage's path
  changed and `file:` in host_vars no longer matches (`--list-installed` prints
  the real path).
- **A pre-release-only project offers a downgrade** — it needs
  `allow_prereleases: true`.
- **`Invalid URL 'None'` in the log** — a `manager` key with no accompanying
  `url`, i.e. a half-written section. Re-running the role restores every key.
- **Log** — `~/.var/app/it.mijorus.gearlever/.local/state/gearlever/gearlever.log`
  (older entries under `cache/logs/`). Verbose logging: Preferences → debug logs.
