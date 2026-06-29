# containers role — rootless Podman, Docker-like, + Distrobox

Sets up **rootless Podman** on the Ubuntu/Mint base and makes it behave like
Docker, plus **Distrobox**. Mirrors how the Fedora/Bazzite desktop "just works":
the key is the registries config, not a `docker` shim.

## What it does

- Installs Podman + the rootless stack (`uidmap`, `slirp4netns`, `passt`,
  `netavark`, `aardvark-dns`, `fuse-overlayfs`), Distrobox, and Docker Compose v2.
- Drops `/etc/containers/registries.conf.d/99-docker-like.conf` so unqualified
  names resolve against **docker.io** (`podman run nginx` works like Docker).
  Ubuntu's Podman ships an empty search list, which is why this is needed.
- Exports `DOCKER_HOST` (via `/etc/profile.d/`) to the rootless Podman socket, so
  `docker compose` v2 / IDE docker plugins / testcontainers talk to Podman.
- Enables user lingering and the rootless `podman.socket`.

## Usage

```sh
podman run --rm hello-world        # pulls from docker.io like Docker
podman compose up                  # Compose v2 against the Podman socket
distrobox create --name dev --image ubuntu:24.04 && distrobox enter dev
```

## The `docker` command

`container_docker_cli` (default `false`) controls the `podman-docker` shim, which
adds a literal `docker` command (a thin wrapper around `podman`). It is a
standalone ~250 KB package that nothing depends on:

- Want `docker run/ps/compose ...`? Set `container_docker_cli: true`, re-run.
- Changed your mind? Set it back to `false`, re-run — it is purged cleanly,
  leaving Podman untouched.

The Bazzite desktop runs podman-native (no shim), so `false` mirrors it.
