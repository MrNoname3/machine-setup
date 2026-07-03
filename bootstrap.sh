#!/usr/bin/env bash
# Bootstrap a fresh machine so Ansible can take over.
#
# One-liner (interactive host menu; run as your normal user, NOT root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrNoname3/machine-setup/main/bootstrap.sh)"
# Non-interactive (pick the host up front):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrNoname3/machine-setup/main/bootstrap.sh)" -- laptop-old
#
# NB the `bash -c "$(curl ...)"` form (not `curl | bash`) keeps stdin attached
# to the terminal so the menu below can actually prompt.
#
# What it does (idempotent, safe to re-run):
#   1. Installs git + ansible the OS-appropriate way (apt on Debian/Mint,
#      Homebrew on Bazzite where git is preinstalled).
#   2. Clones (or fast-forwards) this repo into ~/Projects/machine-setup.
#   3. Lets you pick an inventory host and optionally runs the playbook for it
#      (first run uses -K: it asks your sudo password once).
#
# Overrides: REPO_URL / REPO_DIR env vars; first argument = inventory host
# (skips the menu and runs the playbook for it).
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/MrNoname3/machine-setup.git}"
REPO_DIR="${REPO_DIR:-$HOME/Projects/machine-setup}"
HOST="${1:-}"

msg() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "run as your normal user, not root (sudo is used where needed)"

# --- 1. OS detection + prerequisites -----------------------------------------
[ -r /etc/os-release ] || die "/etc/os-release not found — unsupported system"
. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *bazzite*)
    OS_FAMILY=bazzite
    msg "Bazzite detected — using Homebrew for ansible (git ships with the image)"
    if ! command -v brew >/dev/null 2>&1; then
      [ -x /home/linuxbrew/.linuxbrew/bin/brew ] \
        || die "Homebrew not found (expected on Bazzite at /home/linuxbrew/.linuxbrew)"
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
    command -v ansible-playbook >/dev/null 2>&1 || brew install ansible
    ;;
  *debian*|*ubuntu*|*linuxmint*)
    OS_FAMILY=debian
    msg "Debian-family detected — using apt"
    NEED=()
    command -v git >/dev/null 2>&1 || NEED+=(git)
    command -v ansible-playbook >/dev/null 2>&1 || NEED+=(ansible)
    if [ "${#NEED[@]}" -gt 0 ]; then
      sudo apt-get update -y
      sudo apt-get install -y "${NEED[@]}"
    else
      msg "git + ansible already installed"
    fi
    ;;
  *)
    die "unsupported distro '${PRETTY_NAME:-unknown}' — add a branch for it in bootstrap.sh"
    ;;
esac

# --- 2. Get the repo ----------------------------------------------------------
if [ -d "$REPO_DIR/.git" ]; then
  msg "Repo already at $REPO_DIR — fast-forwarding"
  # Explicit remote+branch: works even if the local branch has no upstream
  # tracking configured (e.g. after a history rewrite).
  git -C "$REPO_DIR" pull --ff-only origin main
else
  msg "Cloning into $REPO_DIR"
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR"
fi

# --- 3. Pick a host + optionally run the playbook -----------------------------
# Hosts come from inventory.ini, so new machines show up here automatically.
mapfile -t HOSTS < <(awk '!/^[[:space:]]*($|#|\[)/ {print $1}' "$REPO_DIR/inventory.ini" | sort -u)
[ "${#HOSTS[@]}" -gt 0 ] || die "no hosts found in inventory.ini"

# Suggest the host matching this OS as the default menu choice.
DEFAULT=""
case "$OS_FAMILY" in
  bazzite) DEFAULT=desktop-bazzite ;;
  debian)  DEFAULT=laptop-old ;;
esac

RUN=no
if [ -n "$HOST" ]; then
  printf '%s\n' "${HOSTS[@]}" | grep -qx "$HOST" || die "host '$HOST' not in inventory.ini"
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
  msg "Applying the playbook for '$HOST' (you will be asked for your sudo password once)"
  cd "$REPO_DIR"
  ansible-playbook -c local -l "$HOST" -K site.yml
fi

# --- 4. What to run day-to-day -------------------------------------------------
msg "Done. Day-to-day usage:"
echo "    cd $REPO_DIR && git pull --ff-only"
case "$OS_FAMILY" in
  bazzite)
    echo "    eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"   # if brew is not on PATH"
    echo "    ansible-playbook -c local -l ${HOST:-desktop-bazzite} -e ansible_become=false site.yml"
    echo "    # use -K instead of '-e ansible_become=false' when a task needs root (e.g. flatpak install)"
    ;;
  *)
    echo "    ansible-playbook -c local -l ${HOST:-laptop-old} site.yml"
    echo "    # (passwordless sudo is set up by the playbook; use -K only on the first run)"
    ;;
esac
