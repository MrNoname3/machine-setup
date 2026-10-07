#!/usr/bin/env bash
# Bootstrap a fresh machine so Ansible can take over.
#
# One-liner (interactive host menu; run as your normal user, NOT root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrNoname3/machine-setup/main/bootstrap.sh)"
# Non-interactive (pick the host up front):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrNoname3/machine-setup/main/bootstrap.sh)" -- laptop-old
# From a branch, with extra arguments for scripts/apply.sh (here a dry run):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrNoname3/machine-setup/main/bootstrap.sh)" -- --branch my-branch laptop-old --check --diff
#
# NB the `bash -c "$(curl ...)"` form (not `curl | bash`) keeps stdin attached
# to the terminal so the menu below can actually prompt.
#
# What it does (idempotent, safe to re-run):
#   1. Installs the bare minimum to get going: git + python3-venv (apt on
#      Debian/Mint; nothing on Bazzite — both ship with the image). Ansible
#      itself is NOT installed system-wide: scripts/apply.sh bootstraps the
#      pinned toolchain into the repo-local .venv on first use, so deleting
#      the repo directory later leaves nothing behind.
#   2. Clones this repo into ~/Projects/machine-setup, or fast-forwards an
#      existing clone, on the branch given with --branch (default: main for a
#      new clone, the checked-out branch for an existing one).
#   3. Lets you pick an inventory host and optionally runs the playbook for it
#      (first run uses -K: it asks your sudo password once).
#
# Usage: bootstrap.sh [-b|--branch BRANCH] [HOST [apply.sh arguments...]]
# A HOST skips the menu and runs the playbook for it; the arguments after it go
# to scripts/apply.sh. Overrides: REPO_URL / REPO_DIR / REPO_BRANCH env vars.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/MrNoname3/machine-setup.git}"
REPO_DIR="${REPO_DIR:-$HOME/Projects/machine-setup}"
BRANCH="${REPO_BRANCH:-}"

msg() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: bootstrap.sh [-b|--branch BRANCH] [HOST [apply.sh arguments...]]

  -b, --branch BRANCH  clone or switch to BRANCH (default: main for a new
                       clone, the checked-out branch for an existing one)
  HOST                 skip the menu and run the playbook for this host
  apply.sh arguments   passed on to scripts/apply.sh, e.g. --check --diff

Environment: REPO_URL, REPO_DIR, REPO_BRANCH (same as --branch).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--branch) [ $# -ge 2 ] || die "$1 needs a branch name"; BRANCH="$2"; shift 2 ;;
    --branch=*)  BRANCH="${1#*=}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    -*)          die "unknown option '$1' (options go before the host)" ;;
    *)           break ;;
  esac
done
HOST="${1:-}"
[ $# -gt 0 ] && shift
APPLY_ARGS=("$@")

[ "$(id -u)" != 0 ] || die "run as your normal user, not root (sudo is used where needed)"

# --- 1. OS detection + prerequisites -----------------------------------------
[ -r /etc/os-release ] || die "/etc/os-release not found — unsupported system"
. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *bazzite*)
    OS_FAMILY=bazzite
    msg "Bazzite detected — git + python3 ship with the image, nothing to install"
    ;;
  *debian*|*ubuntu*|*linuxmint*)
    OS_FAMILY=debian
    msg "Debian-family detected — ensuring git + python3-venv (apt)"
    NEED=()
    command -v git >/dev/null 2>&1 || NEED+=(git)
    python3 -c 'import ensurepip' 2>/dev/null || NEED+=(python3-venv)
    if [ "${#NEED[@]}" -gt 0 ]; then
      sudo apt-get update -y
      sudo apt-get install -y "${NEED[@]}"
    else
      msg "git + python3-venv already installed"
    fi
    ;;
  *)
    die "unsupported distro '${PRETTY_NAME:-unknown}' — add a branch for it in bootstrap.sh"
    ;;
esac

# --- 2. Get the repo ----------------------------------------------------------
# Fails with a clear message when the branch is missing on the remote, before
# anything is cloned or switched.
require_remote_branch() { # <remote or URL> <branch> <hint when missing>
  local rc=0
  git ls-remote --exit-code --heads "$1" "refs/heads/$2" >/dev/null || rc=$?
  case "$rc" in
    0) ;;
    2) die "branch '$2' does not exist on $1 — $3" ;;
    *) die "could not reach $1 to look for branch '$2'" ;;
  esac
}
NOT_PUSHED="pushed yet? the GitHub mirror follows the push to Gitea"

