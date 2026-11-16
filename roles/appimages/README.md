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

## Launch environment

An app that needs environment variables to start lists them under `env:` in
host_vars. The role writes them where Gear Lever keeps an app's own variables,
the `env K=V ...` prefix of the desktop entry's `Exec` line: they show up in the
app's page in the GUI, an update carries them over, and variables set there by
hand are left alone. Values must not contain whitespace, because Gear Lever
writes them unquoted.

A reinstall starts from a fresh entry without them; re-running the role puts
them back.

FlightCore uses it to preload the host's `libwayland-client`. The copy bundled in
the AppImage does not work with the host's Mesa EGL, so WebKit aborts with
`Could not create default EGL display: EGL_BAD_PARAMETER` and the window stays
white.

## USB hardware

An app that drives USB hardware lists the devices' `vendor:product` ids under
`usb_devices:` in host_vars, and the role writes them to
`/etc/udev/rules.d/70-appimages.rules` with the `uaccess` tag. That gives the
user logged in at the machine access to the device, and no one else; the rule
files the vendors ship use `MODE="0666"` instead, which opens the device to every
local account. Taking the ids from the vendor's file keeps the two lists in step.

## Network interfaces

An app that creates a network interface and sets its MAC address itself lists
the interface under `fixed_mac_interfaces:`. The role writes them to
`/etc/systemd/network/10-appimages-mac.link` with `MACAddressPolicy=none`.
Without it, udev's `99-default.link` gives the new interface a MAC address of its
own, and when that lands after the app has set its address, the app keeps
addressing frames to the old one and the kernel drops every inbound packet.

Radmin VPN's launcher creates `radminvpn0` this way. With the wrong address the
VPN still connects out, but nothing comes back through it: Radmin shows "Another
app is blocking the connection", pings over the VPN go unanswered and games
cannot be joined.

## The update managers, and why each app uses the one it does

| App | Manager | Source |
|-----|---------|--------|
| FlightCore | `GithubUpdater` | `R2NorthstarTools/FlightCore`, `FlightCore_*_amd64.AppImage` |
| MQTT Explorer | `GithubUpdater` | `thomasnordquist/MQTT-Explorer`, `MQTT-Explorer-*.AppImage`, **pre-releases on** |
| Logic (Saleae) | `StaticFileUpdater` | `https://logic2api.saleae.com/download?os=linux&arch=x64` |
| Radmin VPN | `GithubUpdater` | `baptisterajaut/radmin-vpn-linux`, `RadminVPN-Linux-x86_64.AppImage` |

**`StaticFileUpdater`** does a `HEAD` (following redirects) and compares
`content-length` against the local file's size. The vendor URL above is a
`302` to a versioned file and answers with a `content-length`, which is what
makes it usable — a redirect target without one would make the app look
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
is opt-in, because the set runs to hundreds of MB:

```sh
./scripts/apply.sh desktop-bazzite --tags appimages \
  -e ansible_become=false -e appimages_install_missing=true
```

That resolves each app's download URL — the vendor URL for `StaticFileUpdater`
apps, the newest matching release asset from the API for `GithubUpdater` ones,
using the same glob and architecture filtering Gear Lever itself applies — stages
it in `~/.cache/appimages-bootstrap`, and hands it to
`--integrate … --replace -y`. The staging directory has to be on disk (`/tmp` is
a tmpfs) and outside `/var/tmp`, which Gear Lever's flatpak replaces with a
private directory of its own.

It decides what is missing from the **app name** Gear Lever reports
(`--list-installed --json`), never from the file name: Gear Lever derives the file
name from the AppImage's own desktop entry, so a filename check would re-download
on every run after an upstream rename.

That is why `--replace` matters. The CLI's default conflict mode, *keep both*,
appends the version to the app's name, or the first six hex digits of the file's
md5 when the AppImage declares no version (`Radmin VPN (909f22)`). Such a name
matches no `name:` in host_vars, so the role's verification silently skips the
app and the next bootstrap downloads it again. `--replace` writes the name the
AppImage itself declares, which is also what every later update writes.

Note that this installs whatever is *current* upstream, not the version recorded
here — the role reproduces a working machine, not an exact set of versions.

Adding a new app by hand instead:

```sh
flatpak run it.mijorus.gearlever --integrate ~/Downloads/Whatever.AppImage --replace -y
flatpak run it.mijorus.gearlever --list-installed     # confirm the name and file name
```

Then add it to `appimages:` in host_vars with that exact `name:` and `file:`.

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

So the role brings its own: see the next section.

## Checking and applying updates

A user timer (`appimage-update.timer`, on while `appimages_auto_update` is true)
runs `~/.local/bin/appimage-update` half an hour after login, then about once a
day, at a random point within an hour. It skips the run while Gear Lever's window
is open, since the GUI and the CLI write the same config file, and updates each
app with its own `--update <file>`, so a failed download does not stop the
others. An app that is running is left for the next run. It prints one line per
app it touched:

```sh
journalctl --user -t appimage-update
# Logic: 2.4.44 -> 2.4.50
# FlightCore: 2026-10-02 -> 2026-11-14     (no version in the AppImage: file date)
```

Gear Lever deletes the replaced AppImage, so there is no rollback: going back
means downloading the older release by hand. Its own log does not help here
either — it names no versions and is emptied once it passes 5000 lines.

By hand:

```sh
systemctl --user start appimage-update.service          # one run now
flatpak run it.mijorus.gearlever --list-updates          # what is out of date
```

**Radmin VPN** updates in two layers. The AppImage carries Wine and the launcher,
and pins the Radmin build it was validated with; the Radmin installed in its Wine
prefix (`~/.local/share/radmin-vpn-linux/`) only moves to that build when the
AppImage is run once with `--update`, which keeps the Radmin ID. Radmin's own
"Automatic updates" stays off in its settings: it installs into the live prefix
and takes the running service down with it.

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
