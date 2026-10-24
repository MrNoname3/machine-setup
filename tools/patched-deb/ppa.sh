#!/usr/bin/env bash
#
# ppa.sh source <out-dir>
# ppa.sh upload <out-dir>
#
# The source packages of the PPA and of its build-dependency PPA. "source"
# builds them, unsigned, into <out-dir> in a throwaway Ubuntu 24.04 container:
# each source in PACKAGES through build-deb.sh --source, versioned by the
# number of commits that touched its patches, and each source in BUILD_DEPS
# unchanged but for a changelog entry for the release. "upload" signs the ones
# not uploaded yet with the host's gpg-agent, which asks for the key's
# passphrase, and uploads them with dput. Runs on the host, with podman.
#
# Environment:
#   PPA, BUILD_DEPS_PPA   the two archives (ppa:<owner>/<name>)
#   DEBFULLNAME, DEBEMAIL, KEY   the uploader in the changelogs and the
#                         signing key
#
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
REPO=$(readlink -f "$HERE/../..")

PPA=${PPA:-ppa:mrnoname3/machine-setup}
BUILD_DEPS_PPA=${BUILD_DEPS_PPA:-ppa:mrnoname3/machine-setup-build-deps}
export DEBFULLNAME=${DEBFULLNAME:-MrNoname3}
export DEBEMAIL=${DEBEMAIL:-26522650+MrNoname3@users.noreply.github.com}
KEY=${KEY:-EF66147B218C737F9D35DFC518E1A4A55AAF217D}
IMAGE=docker.io/library/ubuntu:24.04

PACKAGES=(mesa xwayland intel-vaapi-driver muffin)
# Muffin from Linux Mint builds against Mint's library, not Ubuntu's older one.
BUILD_DEPS=(cinnamon-desktop)

die() { printf 'ppa.sh: %s\n' "$*" >&2; exit 1; }

# --- inside the container ----------------------------------------------------

# deb-src for the release, kisak's Mesa PPA and its build dependencies, and
# Linux Mint 22.3's backport component, which carries Cinnamon.
container_setup() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq --error-on=any
  apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
  sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
  install -Dm644 "$REPO/roles/graphics/files/kisak-mesa.asc" /etc/apt/keyrings/kisak-mesa.asc
  install -Dm644 "$HERE/linuxmint.asc" /etc/apt/keyrings/linuxmint.asc
  cat >/etc/apt/sources.list.d/build.sources <<'EOF'
Types: deb deb-src
URIs: https://ppa.launchpadcontent.net/kisak/kisak-mesa/ubuntu
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/kisak-mesa.asc

Types: deb
URIs: https://ppa.launchpadcontent.net/kisak/kisak-mesa-build-deps/ubuntu
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/kisak-mesa.asc

Types: deb-src
URIs: http://packages.linuxmint.com
Suites: zena
Components: backport
Signed-By: /etc/apt/keyrings/linuxmint.asc
EOF
  apt-get update -qq --error-on=any
  apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}

in_source() { # in_source <out-dir> <source>:<revision>...
  local out=$1 work dir version
  shift
  container_setup ca-certificates dpkg-dev fakeroot patch
  for item in "$@"; do
    "$HERE/build-deb.sh" --source "${item#*:}" "${item%%:*}" "$out/main"
  done
  work=$(mktemp -d)
  for source in "${BUILD_DEPS[@]}"; do
    (cd "$work" && apt-get source -qq "$source" >/dev/null 2>&1) || die "apt-get source $source failed"
    dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d -name "$source-*")
    version=$(cd "$dir" && dpkg-parsechangelog -S Version)~ppa1
    {
      printf '%s (%s) noble; urgency=medium\n\n' "$source" "$version"
      printf '  * Rebuild for Ubuntu 24.04, as a build dependency only.\n'
      printf '\n -- %s <%s>  %s\n\n' "$DEBFULLNAME" "$DEBEMAIL" "$(date -R)"
      cat "$dir/debian/changelog"
    } >"$work/changelog"
    mv "$work/changelog" "$dir/debian/changelog"
    (cd "$dir" && dpkg-buildpackage -S -d -nc -sa -us -uc >/dev/null 2>&1) || die "source build of $source failed"
    mkdir -p "$out/build-deps"
    cp "$work/${source}_${version#*:}"* "$out/build-deps/"
    ls "$out/build-deps/${source}_${version#*:}.dsc"
  done
}

# Signs with the host's agent, whose socket is mounted over the container's.
in_upload() { # in_upload <out-dir>
  local out=$1 changes
  container_setup ca-certificates devscripts dput gnupg
  export GNUPGHOME=/root/.gnupg
  gpg --batch --quiet --import "$out/.key.asc"
  for target in main build-deps; do
    for changes in "$out/$target"/*_source.changes; do
      [ -e "$changes" ] || continue
      [ -e "${changes%.changes}.ppa.upload" ] && continue
      debsign --re-sign -k"$KEY" "$changes"
      if [ "$target" = main ]; then
        dput "$PPA" "$changes"
      else
        dput "$BUILD_DEPS_PPA" "$changes"
      fi
    done
  done
}

if [ "${1:-}" = --in-container ]; then
  shift
  cmd=$1
  shift
  "in_$cmd" "$@"
  exit
fi

# --- on the host -------------------------------------------------------------

[ $# -eq 2 ] || die "usage: ppa.sh source|upload <out-dir>"
CMD=$1
mkdir -p "$2"
OUT=$(readlink -f "$2")
case $OUT in
  "$REPO"/*) ;;
  *) die "<out-dir> must be inside the repository, which the container mounts" ;;
esac
command -v podman >/dev/null || die "podman is needed"
run=(podman run --rm --security-opt label=disable -v "$REPO:$REPO" -w "$REPO")

case $CMD in
  source)
    items=()
    for source in "${PACKAGES[@]}"; do
      items+=("$source:$(git -C "$REPO" rev-list --count HEAD -- "tools/patched-deb/patches/$source-*")")
    done
    "${run[@]}" -e DEBFULLNAME -e DEBEMAIL "$IMAGE" \
      bash "$HERE/ppa.sh" --in-container source "$OUT" "${items[@]}"
    ;;
  upload)
    socket=$(gpgconf --list-dirs agent-extra-socket)
    gpg --export --armor "$KEY" >"$OUT/.key.asc"
    "${run[@]}" -v "$socket:/root/.gnupg/S.gpg-agent" -e KEY="$KEY" "$IMAGE" \
      bash -c 'chmod 700 /root/.gnupg && exec bash "$0" --in-container upload "$1"' \
      "$HERE/ppa.sh" "$OUT"
    ;;
  *) die "usage: ppa.sh source|upload <out-dir>" ;;
esac
