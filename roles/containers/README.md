# containers role — rootless Podman (Docker-like) + Distrobox

The single source of truth for the container setup on the laptop (Mint 22 /
Ubuntu 24.04, Podman 4.9). Sets up **rootless Podman** that behaves like Docker,
plus **Distrobox**. Mirrors how the Fedora/Bazzite desktop "just works": the key
is the registries config, not a `docker` shim.

## What the role does

- Asserts unprivileged user namespaces are available (rootless precondition).
- Installs Podman + the rootless stack (`uidmap`, `slirp4netns`, `passt`,
  `netavark`, `aardvark-dns`, `fuse-overlayfs`), Distrobox, and Docker Compose v2.
  - `uidmap` is **required** for rootless (newuidmap/newgidmap).
  - `netavark` + `aardvark-dns` are the modern backend — **default on 24.04**, no
    CNI migration needed.
- Ensures `subuid`/`subgid` ranges for the user (idempotent).
- Drops `/etc/containers/registries.conf.d/99-docker-like.conf` so unqualified
  names resolve against **docker.io** (`podman run nginx` works like Docker).
  Ubuntu's Podman ships an empty search list, which is why this is needed.
- Exports `DOCKER_HOST` (via `/etc/profile.d/99-docker-host.sh`) to the rootless
  Podman socket, so `docker compose` v2 / IDE docker plugins / testcontainers
  talk to Podman.
- Enables user lingering and the rootless `podman.socket`.

Everything runs **rootless** as the normal user — no `sudo` for `podman`.

## Basic usage

```sh
podman run -d -p 8080:80 --name web nginx   # pulls docker.io/library/nginx
podman ps
podman logs web
podman stop web && podman rm web
podman images
podman system prune -af                      # reclaim space
```

Unqualified names (`nginx`, `ubuntu`, `python`…) resolve to Docker Hub, exactly
like Docker. Verified: `podman run hello-world` → "Hello from Docker!".

## Compose v2

```sh
podman compose up -d      # uses the docker-compose v2 provider against Podman
podman compose ps
podman compose down
```

## Networking — name & alias resolution (IMPORTANT)

The #1 gotcha: containers resolve each other by name **only on a user-defined
network**, not on the default `podman` network (that one has no DNS).

```sh
podman network create mynet

# server, reachable as "web" and as the alias "api"
podman run -d --name web --network mynet --network-alias api nginx

# any container on mynet can reach it by either name
podman run --rm --network mynet alpine wget -qO- http://web    # by name
podman run --rm --network mynet alpine wget -qO- http://api    # by alias
```

Both work because the user-defined network uses **aardvark-dns**. (Verified.)
In a compose file every service is on a shared project network automatically, so
service names resolve out of the box.

## Privileged ports (< 1024)

Rootless containers cannot bind ports below 1024 by default (we keep this default
for security). Options:

- **Use a high port** (recommended for dev): `-p 8080:80`.
- **Lower the threshold system-wide** (if you really need `-p 80:80`):
  `echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-podman-lowports.conf && sudo sysctl --system`
  (Not enabled by this role — enable it yourself if needed.)

## Distrobox

Run other distros with full home integration:

```sh
distrobox create --name dev --image ubuntu:24.04
distrobox enter dev
# inside: your $HOME and user are shared; install packages freely

# put a GUI app from the box into the host menu:
distrobox-export --app gimp

distrobox list
distrobox rm -f dev
```

### GPU in containers (optional)

For hardware video decode / 3D, pass the GPU device:

```sh
distrobox create --name dev --image ubuntu:24.04 \
  --additional-flags "--device /dev/dri"
```

This laptop's Intel HD 3000 (Sandy Bridge) uses the legacy VA-API driver — inside
the box install **`i965-va-driver`** (not `intel-media-va-driver`, which is Gen8+).

## The `docker` command (optional)

`container_docker_cli` (default `false`) controls the `podman-docker` shim, which
adds a literal `docker` command (a thin wrapper around `podman`). Standalone
~250 KB package that nothing depends on:

- Want `docker run/ps/compose …`? Set `container_docker_cli: true`, re-run.
- Changed your mind? Set it back to `false`, re-run — it is purged cleanly,
  Podman untouched.

The Bazzite desktop runs podman-native (no shim), so `false` mirrors it.

## SELinux / AppArmor (and the cross-machine `:Z`)

- **No SELinux** on the laptop (Ubuntu/Mint uses AppArmor); `podman info` shows
  `selinux=false`.
- **AppArmor is active but does not confine rootless containers**
  (`apparmor=false` in `podman info`). That is expected: rootless isolation comes
  from **user namespaces + seccomp + dropped capabilities**. Host-side profiles
  (`podman`/`crun`/`runc`) still confine the runtime binaries.
- Ubuntu's unprivileged-userns AppArmor restriction is **off** here
  (`kernel.apparmor_restrict_unprivileged_userns=0`), so rootless works smoothly.
  The role asserts `unshare --user` early so a future regression fails clearly.
- **Cross-machine volumes:** the Bazzite desktop uses **SELinux**, where bind
  mounts often need a relabel flag — `-v ./data:/data:Z` (private) or `:z`
  (shared). On this laptop the flag is a harmless no-op. Keep `:Z` in compose
  files / run commands so they work on **both** machines.

## Troubleshooting

- **`short-name "nginx" did not resolve`**: the docker.io search drop-in is
  missing — re-run the role.
- **Containers can't reach each other by name**: they're on the default `podman`
  network. Create and use a user-defined network (see Networking).
- **Check the backend**: `podman info --format '{{.Host.NetworkBackend}}'` →
  should be `netavark`.
- **Compose can't find a provider**: ensure `docker-compose-v2` is installed
  (the role installs it); `podman compose version` should print the provider path.
- **`docker compose` / API tool can't connect**: `DOCKER_HOST` is set in a new
  login shell only — open a new terminal, or `source /etc/profile.d/99-docker-host.sh`.