if [ -d "$REPO_DIR/.git" ]; then
  G=(git -C "$REPO_DIR")
  CURRENT=$("${G[@]}" symbolic-ref --quiet --short HEAD) \
    || die "$REPO_DIR is not on a branch (detached HEAD) — check one out, or pass --branch"
  TARGET="${BRANCH:-$CURRENT}"
  if [ -n "$BRANCH" ]; then HINT=$NOT_PUSHED; else HINT="merged and deleted? re-run with --branch main"; fi
  require_remote_branch "$("${G[@]}" remote get-url origin)" "$TARGET" "$HINT"
  if [ "$TARGET" != "$CURRENT" ] && [ -n "$("${G[@]}" status --porcelain)" ]; then
    die "$REPO_DIR has uncommitted changes — commit or stash them before switching to '$TARGET'"
  fi
  msg "Repo already at $REPO_DIR — fast-forwarding '$TARGET'"
  "${G[@]}" fetch origin "$TARGET"
  # A branch with no local copy yet is created tracking origin/$TARGET.
  [ "$TARGET" = "$CURRENT" ] || "${G[@]}" switch "$TARGET"
  "${G[@]}" merge --ff-only "origin/$TARGET"
else
  TARGET="${BRANCH:-main}"
  require_remote_branch "$REPO_URL" "$TARGET" "$NOT_PUSHED"
  msg "Cloning '$TARGET' into $REPO_DIR"
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --branch "$TARGET" "$REPO_URL" "$REPO_DIR"
fi
REVISION="$TARGET @ $(git -C "$REPO_DIR" rev-parse --short HEAD)"

# --- 3. Pick a host + optionally run the playbook -----------------------------
# Hosts come from inventory.ini, so new machines show up here automatically.
mapfile -t HOSTS < <(awk '!/^[[:space:]]*($|#|\[)/ {print $1}' "$REPO_DIR/inventory.ini" | sort -u)
[ "${#HOSTS[@]}" -gt 0 ] || die "no hosts found in inventory.ini"

# Suggest the host matching this OS as the default menu choice.
DEFAULT=""
case "$OS_FAMILY" in
  bazzite) DEFAULT=desktop-bazzite ;;
  debian)
    # Mint is the laptop; plain Debian is the tablet image's system.
    case "${ID:-}" in
      debian) DEFAULT=tablet-miix ;;
      *)      DEFAULT=laptop-old ;;
    esac
    ;;
esac

RUN=no
if [ -n "$HOST" ]; then
  printf '%s\n' "${HOSTS[@]}" | grep -qx "$HOST" || die "host '$HOST' not in inventory.ini (on branch '$TARGET')"
  RUN=yes
else
  msg "Which machine is this? (0 = just clone/update, don't run the playbook)"
  i=1
  for h in "${HOSTS[@]}"; do
    mark=""; [ "$h" = "$DEFAULT" ] && mark="  <-- detected OS suggests this"
    printf '  %d) %s%s\n' "$i" "$h" "$mark"
    i=$((i+1))
  done
  printf '  0) clone/update only\n'
  read -rp "Choice: " CHOICE
  if [ "$CHOICE" != 0 ]; then
    [ "$CHOICE" -ge 1 ] 2>/dev/null && [ "$CHOICE" -le "${#HOSTS[@]}" ] || die "invalid choice"
    HOST="${HOSTS[$((CHOICE-1))]}"
    read -rp "Run the playbook for '$HOST' now? [Y/n] " YN
    case "${YN:-Y}" in [Yy]*|"") RUN=yes ;; *) RUN=no ;; esac
  fi
fi

if [ "$RUN" = yes ]; then
  msg "Applying the playbook for '$HOST' from $REVISION (you will be asked for your sudo password once)"
  # scripts/apply.sh bootstraps the repo-local toolchain (.venv + collections).
  "$REPO_DIR/scripts/apply.sh" "$HOST" -K "${APPLY_ARGS[@]}"
fi

# --- 4. What to run day-to-day -------------------------------------------------
msg "Done ($REVISION). Day-to-day usage:"
echo "    cd $REPO_DIR && git pull --ff-only"
if [ "$TARGET" != main ]; then
  echo "    # on branch '$TARGET'; once it is merged: git switch main && git pull --ff-only"
fi
case "$OS_FAMILY" in
  bazzite)
    echo "    ./scripts/apply.sh ${HOST:-desktop-bazzite} -e ansible_become=false"
    echo "    # use -K instead of '-e ansible_become=false' when a task needs root (e.g. flatpak install)"
    ;;
  *)
    echo "    ./scripts/apply.sh ${HOST:-$DEFAULT}"
    echo "    # (passwordless sudo is set up by the playbook; use -K only on the first run)"
    ;;
esac
