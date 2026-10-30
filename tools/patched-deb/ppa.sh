#!/usr/bin/env bash
#
# ppa.sh source <out-dir>
# ppa.sh upload <out-dir>
# ppa.sh check <out-dir>
#
# The source packages of the PPA and of its build-dependency PPA, from the
# archive versions ppa-sources.yml names. "source" builds them, unsigned, into
# <out-dir> in a throwaway Ubuntu 24.04 container: each source under
# "packages" through build-deb.sh --source, versioned by the number of commits
# that touched its patches, and each under "build_deps" unchanged but for a
# changelog entry for the release. "upload" signs the ones not uploaded yet
# with the host's gpg-agent, which asks for the key's passphrase, and uploads
# them with dput. Both run on the host, with podman. "check" builds them on
# the machine it runs on, as root on Ubuntu 24.04, such as a CI runner.
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

die() { printf 'ppa.sh: %s\n' "$*" >&2; exit 1; }

# listed packages|build_deps: "<source> <version>" for each source of a section.
listed() {
  awk -v want="$1:" '/^[a-z_]+:$/ { section = $1; next }
    section == want && /^  [a-z0-9.+-]+: / { v = $2; gsub(/"/, "", v); sub(/:$/, "", $1); print $1, v }' \
    "$HERE/ppa-sources.yml"
}

# --- inside the container ----------------------------------------------------

# deb-src for the release, kisak's Mesa PPA and its build dependencies, and
# Linux Mint 22.3's backport component, which carries Cinnamon.
container_setup() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq --error-on=any
  apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
  install -Dm644 "$REPO/roles/graphics/files/kisak-mesa.asc" /etc/apt/keyrings/kisak-mesa.asc
  install -Dm644 "$HERE/linuxmint.asc" /etc/apt/keyrings/linuxmint.asc
  cat >/etc/apt/sources.list.d/build.sources <<'EOF'
Types: deb-src
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

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

in_source() { # in_source <out-dir> <revision>/<source>=<version>...
  local out=$1 work dir source want version
  shift
  container_setup ca-certificates dpkg-dev fakeroot patch
  for item in "$@"; do
    "$HERE/build-deb.sh" --source "${item%%/*}" "${item#*/}" "$out/main"
  done
  work=$(mktemp -d)
  while read -r source want; do
    (cd "$work" && apt-get source -qq "$source=$want" >/dev/null 2>&1) || die "apt-get source $source $want failed"
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
  done < <(listed build_deps)
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

[ $# -eq 2 ] || die "usage: ppa.sh source|upload|check <out-dir>"
CMD=$1
mkdir -p "$2"
OUT=$(readlink -f "$2")

# <revision>/<source>=<version> for each source under "packages"; a checkout
# without the history counts 0.
items=()
while read -r source version; do
  revision=$(git -C "$REPO" rev-list --count HEAD -- "tools/patched-deb/patches/$source-*" 2>/dev/null) || revision=0
  items+=("$revision/$source=$version")
done < <(listed packages)

if [ "$CMD" = check ]; then
  [ "$(id -u)" = 0 ] || die "check runs as root"
  [ "$(. /etc/os-release && echo "$VERSION_CODENAME")" = noble ] || die "check runs on Ubuntu 24.04"
  in_source "$OUT" "${items[@]}"
  exit
fi

case $OUT in
  "$REPO"/*) ;;
  *) die "<out-dir> must be inside the repository, which the container mounts" ;;
esac
command -v podman >/dev/null || die "podman is needed"
run=(podman run --rm --security-opt label=disable -v "$REPO:$REPO" -w "$REPO")

case $CMD in
  source)
    "${run[@]}" -e DEBFULLNAME -e DEBEMAIL "$IMAGE" \
      bash "$HERE/ppa.sh" --in-container source "$OUT" "${items[@]}"
    ;;
  upload)
    # The container signs through the agent's socket, which exists only while
    # the agent runs.
    gpgconf --launch gpg-agent
    socket=$(gpgconf --list-dirs agent-extra-socket)
    gpg --export --armor "$KEY" >"$OUT/.key.asc"
    "${run[@]}" -v "$socket:/root/.gnupg/S.gpg-agent" -e KEY="$KEY" "$IMAGE" \
      bash -c 'chmod 700 /root/.gnupg && exec bash "$0" --in-container upload "$1"' \
      "$HERE/ppa.sh" "$OUT"
    ;;
  *) die "usage: ppa.sh source|upload|check <out-dir>" ;;
esac
