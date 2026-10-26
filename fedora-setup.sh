#!/usr/bin/env bash
#
# fedora-setup.sh — set up, update and maintain Fedora GNOME with one command
#
# Target:  Fedora 41+ (dnf5). Written on Fedora 44 Workstation / GNOME 50 for a
#          ThinkPad T14 Gen 1 AMD, but every hardware-specific step is detected
#          first and skipped on other machines, so it also works on plain
#          Fedora GNOME spins.
#
# Usage:
#   ./fedora-setup.sh                  set up a fresh install, or maintain it
#   ./fedora-setup.sh --dry-run        show every change, make none
#   ./fedora-setup.sh --yes            no confirmation prompt
#   ./fedora-setup.sh --quiet          only warnings and errors
#   ./fedora-setup.sh amd media apps   run only those stages
#   ./fedora-setup.sh --skip audio     run everything except audio
#   ./fedora-setup.sh health           read-only health report
#   ./fedora-setup.sh release          upgrade to the next Fedora release
#   ./fedora-setup.sh --help           this text
#
# Fresh install, nothing cloned yet:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Rev4N1/fedora-thinkpad-setup/main/fedora-setup.sh)
#
# Every stage checks what is already done and skips it, so the same plain run
# both installs and maintains. Re-running updates dnf, Flatpak, firmware and
# the GitHub-only apps, puts back drifted settings, checks the machine, and
# cleans up. It also updates itself from git before doing anything.
#
# Stages:
#   config     dnf tuning, optional hostname, install `fedora-setup` in ~/.local/bin
#   update     system upgrade, fwupd refresh
#   rpmfusion  RPM Fusion free/nonfree, AppStream data, OpenH264 repo
#   flatpak    Flathub (full repo), drop duplicate Fedora remotes
#   amd        AMD VA-API + Vulkan freeworld drivers (skipped if not AMD)
#   media      full ffmpeg, multimedia group, GStreamer codecs
#   apps       VS Code, Helium, Spotifast, Nuvio, Discord, archive tools
#   audio      EasyEffects, T14 Gen 1 speaker preset, service, autoload
#   vpn        import wireguard/*.conf into NetworkManager
#   gnome      GNOME preferences, extensions, terminal transparency
#   laptop     tuned, TRIM, boot, firmware, fingerprint, ThinkPad extras
#   sweep      final dnf/Flatpak/firmware update pass
#   health     read-only health report
#   cleanup    autoremove, journal, Flatpak runtimes, package cache
#
# Internal stage:
#   session    re-applies the desktop-only steps at the next login
#
# Optional stage (not part of a full run):
#   release    upgrade to the next Fedora release (dnf system-upgrade)
#
# Settings: edit the block at the top of this script — there is no config file.
# Logs: ~/.local/state/fedora-setup/logs/
# WireGuard: put *.conf in wireguard/ next to this script (git-ignored).
#
# Read this before you run it. Not official Fedora documentation.

set -Eeuo pipefail

VERSION="3.2"

# ---------------------------------------------------------------- settings ---

# Your settings. Edit them here: there is no separate config file.
CFG_HOSTNAME=""              # hostname to set; empty = leave it alone
CFG_BROWSER="helium"         # default browser on first install: helium | none
CFG_TOUCHPAD_SPEED="0.45"    # GNOME pointer speed, -1.0 (slow) .. 1.0 (fast)
CFG_AUDIO="auto"             # speaker profile: auto (T14 Gen 1 only) | off | force
CFG_EXTRA_PACKAGES=""        # extra dnf packages, space separated
REBOOT_PROMPT=1              # ask "reboot now?" when a new kernel waits: 1 | 0

# ------------------------------------------------------------------ state ---

DRY_RUN=0
ASSUME_YES=0
QUIET=0
SELF_UPDATE=1
NO_REBOOT=0

STAGES=()
SKIP_STAGES=()
ORIG_ARGS=("$@")

# Stages run by a plain invocation, in order. "session" is deliberately not in
# this list: it only makes sense after a graphical login and is scheduled by
# the script itself when a step needs a desktop session.
DEFAULT_STAGES=(config update rpmfusion flatpak amd media apps audio vpn gnome laptop sweep health cleanup)
EXTRA_STAGES=(session release)
ALL_STAGES=("${DEFAULT_STAGES[@]}" "${EXTRA_STAGES[@]}")

# Resolve the script's real path, following the ~/.local/bin/fedora-setup
# symlink back into the checkout so wireguard/ and git
# self-update all work from either entry point. Under `bash <(curl ...)` or
# `curl ... | bash` there is no file: main() then bootstraps a checkout.
SELF_PATH=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
  SCRIPT_DIR="$(dirname "$SELF_PATH")"
else
  SCRIPT_DIR="$PWD"
fi

REPO_URL="https://github.com/Rev4N1/fedora-thinkpad-setup.git"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-setup"
INSTALLED_PATH="${XDG_BIN_HOME:-$HOME/.local/bin}/fedora-setup"
FIRST_DONE="$STATE_DIR/first-setup.done"
FIRST_RUN=1
[[ -f "$FIRST_DONE" ]] && FIRST_RUN=0

# Set when a stage could not do its desktop-only work (no session bus), so the
# script can queue a one-shot autostart entry instead of asking you to do it.
SESSION_PENDING=0

# ---------------------------------------------------------------- plumbing ---

if [[ -t 1 ]]; then
  C_OK=$'\033[1;32m'; C_INFO=$'\033[1;34m'; C_WARN=$'\033[1;33m'
  C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'
else
  C_OK=''; C_INFO=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi

log()  { (( QUIET )) || printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()   { (( QUIET )) || printf '%s  ok%s %s\n'  "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s  !!%s %s\n'  "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s ERR%s %s\n'  "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }

step() { (( QUIET )) || printf '\n%s────── %s ──────%s\n' "$C_INFO" "$*" "$C_OFF"; }

# run CMD... — echoes then executes, or just echoes under --dry-run
run() {
  (( QUIET )) || printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_OFF"
  (( DRY_RUN )) && return 0
  "$@"
}

# run_sh 'shell string' — for commands needing brace expansion, globs or pipes
run_sh() {
  (( QUIET )) || printf '%s  $ %s%s\n' "$C_DIM" "$1" "$C_OFF"
  (( DRY_RUN )) && return 0
  bash -c "$1"
}

# report 'shell string' 'warning' — run a read-only check and only print its
# output, plus the warning, when it found something. Keeps re-runs quiet.
report() {
  (( QUIET )) || printf '%s  $ %s%s\n' "$C_DIM" "$1" "$C_OFF"
  (( DRY_RUN )) && return 0
  local out
  out="$(bash -c "$1" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
    warn "$2"
  else
    ok "nothing found"
  fi
}

have()      { command -v "$1" >/dev/null 2>&1; }
installed() { rpm -q "$1" >/dev/null 2>&1; }

# ask_yes PROMPT — a y/N question that still works after stdout/stderr have
# been piped through tee. The prompt is written straight to the controlling
# terminal, otherwise tee's buffering can swallow it and the script looks
# frozen while it waits for an answer nobody can see.
ask_yes() {
  local reply=""
  if [[ -r /dev/tty ]]; then
    read -rp "$1" reply </dev/tty 2>/dev/tty || reply=""
  else
    read -rp "$1" reply || reply=""
  fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

# contains 'haystack' 'needle'
# grep -q in a pipeline is dangerous under `set -o pipefail`: grep exits at the
# first match, the producer gets SIGPIPE, and the whole pipeline is reported as
# failed even though the match succeeded. Capture first, then test the string.
contains() { [[ $1 == *"$2"* ]]; }

# write_file PATH <<'EOF' ... — write a user file, honouring --dry-run.
write_file() {
  local path=$1
  if (( DRY_RUN )); then
    (( QUIET )) || printf '%s  $ write %s%s\n' "$C_DIM" "$path" "$C_OFF"
    cat >/dev/null
    return 0
  fi
  cat >"$path"
}

# write_root_file PATH <<'EOF' ... — same, but through sudo.
write_root_file() {
  local path=$1
  if (( DRY_RUN )); then
    (( QUIET )) || printf '%s  $ write %s%s\n' "$C_DIM" "$path" "$C_OFF"
    cat >/dev/null
    return 0
  fi
  sudo tee "$path" >/dev/null
}

# gset SCHEMA KEY VALUE — a GNOME preference for the *current user*.
# Never call this under sudo: it would write to root's dconf, not yours.
gset() {
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    warn "no session bus — skipping GNOME setting: $1 $2"
    return 0
  fi
  local schemas
  schemas="$(gsettings list-schemas 2>/dev/null || true)"
  if ! grep -qx "$1" <<<"$schemas"; then
    ok "schema $1 not on this system, skipping $2"
    return 0
  fi
  if ! gsettings writable "$1" "$2" >/dev/null 2>&1; then
    warn "not writable on this system, skipping: $1 $2"
    return 0
  fi
  run gsettings set "$1" "$2" "$3"
}

# Install only what is missing, so re-runs stay quiet and fast.
dnf_install() {
  local missing=() p
  for p in "$@"; do
    installed "$p" || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    ok "already installed: $*"
    return 0
  fi
  run sudo dnf install -y "${missing[@]}"
}

# Same, but a failure is a warning: one unavailable optional package must not
# stop a maintenance run.
dnf_try() {
  dnf_install "$@" || warn "could not install: $*"
}

# repo_enabled ID — compare against captured output, never a live pipe.
repo_enabled() {
  local list
  list="$(dnf repolist --enabled 2>/dev/null || true)"
  [[ $list == *"$1"* ]]
}

flatpak_installed() {
  local list
  list="$(flatpak list --app --columns=application 2>/dev/null || true)"
  [[ $list == *"$1"* ]]
}

flatpak_install() {
  local missing=() p
  for p in "$@"; do
    flatpak_installed "$p" || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    ok "flatpaks already installed: $*"
    return 0
  fi
  run sudo flatpak install -y --noninteractive --system flathub "${missing[@]}" \
    || run flatpak install -y --noninteractive --user flathub "${missing[@]}" \
    || warn "could not install Flatpaks: ${missing[*]}"
}

# gh_rpm NAME REPO ASSET_REGEX [INSTALLED_NAME_PREFIX]
# Install or upgrade an app that is only published as an RPM on GitHub Releases
# (no dnf repo, so 'dnf upgrade' never sees new versions). The installed release
# tag is remembered, so re-runs skip the download unless a newer release is out.
gh_rpm() {
  local pkg="$1" repo="$2" pattern="$3" prefix="${4:-$1}"
  local stamp="$STATE_DIR/$pkg.tag" json tag url namelist
  local -a dnf_args=()

  if ! json="$(curl -fsSL --max-time 30 "https://api.github.com/repos/$repo/releases/latest")"; then
    warn "could not reach GitHub for $pkg — skipping (try again later)"
    return 0
  fi
  tag="$(grep -m1 '"tag_name"' <<<"$json" | cut -d'"' -f4 || true)"
  url="$(grep -m1 -oE "https://[^\"]+/$pattern" <<<"$json" || true)"
  if [[ -z "$url" ]]; then
    warn "no RPM matching '$pattern' in $repo release ${tag:-?} — skipping $pkg"
    return 0
  fi

  # Lower-cased: upstream RPM names do not always match the repo's casing.
  namelist="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null || true)"
  if [[ ${namelist,,} == *"${prefix,,}"* &&"$(cat "$stamp" 2>/dev/null || true)" == "$tag" ]]; then
    ok "$pkg $tag is current"
    return 0
  fi

  # A locally downloaded RPM is unsigned; allow it for this one transaction only
  # so a signature-less GitHub build is not rejected by the localpkg check.
  dnf_args=(install -y --setopt=localpkg_gpgcheck=0 "$url")
  run sudo dnf "${dnf_args[@]}" || { warn "could not install $pkg $tag"; return 0; }
  (( DRY_RUN )) || printf '%s\n' "$tag" >"$stamp"
}

# ------------------------------------------------------------------- args ---

usage() {
  if [[ -f "$0" ]]; then
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); if (length($0)) print; next } NR > 1 { exit }' "$0"
  else
    printf '%s\n' "fedora-setup.sh — set up, update and maintain Fedora GNOME with one command"
  fi
}

valid_stage() {
  local s
  for s in "${ALL_STAGES[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

while (( $# )); do
  case "$1" in
    --dry-run|--check) DRY_RUN=1 ;;
    -y|--yes)          ASSUME_YES=1 ;;
    -q|--quiet)        QUIET=1 ;;
    --no-self-update)  SELF_UPDATE=0 ;;
    --no-reboot)       NO_REBOOT=1 ;;
    -h|--help)         usage; exit 0 ;;
    -V|--version)      printf 'fedora-setup %s\n' "$VERSION"; exit 0 ;;
    --skip)
      [[ $# -ge 2 ]] || die "--skip needs a stage name"
      IFS=, read -r -a _skips <<<"$2"
      for _s in "${_skips[@]}"; do
        valid_stage "$_s" || die "unknown stage in --skip: $_s"
        SKIP_STAGES+=("$_s")
      done
      shift ;;
    --skip=*)
      IFS=, read -r -a _skips <<<"${1#*=}"
      for _s in "${_skips[@]}"; do
        valid_stage "$_s" || die "unknown stage in --skip: $_s"
        SKIP_STAGES+=("$_s")
      done ;;
    --) shift; while (( $# )); do
          valid_stage "$1" || die "unknown stage: $1 (valid: ${ALL_STAGES[*]})"
          STAGES+=("$1"); shift
        done; break ;;
    -*) die "unknown flag: $1 (see --help)" ;;
    *)
      valid_stage "$1" || die "unknown stage: $1 (valid: ${ALL_STAGES[*]})"
      STAGES+=("$1") ;;
  esac
  shift
done

(( NO_REBOOT )) && REBOOT_PROMPT=0

# A plain run (no stage names given) is what marks the first setup as complete,
# even when some stages are skipped. Partial runs never do, so the one-time
# advice is not lost.
if (( ${#STAGES[@]} == 0 )); then
  STAGES=("${DEFAULT_STAGES[@]}")
  FULL_RUN=1
else
  FULL_RUN=0
fi

# Remove skipped stages from the selection.
if (( ${#SKIP_STAGES[@]} )); then
  _kept=()
  for _s in "${STAGES[@]}"; do
    _skip=0
    for _x in "${SKIP_STAGES[@]}"; do [[ "$_s" == "$_x" ]] && _skip=1; done
    (( _skip )) || _kept+=("$_s")
  done
  STAGES=("${_kept[@]}")
fi
(( ${#STAGES[@]} )) || die "every selected stage is skipped — nothing to do."

# Called from main() after self-update, so a restart into a newer script does
# not tee its output into a second log through the first one.
start_log() {
  (( DRY_RUN )) && return 0
  mkdir -p "$STATE_DIR/logs"
  LOG="$STATE_DIR/logs/$(date +%Y-%m-%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
  # Keep the 20 most recent logs. '|| true': with pipefail a glob that matches
  # only the log just created (or nothing yet) must not abort the run.
  # shellcheck disable=SC2012  # names are our own timestamps
  ls -1t "$STATE_DIR"/logs/*.log 2>/dev/null | tail -n +21 | xargs -r rm -f || true
}

wants() {
  local s
  for s in "${STAGES[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

# --------------------------------------------------------------- preflight ---

preflight() {
  step "Preflight"

  [[ $EUID -ne 0 ]] || die "run as your normal user, not root — the script calls sudo itself."
  have dnf || die "dnf not found. Is this actually Fedora?"
  [[ ! -e /run/ostree-booted ]] \
    || die "Atomic/ostree system (Silverblue etc.) — this script is for the dnf-based Workstation/GNOME spin."

  local ver major
  ver="$(rpm -E %fedora)"
  major="${ver%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    die "could not determine the Fedora release (rpm -E %fedora returned '$ver')."
  fi
  if (( major < 41 )); then
    die "Fedora $ver is too old: this script needs dnf5 (Fedora 41 or newer)."
  elif (( major != 44 )); then
    warn "written and tested on Fedora 44; detected Fedora $ver — package names may differ."
  else
    ok "Fedora 44 detected"
  fi

  local dnfver
  dnfver="$(dnf --version 2>/dev/null | head -n1 || true)"
  if [[ $dnfver == dnf5* ]]; then
    ok "dnf5 in use"
  else
    warn "dnf5 not detected ($dnfver) — 'config-manager setopt' may fail."
  fi

  local pci="" gpus=""
  have lspci && pci="$(lspci 2>/dev/null || true)"
  # grep -Ei here consumes all of lspci, so there is no SIGPIPE to fight with
  # under `set -o pipefail`; the word-boundary test then runs on a here-string.
  [[ -n "$pci" ]] && gpus="$(grep -Ei 'VGA|3D controller|Display' <<<"$pci" || true)"
  if grep -qiE '\b(amd|ati|radeon)\b' <<<"$gpus"; then
    ok "AMD GPU detected"
  else
    ok "no AMD GPU found — the 'amd' stage will skip itself"
  fi

  have curl || die "curl not found — it is needed to fetch the GitHub-only apps."
  have flock || die "flock not found (util-linux) — needed to prevent concurrent runs."

  if (( DRY_RUN )); then
    warn "DRY RUN — nothing will be changed."
  else
    log "Stages to run: ${STAGES[*]}"
    log "Logging to: $LOG"
  fi

  if (( ! DRY_RUN && ! ASSUME_YES )); then
    # This also covers a double-click or a .desktop launcher: there 'read'
    # gets EOF, and the window would close before the error could be read.
    if ! ask_yes "Proceed? [y/N] "; then
      die "aborted — nothing was changed.
     (no terminal? use --yes for unattended runs, or --dry-run to preview)"
    fi
  fi

  if (( ! DRY_RUN )); then
    # One run at a time: two overlapping runs would fight over dnf's lock.
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || die "another fedora-setup run is already in progress."
  fi

  # The login-time 'session' stage only touches your own settings; it must not
  # ask for sudo, because it runs from autostart with no terminal to answer.
  local s needs_root=0
  for s in "${STAGES[@]}"; do [[ "$s" == session ]] || needs_root=1; done

  if (( ! DRY_RUN && needs_root )); then
    # Cache sudo up front and keep it warm for the whole run.
    sudo -v || die "sudo is needed for these stages (run from a terminal, or as a user with sudo rights)."
    # '|| true' + 'trap - ERR': the loop inherits the ERR trap (set -E), and
    # a single failed refresh must not print a bogus "script failed".
    ( trap - ERR
      while true; do sudo -n true 2>/dev/null || true; sleep 60; kill -0 "$$" 2>/dev/null || exit 0; done ) &
    SUDO_KEEPALIVE=$!
    trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT
  fi
}

# Report the failing STAGE, not the line inside the run() helper where the
# error surfaces — otherwise every failure reads "line 46: $@", which says
# nothing about what actually broke.
on_err() {
  local code=$? cmd="$BASH_COMMAND" i stage=""
  for (( i = 0; i < ${#FUNCNAME[@]}; i++ )); do
    case "${FUNCNAME[i]}" in
      stage_*|preflight|self_update|bootstrap) stage="${FUNCNAME[i]}"; break ;;
    esac
  done
  printf '\n%s ERR%s %s failed (exit %d)\n' "$C_ERR" "$C_OFF" "${stage:-script}" "$code" >&2
  printf '%s ERR%s command: %s\n' "$C_ERR" "$C_OFF" "$cmd" >&2
  if [[ -n "$stage" && "$stage" == stage_* ]]; then
    printf '%s ERR%s fix it, then resume with: %s %s\n' \
      "$C_ERR" "$C_OFF" "$0" "${stage#stage_}" >&2
  fi
  exit "$code"
}
trap on_err ERR

# ------------------------------------------------------------ self-update ---

# Run without a file (`bash <(curl ...)` on a fresh install): get a real
# checkout first, then hand over to it. From then on everything — the script,
# wireguard/, self-update — lives in that one directory.
bootstrap() {
  local dest="$HOME/fedora-thinkpad-setup"
  [[ $EUID -ne 0 ]] || die "run as your normal user, not root — the script calls sudo itself."
  step "Bootstrap"
  if (( DRY_RUN )); then
    ok "would clone $REPO_URL into $dest and run it from there"
    exit 0
  fi
  have git || sudo dnf install -y git
  if [[ -d "$dest/.git" ]]; then
    ok "checkout already at $dest"
  else
    git clone --quiet "$REPO_URL" "$dest"
  fi
  ok "running $dest/fedora-setup.sh"
  # Give the new process the terminal as stdin: under `curl | bash` stdin is
  # still the rest of the downloaded script.
  if [[ -r /dev/tty ]]; then
    exec "$dest/fedora-setup.sh" "${ORIG_ARGS[@]}" </dev/tty
  fi
  exec "$dest/fedora-setup.sh" "${ORIG_ARGS[@]}"
}

# ~/.local/bin/fedora-setup is a symlink into the checkout, never a copy: a
# copy would look for wireguard/ in ~/.local/bin and could not
# update itself.
install_self() {
  local dest="$INSTALLED_PATH"
  if [[ -L "$dest" && "$(readlink -f "$dest")" == "$SELF_PATH" ]]; then
    ok "'fedora-setup' command points at this checkout"
  else
    run mkdir -p "$(dirname "$dest")"
    run ln -sfn "$SELF_PATH" "$dest"
  fi
  if ! contains ":${PATH:-}:" ":$(dirname "$dest"):"; then
    warn "$(dirname "$dest") is not in PATH yet — open a new terminal to use the 'fedora-setup' command"
  fi
}

# exec into the freshly updated copy, keeping the original flags. --yes is only
# forwarded if it was given: self-update runs *before* the confirmation prompt,
# so passing it unconditionally would skip the prompt on a first run (and could
# pull a newer script that then changes the machine unasked).
self_exec() {
  local -a again=(--no-self-update)
  (( ASSUME_YES )) && again+=(--yes)
  exec "$SELF_PATH" "${again[@]}" "${ORIG_ARGS[@]}"
}

# Pull a newer script before doing anything else. A plain run therefore both
# maintains the machine and keeps the tool itself current.
self_update() {
  (( SELF_UPDATE )) || return 0
  (( DRY_RUN )) && { ok "would check for a newer script"; return 0; }
  [[ -n "$SELF_PATH" ]] || return 0

  if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
    ok "not a git checkout — self-update off (clone the repo to get it)"
    return 0
  fi
  have git || { warn "git not found — skipping self-update"; return 0; }
  local before after
  before="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
  # GIT_TERMINAL_PROMPT=0: never hang on a credential prompt nobody can see.
  if ! GIT_TERMINAL_PROMPT=0 git -C "$SCRIPT_DIR" pull --ff-only --quiet >/dev/null 2>&1; then
    warn "self-update failed (offline or local changes) — continuing with this copy"
    return 0
  fi
  after="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$after" && "$before" != "$after" ]]; then
    ok "script updated (${before:0:7}..${after:0:7}) — restarting it"
    self_exec
  fi
  ok "script is up to date"
}

# ------------------------------------------------------------ 1. dnf config ---

stage_config() {
  step "1. dnf, hostname, installed command"

  # dnf5's config-manager is idempotent and writes a proper [main] section,
  # unlike appending to /etc/dnf/dnf.conf by hand on every run.
  run sudo dnf config-manager setopt max_parallel_downloads=10 installonly_limit=2

  if [[ -n "$CFG_HOSTNAME" ]]; then
    local current
    current="$(hostnamectl --static 2>/dev/null || true)"
    if [[ "$current" == "$CFG_HOSTNAME" ]]; then
      ok "hostname already '$CFG_HOSTNAME'"
    else
      run sudo hostnamectl set-hostname "$CFG_HOSTNAME"
    fi
  else
    ok "hostname left alone (set CFG_HOSTNAME at the top of the script to change it)"
  fi

  install_self

  if [[ -n "$CFG_EXTRA_PACKAGES" ]]; then
    local -a extra
    read -r -a extra <<<"$CFG_EXTRA_PACKAGES"
    dnf_try "${extra[@]}"
  fi
}

# --------------------------------------------------------------- 2. update ---

stage_update() {
  step "2. System + firmware update"

  run sudo dnf upgrade --refresh -y

  # Firmware is fetched here and installed once, in the sweep stage. Laptop
  # firmware updates are the ones that actually matter — battery, charging,
  # thermals and EC bugs all ship as fwupd payloads, and Lenovo publishes
  # ThinkPad BIOS updates to LVFS. Best-effort: some devices expose nothing.
  dnf_try fwupd
  run_sh "sudo fwupdmgr refresh --force >/dev/null 2>&1 || true"
}

# ----------------------------------------------------------- 3. rpm fusion ---

stage_rpmfusion() {
  step "3. RPM Fusion"

  if installed rpmfusion-free-release && installed rpmfusion-nonfree-release; then
    ok "RPM Fusion already enabled"
  else
    run_sh 'sudo dnf install -y \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"'
  fi

  # Since dnf5 (F41+) RPM Fusion can no longer extend Fedora's comps groups,
  # so the AppStream metadata must be installed explicitly for GNOME Software.
  # Not fatal: only the GUI catalogue is affected.
  dnf_try rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data

  # Cisco OpenH264 repo — dnf5 syntax. The old '--set-enabled' form is gone.
  run sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1 \
    || warn "could not enable the OpenH264 repo — openh264 will be skipped"

  # No 'dnf upgrade' here: the sweep stage updates everything, RPM Fusion
  # packages included, once all repos are in place.
}

# -------------------------------------------------------------- 4. flatpak ---

flatpak_remote_scope() {
  local remote=$1 scope list
  for scope in system user; do
    list="$(flatpak remotes --"$scope" --columns=name 2>/dev/null || true)"
    if grep -qx -- "$remote" <<<"$list"; then
      printf '%s\n' "$scope"
      return 0
    fi
  done
  return 1
}

stage_flatpak() {
  step "4. Flathub"

  dnf_install flatpak

  # Fedora's own remotes duplicate and shadow Flathub apps. Remove them, but
  # never orphan an app that was installed from one.
  local r scope origins
  origins="$(flatpak list --app --columns=origin 2>/dev/null || true)"
  for r in fedora fedora-testing; do
    if ! scope="$(flatpak_remote_scope "$r")"; then
      ok "remote '$r' not present"
      continue
    fi
    if grep -qx -- "$r" <<<"$origins"; then
      warn "remote '$r' still provides installed Flatpaks — leaving it enabled"
      continue
    fi
    if [[ "$scope" == system ]]; then
      run sudo flatpak remote-delete --force --system "$r"
    else
      run flatpak remote-delete --force --user "$r"
    fi
  done

  # The stock Fedora remote is filtered to a handful of apps. Adding Flathub
  # and clearing the filter is what actually gives you the full repository.
  local flathub_scope=""
  flathub_scope="$(flatpak_remote_scope flathub || true)"
  if [[ "$flathub_scope" == system ]]; then
    ok "flathub remote already present"
  elif [[ "$flathub_scope" == user ]]; then
    ok "flathub remote already present (user scope)"
  else
    run sudo flatpak remote-add --if-not-exists --system flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo
    flathub_scope=system
  fi
  # A user-scoped remote has no system filter to clear; skip it there.
  if [[ "$flathub_scope" == system ]]; then
    run sudo flatpak remote-modify --system --no-filter --enable flathub || \
      warn "could not clear the Flathub filter (older flatpak?)"
  fi

  # No 'flatpak update' here: the sweep stage updates both scopes.
}

# --------------------------------------------------------- 5. amd graphics ---

amd_gpu() {
  local pci="" gpus=""
  have lspci && pci="$(lspci 2>/dev/null || true)"
  [[ -n "$pci" ]] && gpus="$(grep -Ei 'VGA|3D controller|Display' <<<"$pci" || true)"
  grep -qiE '\b(amd|ati|radeon)\b' <<<"$gpus"
}

stage_amd() {
  step "5. AMD graphics (Vulkan + VA-API)"

  if ! amd_gpu; then
    ok "not an AMD GPU — skipping VA-API/Vulkan freeworld drivers"
    return 0
  fi

  # mesa-vulkan-drivers is deliberately NOT in this list. It is already on a
  # Workstation install, and after the freeworld swap below it is *replaced*
  # by mesa-vulkan-drivers-freeworld — so asking for it by name on a re-run
  # hits a package conflict, and dnf then satisfies the request with the i686
  # build, dragging in ~350 MB of 32-bit libraries.
  dnf_try vulkan-loader vulkan-tools mesa-libGLU libva-utils

  # Fedora 41+ moved VA-API back into mesa-dri-drivers, so the old
  # 'dnf swap mesa-va-drivers ...' fails: install the freeworld driver
  # alongside instead.
  dnf_try mesa-va-drivers-freeworld

  # Vulkan is still a genuine swap, per RPM Fusion's Howto/Multimedia.
  # Three states so re-runs are safe.
  if installed mesa-vulkan-drivers-freeworld; then
    ok "mesa-vulkan-drivers-freeworld already installed — nothing to swap"
  elif installed mesa-vulkan-drivers; then
    run sudo dnf swap -y mesa-vulkan-drivers mesa-vulkan-drivers-freeworld \
      || warn "Vulkan freeworld swap failed — this is usually a temporary mesa/RPM Fusion version mismatch; the next run retries it"
  else
    # Neither present (unusual) — install freeworld directly rather than
    # pulling in the stock driver only to swap it straight back out.
    dnf_try mesa-vulkan-drivers-freeworld
  fi

  # Guard against the 32-bit stack sneaking in via a conflict fallback.
  if installed mesa-vulkan-drivers.i686; then
    warn "mesa-vulkan-drivers.i686 is installed — only needed for 32-bit games or Wine."
    warn "remove it with:  sudo dnf remove mesa-vulkan-drivers.i686 && sudo dnf autoremove"
  fi

  # Deliberately omitted:
  #   - the .i686 freeworld libraries: only needed for 32-bit Steam/Wine/Proton.
  #   - mesa-vdpau-drivers-freeworld: VDPAU is legacy, and modern GNOME/Wayland
  #     desktops go through VA-API.
}

# ---------------------------------------------------------------- 6. media ---

stage_media() {
  step "6. Codecs and hardware acceleration"

  # Fedora ships the codec-stripped ffmpeg-free; swap in the full RPM Fusion build.
  if installed ffmpeg; then
    ok "full ffmpeg already installed"
  elif ! run sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing; then
    warn "ffmpeg swap failed — trying a direct install instead"
    run sudo dnf install -y --allowerasing ffmpeg || warn "could not install the full ffmpeg build"
  fi

  # 'install', not the old 'groupupdate' — that subcommand is gone in dnf5.
  # Once installed, its packages update with the sweep stage, so skip the slow
  # group resolve on re-runs. Fall back to the explicit list if the group is
  # unavailable (comps data missing, or a minimal spin).
  local groups
  groups="$(dnf group list --installed 2>/dev/null || true)"
  if grep -qw multimedia <<<"$groups"; then
    ok "@multimedia group already installed"
  else
    run_sh 'sudo dnf install -y @multimedia \
        --setopt="install_weak_deps=False" \
        --exclude=PackageKit-gstreamer-plugin' \
      || dnf_try gstreamer1-plugins-good gstreamer1-plugins-bad-free \
                 gstreamer1-plugins-base gstreamer1-plugins-good-extras
  fi

  # dnf5 cannot pull RPM Fusion packages into Fedora's groups (see stage 3),
  # so the patent-encumbered GStreamer plugins — what GNOME apps use for
  # H.264/H.265/AAC — have to be asked for by name.
  dnf_try gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly

  dnf_try libva libva-utils

  # Cisco OpenH264 (repo enabled in stage 3) for GStreamer apps. Helium is
  # Chromium-based and brings its own codecs, so it does not need this.
  dnf_try openh264 gstreamer1-plugin-openh264
}

# ----------------------------------------------------------------- 7. apps ---

stage_apps() {
  step "7. Applications"

  log "Archive + AppImage support"
  dnf_try p7zip p7zip-plugins unrar fuse fuse-libs

  log "Visual Studio Code"
  if installed code; then
    ok "code already installed"
  elif run sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc; then
    write_root_file /etc/yum.repos.d/vscode.repo <<'REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO
    dnf_try code
  else
    warn "could not import the Microsoft signing key — skipping VS Code"
  fi

  log "Desktop integration tools"
  dnf_try xdg-utils

  log "Helium browser"
  # Official COPR from imput (the Helium devs). Helium deliberately ships no
  # Flatpak — Chromium's sandbox cannot work inside one. Being a dnf repo,
  # it updates with every 'dnf upgrade' from here on.
  local helium_was_installed=0
  installed helium-bin && helium_was_installed=1
  if repo_enabled 'imput:helium'; then
    ok "Helium COPR already enabled"
  else
    run sudo dnf copr enable -y imput/helium || warn "could not enable the Helium COPR"
  fi
  dnf_try helium-bin

  # Make it the default browser — only on first install, so a later choice of
  # yours is never overridden by a maintenance run.
  if (( ! helium_was_installed )); then
    case "$CFG_BROWSER" in
      helium)
        run_sh 'if command -v xdg-settings >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
                  d=$(compgen -G "/usr/share/applications/*helium*.desktop" | head -n1)
                  [[ -n $d ]] && xdg-settings set default-web-browser "$(basename "$d")"
                fi' || true ;;
      none)
        ok "default browser left alone (CFG_BROWSER=none)" ;;
      *)
        warn "unknown CFG_BROWSER '$CFG_BROWSER' — leaving the default browser alone" ;;
    esac
  fi

  log "Spotifast + Nuvio (GitHub releases)"
  # Neither has a dnf repo or Flathub listing, so 'dnf upgrade' cannot update
  # them. gh_rpm checks for a newer release on every run instead — this is why
  # re-running the script is how they stay updated.
  # Spotifast needs Spotify Premium to play (free accounts can only browse).
  # Nuvio is alpha software — expect frequent releases.
  gh_rpm spotifast crmne/spotifast          'spotifast-[0-9.]+-[0-9]+\.x86_64\.rpm' spotifast
  gh_rpm nuvio     NuvioMedia/NuvioDesktop  'Nuvio-Linux-x86_64-[^"/]+\.rpm'          nuvio

  log "Discord"
  # Flatpak: Discord ships no Fedora package, and its tarball self-updates in a
  # way that breaks under a package manager.
  flatpak_install com.discordapp.Discord
}

# ---------------------------------------------------------------- 8. audio ---

# Impulse responses recorded from the T14 Gen 1's Windows Dolby profiles,
# from github.com/shuhaowu/linux-thinkpad-speaker-improvements. Applied with
# EasyEffects' convolver, they get rid of most of the tinny, hollow sound the
# speakers have on Linux.
SPEAKER_IRS_REPO="shuhaowu/linux-thinkpad-speaker-improvements"
SPEAKER_IRS_MODEL="ThinkPadT14Gen1"
SPEAKER_IRS=(DolbyMusicBalanced DolbyMovieBalanced DolbyVoiceBalanced DolbyGameBalanced)
SPEAKER_PRESET="ThinkPad T14 Speakers"
FLAT_PRESET="Flat (headphones)"

is_t14g1() {
  local v
  v="$(cat /sys/class/dmi/id/product_version 2>/dev/null || true)"
  contains "$v" "ThinkPad T14 Gen 1"
}

ee_preset_json() {
  cat <<'JSON'
{
    "output": {
        "blocklist": [],
        "plugins_order": ["convolver#0", "limiter#0"],
        "convolver#0": {
            "bypass": false,
            "input-gain": 0.0,
            "output-gain": 0.0,
            "kernel-name": "DolbyMusicBalanced",
            "ir-width": 100,
            "autogain": true
        },
        "limiter#0": {
            "bypass": false,
            "input-gain": 0.0,
            "output-gain": 0.0,
            "mode": "Herm Thin",
            "oversampling": "None",
            "dithering": "None",
            "threshold": -1.0,
            "attack": 5.0,
            "release": 5.0,
            "lookahead": 5.0,
            "stereo-link": 100.0,
            "gain-boost": true
        }
    }
}
JSON
}

download_irs() {
  local data="$HOME/.local/share/easyeffects" name src local_dir
  local_dir="$SCRIPT_DIR/linux-thinkpad-speaker-improvements-main/$SPEAKER_IRS_MODEL"

  for name in "${SPEAKER_IRS[@]}"; do
    if [[ -s "$data/irs/$name.irs" ]]; then
      ok "$name.irs already in place"
      continue
    fi
    if [[ -s "$local_dir/$name.irs" ]]; then
      run cp "$local_dir/$name.irs" "$data/irs/$name.irs"
      continue
    fi
    src="https://raw.githubusercontent.com/$SPEAKER_IRS_REPO/main/$SPEAKER_IRS_MODEL/$name.irs"
    if (( DRY_RUN )); then
      run_sh "curl -fsSL -o '$data/irs/$name.irs' '$src'"
    elif ! curl -fsSL --max-time 60 -o "$data/irs/$name.irs" "$src" \
         || [[ ! -s "$data/irs/$name.irs" ]]; then
      rm -f "$data/irs/$name.irs"
      warn "could not download $name.irs"
    fi
  done
}

# Write a preset only if it does not exist yet, so tweaks made in the
# EasyEffects UI survive maintenance runs.
ee_write_preset() {
  local path=$1
  if [[ -f "$path" ]]; then
    ok "preset exists — leaving your version alone: $(basename "$path")"
    return 0
  fi
  ee_preset_json | write_file "$path"
  (( DRY_RUN )) || ok "wrote $(basename "$path")"
}

ee_write_flat_preset() {
  local data="$HOME/.local/share/easyeffects"
  local path="$data/output/$FLAT_PRESET.json"
  [[ -f "$path" ]] && return 0
  write_file "$path" <<'JSON'
{
    "output": {
        "blocklist": [],
        "plugins_order": []
    }
}
JSON
}

# Create an autoload profile: EasyEffects reads ~/.local/share/easyeffects/
# autoload/output/<device>:<route>.json when the output device or route
# changes, and loads the named preset for it. This is what makes switching
# between speakers and headphones automatic — no GUI step.
_ee_autoload_one() {
  local data=$1 device=$2 devdesc=$3 route=$4 preset
  local file
  if [[ "$route" == *[Ss]peaker* || "$route" == *[Ii]nternal* ]]; then
    preset="$SPEAKER_PRESET"
  else
    preset="$FLAT_PRESET"
  fi
  file="$data/autoload/output/${device//\//_}:${route//\//_}.json"
  [[ -f "$file" ]] && return 0
  write_file "$file" <<JSON
{
    "device": "$device",
    "device-description": "$devdesc",
    "device-profile": "$route",
    "preset-name": "$preset"
}
JSON
}

ee_write_autoload() {
  local data="$HOME/.local/share/easyeffects"
  local list line name="" desc="" rest pdesc written=0

  if ! have pactl; then
    warn "pactl not found — skipping EasyEffects autoload profiles"
    return 1
  fi
  if ! list="$(pactl list sinks 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$list" ]] || return 1

  while IFS= read -r line; do
    if [[ "$line" == 'Sink #'* ]]; then
      name=""; desc=""
    elif [[ "$line" == $'\t'Name:* ]]; then
      name="${line#*Name: }"
    elif [[ "$line" == $'\t'Description:* ]]; then
      desc="${line#*Description: }"
    elif [[ "$line" == $'\t\t'*": "*" (type: "* ]]; then
      # A port line: "<port-name>: <route description> (type: ...)". The
      # ' (type: ' test is what tells it apart from other indented keys such as
      # the "Formats:" block, whose entries have no separator at all.
      rest="${line#$'\t\t'}"
      pdesc="${rest#*: }"
      pdesc="${pdesc%% (type:*}"
      [[ -n "$name" && -n "$pdesc" ]] || continue
      _ee_autoload_one "$data" "$name" "$desc" "$pdesc"
      written=$(( written + 1 ))
    fi
  done <<<"$list"

  (( written )) || return 1
  ok "autoload profiles ready for $written output route(s)"
}

ee_write_service() {
  local dir="$HOME/.config/systemd/user"
  local unit="$dir/easyeffects.service"
  local bin
  bin="$(command -v easyeffects 2>/dev/null || echo /usr/bin/easyeffects)"

  run mkdir -p "$dir"
  if [[ -f "$unit" ]] && ! grep -q -- '--service-mode' "$unit"; then
    # Never overwrite a unit you wrote yourself unless it is clearly not ours.
    ok "keeping your existing easyeffects.service"
    return 0
  fi
  write_file "$unit" <<EOF
[Unit]
Description=EasyEffects (service mode)
Documentation=man:easyeffects(1)
PartOf=graphical-session.target
After=pipewire.service wireplumber.service

[Service]
Type=simple
ExecStart=$bin --service-mode --hide-window
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
}

# Returns 1 when there is no desktop session yet, so the caller can queue the
# work for the next login instead of telling the user to do it by hand.
audio_session_start() {
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    return 1
  fi
  systemctl --user daemon-reload || return 1
  systemctl --user enable easyeffects.service || return 1

  # Only start it when it is not already running: restarting on every
  # maintenance pass would cut the audio for a moment for no reason.
  local started=0
  if ! systemctl --user is-active --quiet easyeffects.service; then
    if systemctl --user start easyeffects.service; then
      started=1
    else
      warn "EasyEffects service did not start — check 'systemctl --user status easyeffects'"
      return 0
    fi
  fi

  # A freshly started instance has no preset loaded yet. `--load-preset` is
  # handled by the running (primary) instance over its local socket, which is
  # exactly what a second invocation is for. Doing this only on a fresh start
  # means maintenance runs never overwrite a preset you picked yourself.
  if (( started )); then
    sleep 2
    easyeffects --load-preset "$SPEAKER_PRESET" >/dev/null 2>&1 || true
  fi
  return 0
}

audio_wanted() {
  case "$CFG_AUDIO" in
    off)   return 1 ;;
    force) return 0 ;;
    *)     is_t14g1 ;;
  esac
}

stage_audio() {
  step "8. Audio (EasyEffects + T14 Gen 1 speaker profile)"

  if ! audio_wanted; then
    ok "speaker profile not applied (CFG_AUDIO=$CFG_AUDIO, auto = ThinkPad T14 Gen 1 only)"
    return 0
  fi

  dnf_install easyeffects

  local data="$HOME/.local/share/easyeffects"
  run mkdir -p "$data/irs" "$data/output" "$data/autoload/output"

  log "Impulse response files"
  download_irs

  log "Output presets"
  ee_write_preset "$data/output/$SPEAKER_PRESET.json"
  ee_write_flat_preset

  log "Service + autoload"
  ee_write_service
  ee_write_autoload || warn "could not read the audio devices — autoload will be retried at next login"

  if ! audio_session_start; then
    SESSION_PENDING=1
  fi

  if (( FIRST_RUN )); then
    cat <<EOT

  The speaker profile is applied automatically: EasyEffects runs as a user
  service, loads "$SPEAKER_PRESET" for the internal speakers and a flat
  preset for headphones/HDMI. Swap Music / Movie / Voice / Game any time in
  the Convolver, or edit the preset in the EasyEffects window — re-runs never
  overwrite it.

EOT
  fi
}

# ------------------------------------------------------------------ 9. vpn ---

stage_vpn() {
  step "9. WireGuard"

  # NetworkManager talks to the kernel's built-in WireGuard directly and reads
  # the .conf files itself, so no extra package is needed. Tunnels show up in
  # GNOME's network menu. (wireguard-tools would only add the 'wg' debug CLI.)
  local dir="$SCRIPT_DIR/wireguard" f name

  if ! compgen -G "$dir/*.conf" >/dev/null; then
    ok "no tunnel configs in $dir — drop *.conf files there to import them"
    return 0
  fi

  local existing
  existing="$(nmcli -g NAME connection show 2>/dev/null || true)"

  # Import each tunnel once. The connection takes the file's name, so keep
  # names to 15 characters or fewer (the Linux interface-name limit).
  for f in "$dir"/*.conf; do
    name="$(basename "$f" .conf)"
    if grep -qxF -- "$name" <<<"$existing"; then
      ok "tunnel '$name' already imported"
    else
      run sudo nmcli connection import type wireguard file "$f"
    fi
    # The files hold private keys: only nag when they are readable by others.
    if [[ -n "$(find "$f" -maxdepth 0 -perm /077 -print -quit 2>/dev/null)" ]]; then
      warn "$f is readable by others — it holds a private key: chmod 600 '$f'"
    fi
  done
}

# --------------------------------------------------------------- 10. gnome ---

gnome_extension_enable() {
  local uuid=$1 current
  current="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '@as []')"
  if contains "$current" "'$uuid'"; then
    ok "extension already enabled: $uuid"
    return 0
  fi
  if [[ "$current" == "@as []" || "$current" == "[]" ]]; then
    current="['$uuid']"
  else
    current="${current%]}, '$uuid']"
  fi
  run gsettings set org.gnome.shell enabled-extensions "$current"
  if have gnome-extensions; then
    run_sh "gnome-extensions enable '$uuid' 2>/dev/null || true"
  fi
  return 0
}

not_gnome() {
  [[ -n "${XDG_CURRENT_DESKTOP:-}" && "${XDG_CURRENT_DESKTOP:-}" != *GNOME* ]]
}

stage_gnome() {
  step "10. GNOME"

  dnf_try gnome-tweaks
  flatpak_install com.mattjakeman.ExtensionManager

  log "Extensions: Dash to Dock + Blur my Shell + Caffeine"
  # All three are packaged by Fedora, so use those rather than
  # extensions.gnome.org: they are built against the shell Fedora ships, and
  # update with the system instead of breaking on a shell upgrade.
  dnf_try \
    gnome-shell-extension-dash-to-dock \
    gnome-shell-extension-blur-my-shell \
    gnome-shell-extension-caffeine

  if not_gnome; then
    ok "desktop is ${XDG_CURRENT_DESKTOP}, not GNOME — skipping GNOME settings"
    return 0
  fi

  if ! gnome_settings; then
    ok "no desktop session — GNOME preferences queued for your next login"
    SESSION_PENDING=1
  fi

  (( FIRST_RUN )) || return 0
  cat <<'EOT'

  Log out and back in once if this was the first run: GNOME cannot load new
  shell extensions live on Wayland. Everything else is already applied.

EOT
}

# The per-user part of the GNOME stage: needs a session bus, never sudo, so
# the login-time 'session' stage can run it on its own. Returns 1 without a
# session so the caller can queue it.
gnome_settings() {
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 1
  have gsettings || return 1

  local schemas
  schemas="$(gsettings list-schemas 2>/dev/null || true)"

  log "Touchpad"
  # GNOME ships tap-to-click OFF by default, which surprises most laptop users.
  gset org.gnome.desktop.peripherals.touchpad tap-to-click true
  gset org.gnome.desktop.peripherals.touchpad natural-scroll true
  # Pointer speed runs -1.0 (slowest) .. 1.0 (fastest); 0.0 is the default.
  gset org.gnome.desktop.peripherals.touchpad speed "$CFG_TOUCHPAD_SPEED"

  log "Desktop"
  gset org.gnome.desktop.interface show-battery-percentage true
  gset org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'

  log "Night Light"
  gset org.gnome.settings-daemon.plugins.color night-light-enabled true
  gset org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
  # This key is a uint32, so the type has to be stated explicitly.
  gset org.gnome.settings-daemon.plugins.color night-light-temperature 'uint32 3700'

  log "Keyboard"
  # Repeat delay in ms before a held key starts repeating (GNOME default 500).
  # 250 is the "short" end of the Settings slider without being twitchy.
  gset org.gnome.desktop.peripherals.keyboard delay 'uint32 250'
  gset org.gnome.desktop.peripherals.keyboard repeat-interval 'uint32 30'

  log "Extensions"
  if grep -qx 'org.gnome.shell' <<<"$schemas"; then
    gset org.gnome.shell disable-user-extensions false
    gnome_extension_enable dash-to-dock@micxgx.gmail.com
    gnome_extension_enable blur-my-shell@aunetx
    gnome_extension_enable caffeine@patapon.info
  fi

  # Ptyxis is the default GNOME terminal since F41. The widely-copied
  # transparency snippet relies on $PTYXIS_PROFILE, which only exists *inside*
  # a running Ptyxis — so resolve the default profile UUID properly instead.
  if grep -qx 'org.gnome.Ptyxis' <<<"$schemas"; then
    local uuid
    uuid="$(gsettings get org.gnome.Ptyxis default-profile-uuid 2>/dev/null || true)"
    uuid="${uuid//\'/}"
    uuid="${uuid//\"/}"
    if [[ -n "$uuid" ]]; then
      run gsettings set \
        "org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$uuid/" opacity 0.90
    else
      warn "could not resolve the Ptyxis default profile; skipping transparency."
    fi
  else
    ok "Ptyxis not available in this session — skipping terminal transparency"
  fi
  return 0
}

# -------------------------------------------------------------- 11. laptop ---

stage_laptop() {
  step "11. Laptop (power, SSD, firmware, boot)"

  log "Power management"
  # Fedora 41+ replaced power-profiles-daemon with tuned + the tuned-ppd
  # shim, so GNOME's power slider talks to tuned now. TLP drives the same
  # kernel knobs and the two fight if both are running.
  if installed tlp; then
    warn "TLP is installed and conflicts with tuned-ppd on Fedora 44."
    warn "to return to Fedora's default: sudo dnf remove tlp tlp-rdw"
  else
    ok "TLP not installed (good — tuned owns power management here)"
  fi

  dnf_try tuned tuned-ppd
  run sudo systemctl enable --now tuned || warn "could not enable tuned"
  run_sh "tuned-adm active    || true"
  run_sh "tuned-adm recommend || true"

  # Report the cpufreq driver. On a ThinkPad T14 Gen 1 AMD (Renoir) this WILL
  # say 'acpi-cpufreq', not 'amd-pstate-epp': Lenovo's firmware on T14 Gen 1-3
  # AMD never exposed the ACPI _CPC object, so amd-pstate cannot bind and the
  # kernel logs "_CPC in PCC is not supported". That is a firmware limitation,
  # not a misconfiguration — adding amd_pstate=active to the kernel cmdline
  # does not fix it. tuned still manages governors fine on acpi-cpufreq.
  run_sh "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || true"

  log "SSD TRIM"
  local fstrim_state
  fstrim_state="$(systemctl is-enabled fstrim.timer 2>/dev/null || true)"
  if [[ "$fstrim_state" == "enabled" ]]; then
    ok "fstrim.timer already enabled"
  else
    run sudo systemctl enable --now fstrim.timer || warn "could not enable fstrim.timer"
  fi

  log "Boot time"
  # NetworkManager-wait-online holds boot until the network is fully up. It
  # only matters for servers mounting network shares at boot; on a laptop it
  # just adds seconds (more on Wi-Fi). WireGuard via NetworkManager does not
  # need it either.
  if [[ "$(systemctl is-enabled NetworkManager-wait-online.service 2>/dev/null || true)" == "enabled" ]]; then
    run sudo systemctl disable NetworkManager-wait-online.service || warn "could not disable NetworkManager-wait-online"
  else
    ok "NetworkManager-wait-online already disabled"
  fi

  log "Swap (Fedora uses zram by default — no swap partition needed)"
  run_sh "zramctl || true"

  log "SSD health tool"
  dnf_try smartmontools

  # --- ThinkPad-specific ---------------------------------------------------
  local model
  model="$(cat /sys/class/dmi/id/product_version 2>/dev/null || true)"
  if ! contains "$model" "ThinkPad"; then
    ok "not a ThinkPad (${model:-unknown}) — skipping ThinkPad extras"
    return 0
  fi

  log "ThinkPad detected: $model"

  local thr=/sys/class/power_supply/BAT0/charge_control_end_threshold
  if [[ -r $thr ]]; then
    ok "battery charge limit: $(<"$thr")% (left at 100% by default)"
    if (( FIRST_RUN )); then
      ok "to cap later: echo 80 | sudo tee $thr"
      ok "(that resets on reboot — it needs a systemd unit to persist)"
    fi
  fi

  # T14 Gen 1 AMD exposes both s2idle and deep S3, but which one is active is
  # decided by the BIOS "Sleep State" setting (Linux = S3, Windows = s2idle).
  # S3 uses far less battery in suspend; it cannot be changed from userspace.
  if grep -q '\[deep\]' /sys/power/mem_sleep 2>/dev/null; then
    ok "suspend uses deep sleep (S3)"
  else
    warn "suspend is not using deep sleep: $(cat /sys/power/mem_sleep 2>/dev/null || echo '?')"
    warn "set BIOS > Config > Power > Sleep State to 'Linux' for much lower battery drain while suspended."
  fi

  log "Fingerprint reader"
  dnf_try fprintd fprintd-pam
  # No 'systemctl enable fprintd': the unit is static (no [Install] section)
  # because it is D-Bus activated — it starts on demand and exits when idle.

  # Enabling the PAM feature costs nothing and means the first finger you
  # enroll is already usable for login and sudo. 'authselect current' is
  # checked first because enable-feature is not idempotent on older releases.
  local cur enrolled
  cur="$(authselect current 2>/dev/null || true)"
  if ! contains "$cur" "with-fingerprint"; then
    run sudo authselect enable-feature with-fingerprint \
      || warn "could not enable the fingerprint PAM feature (authselect)"
  fi

  enrolled="$(fprintd-list "$USER" 2>/dev/null || true)"
  if grep -q ' - #[0-9]' <<<"$enrolled"; then
    ok "fingerprint enrolled and enabled for login/sudo"
  else
    warn "no finger enrolled yet — this one needs your finger on the reader:"
    warn "  fprintd-enroll"
  fi
}

# -------------------------------------------------------------- 12. session ---

# Everything that needs a live desktop session is queued here. The main run
# writes a one-shot autostart entry when it cannot do this work itself, so the
# user never has to run anything manually after the first reboot.
schedule_session_finalize() {
  if (( DRY_RUN )); then
    ok "would queue the desktop-only steps for the next login"
    return 0
  fi

  local runner=""
  if [[ -n "$SELF_PATH" ]]; then
    runner="$SELF_PATH"
  elif [[ -x "$HOME/.local/bin/fedora-setup" ]]; then
    runner="$HOME/.local/bin/fedora-setup"
  else
    warn "cannot queue the desktop-only steps: no script path to run at login"
    return 0
  fi

  local wrapper="$STATE_DIR/finish-session.sh"
  local entry="$HOME/.config/autostart/fedora-setup-session.desktop"

  mkdir -p "$STATE_DIR" "$(dirname "$entry")"
  cat >"$wrapper" <<EOF
#!/usr/bin/env bash
# Written by fedora-setup.sh — applies the desktop-only steps once, then goes away.
exec $(printf '%q' "$runner") session --yes --quiet --no-self-update
EOF
  chmod 0755 "$wrapper"

  cat >"$entry" <<EOF
[Desktop Entry]
Type=Application
Name=Fedora setup (finish session)
Comment=Applies the GNOME and EasyEffects settings that need a logged-in desktop
Exec="$wrapper"
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

  ok "desktop-only steps queued for your next login (nothing for you to do)"
}

stage_session() {
  step "Session finalisation"

  local entry="$HOME/.config/autostart/fedora-setup-session.desktop"

  if not_gnome; then
    ok "desktop is ${XDG_CURRENT_DESKTOP}, not GNOME — nothing to finalise"
    rm -f "$entry"
    return 0
  fi

  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    warn "no desktop session yet — queued for the next login"
    return 0
  fi

  # Only the per-user halves of the gnome and audio stages: this runs from
  # autostart, where there is no terminal to answer a sudo prompt.
  SESSION_PENDING=0
  gnome_settings || SESSION_PENDING=1
  if audio_wanted && installed easyeffects; then
    ee_write_autoload || SESSION_PENDING=1
    audio_session_start || SESSION_PENDING=1
  fi

  if (( SESSION_PENDING == 0 )); then
    rm -f "$entry" "$STATE_DIR/finish-session.sh"
    ok "desktop settings and audio profile applied"
  else
    warn "some desktop steps still need a session — will retry at next login"
  fi
}

# --------------------------------------------------------------- 13. sweep ---

stage_sweep() {
  step "13. Final update sweep"

  # Stage 2 updated the system as it was *then*. Since it, we enabled RPM
  # Fusion, swapped ffmpeg and mesa, and added the Helium, VS Code and
  # Flathub repos — all of which can pull newer dependencies. One last pass
  # over every source guarantees the machine is genuinely current.
  log "RPM packages"
  run sudo dnf upgrade -y   # metadata is already fresh from stage 2

  # System and user Flatpak installations are separate scopes and a plain
  # 'flatpak update' only covers the one you have rights to.
  log "Flatpaks (system + user scopes)"
  run_sh "sudo flatpak update -y --noninteractive || true"
  run_sh "flatpak update -y --noninteractive || true"

  # Metadata was refreshed in the update stage (and by Fedora's own
  # fwupd-refresh timer). --no-reboot-check: '-y' would otherwise also answer
  # "Restart now?" and reboot the laptop in the middle of the script. Many
  # laptops apply firmware during the next boot, not while running.
  log "Firmware"
  if (( DRY_RUN )); then
    run sudo fwupdmgr update -y
  else
    local help="" ; local -a fwargs=(-y)
    help="$(sudo fwupdmgr update --help 2>&1 || true)"
    contains "$help" "--no-reboot-check" && fwargs+=(--no-reboot-check)
    run sudo fwupdmgr update "${fwargs[@]}" || true
  fi
}

# -------------------------------------------------------------- 14. health ---

HEALTH_ISSUES=0
issue() { HEALTH_ISSUES=$(( HEALTH_ISSUES + 1 )); warn "$@"; }

stage_health() {
  step "14. Health check"

  # Report-only. Nothing here changes configuration.

  log "Failed system services"
  local failed
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
  if [[ -z "$failed" ]]; then
    ok "no failed services"
  else
    printf '%s\n' "$failed"
    issue "inspect with: systemctl status <unit>   and   journalctl -u <unit> -b"
  fi
  failed="$(systemctl --user --failed --no-legend --plain 2>/dev/null || true)"
  if [[ -n "$failed" ]]; then
    printf '%s\n' "$failed"
    issue "failed user services above"
  fi

  log "Errors logged since this boot (last 15)"
  run_sh "journalctl -b -p err --no-pager -q 2>/dev/null | tail -n 15 || true"

  log "Reboot needed?"
  local running newest
  running="$(uname -r)"
  newest="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -n1 || true)"
  if [[ -n "$newest" && "$running" != "$newest" ]]; then
    issue "running kernel $running, but $newest is installed — reboot to use it."
  else
    ok "running the newest installed kernel ($running)"
  fi

  log "Battery health"
  local bat=/sys/class/power_supply/BAT0 full design
  if [[ -r $bat/energy_full && -r $bat/energy_full_design ]]; then
    full="$(<"$bat/energy_full")"; design="$(<"$bat/energy_full_design")"
    if (( design > 0 )); then
      ok "capacity: $(( full * 100 / design ))% of design, $(cat "$bat/cycle_count" 2>/dev/null || echo '?') cycles"
    fi
  else
    ok "no battery info exposed"
  fi

  log "Disk"
  run_sh "df -h / /home 2>/dev/null | awk '!seen[\$0]++' || true"
  local use
  use="$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
  if [[ -n "$use" ]] && (( use >= 85 )); then
    issue "root filesystem is ${use}% full — performance and updates suffer past ~90%."
  fi

  # Fedora uses btrfs but schedules no scrub. A monthly scrub verifies every
  # block's checksum and catches a failing SSD before it eats your files.
  # It reads the whole disk once (a few minutes on an NVMe drive).
  if [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == btrfs ]]; then
    log "Btrfs scrub (monthly)"
    local stamp="$STATE_DIR/btrfs-scrub.last" last=0 now
    now="$(date +%s)"
    last="$(cat "$stamp" 2>/dev/null || echo 0)"
    if (( now - last > 30 * 86400 )); then
      # Errors found are reported, not fatal — cleanup still has to run.
      run_sh "sudo btrfs scrub start -B / || echo '  !! scrub reported errors — see: sudo btrfs scrub status /'"
      (( DRY_RUN )) || printf '%s\n' "$now" >"$stamp"
    else
      ok "last scrub $(( (now - last) / 86400 )) days ago — not due yet"
    fi
    run_sh "sudo btrfs device stats / | grep -v ' 0\$' || true"
  fi

  log "SSD health"
  local disk
  disk="$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1; exit}' || true)"
  if [[ -n "$disk" ]]; then
    run_sh "sudo smartctl -H /dev/$disk 2>/dev/null | grep -iE 'result|status' || true"
  else
    ok "no disk device found"
  fi
}

# ------------------------------------------------------------- 15. cleanup ---

stage_cleanup() {
  step "15. Cleanup"

  # Order matters: everything that needs repo metadata runs FIRST, and
  # 'dnf clean all' is dead last. Cleaning the cache up front would force
  # every later dnf command to re-download all metadata.

  log "Tools needed for the checks below"
  dnf_try rpmconf remove-retired-packages clean-rpm-gpg-pubkey symlinks

  log "Stale config files left by upgrades (.rpmnew / .rpmsave)"
  # Report only — merging configs is interactive and must be your decision.
  # Searched for directly: rpmconf has no list-only mode, and with its errors
  # hidden it would always look like "nothing found".
  report "sudo find /etc \\( -name '*.rpmnew' -o -name '*.rpmsave' \\) -print" \
    "merge the files above by running: sudo rpmconf -a"

  # Retired packages only appear after a release upgrade (44 -> 45), so this
  # is only mentioned on the first run after the Fedora version changes.
  local ver last_ver stamp="$STATE_DIR/fedora-version"
  ver="$(rpm -E %fedora)"
  last_ver="$(cat "$stamp" 2>/dev/null || echo "$ver")"
  if [[ "$ver" != "$last_ver" ]]; then
    log "Retired packages (dropped by Fedora $ver, no longer getting updates)"
    warn "upgraded from Fedora $last_ver: run 'remove-retired-packages' by hand — it is interactive."
  fi
  (( DRY_RUN )) || printf '%s\n' "$ver" >"$stamp"

  log "Duplicate packages left behind by a failed release upgrade"
  report "sudo dnf repoquery --duplicates" "remove them with: sudo dnf remove --duplicates"

  log "Packages no longer provided by any enabled repo"
  # spotifast and nuvio come from GitHub, not a repo, so they always show up
  # here and are meant to; old kernels are handled by installonly_limit.
  report "dnf repoquery --extras 2>/dev/null | grep -vE '^(spotifast|nuvio|kernel|kmod-)'" \
    "review the list above before removing anything — RPMs you installed by hand show up here too."

  # installonly_limit=2 (stage 1) prunes old kernels on each kernel update;
  # the spare one to boot from is deliberate, so nothing is force-removed.
  log "Installed kernels"
  run_sh "rpm -q kernel | sort -V || true"

  log "Orphaned dependencies"
  run sudo dnf autoremove -y

  log "Old RPM signing keys from previous releases"
  run_sh "sudo clean-rpm-gpg-pubkey || true"

  log "Dangling symlinks under /usr"
  report "sudo symlinks -r /usr | grep dangling" "remove them with: sudo symlinks -r -d /usr"

  log "Unused Flatpak runtimes (both scopes) and repo integrity"
  run_sh "sudo flatpak uninstall --unused -y --noninteractive || true"
  run_sh "flatpak uninstall --unused -y --noninteractive || true"
  run_sh "sudo flatpak repair || true"

  log "Journal trim (2 weeks / 500M)"
  run sudo journalctl --vacuum-time=2weeks
  run sudo journalctl --vacuum-size=500M

  log "Saved crash dumps"
  run_sh "coredumpctl --no-pager list 2>/dev/null | tail -5 || true"
  run_sh "sudo journalctl --vacuum-time=2weeks --identifier=systemd-coredump >/dev/null 2>&1 || true"

  log "Your user cache (reported, not deleted — apps rebuild these but it is your data)"
  run_sh "du -sh ~/.cache 2>/dev/null || true"

  # Last, now that nothing else needs the metadata. 'packages', not 'all':
  # wiping the repo metadata too would make the next dnf command re-download
  # all of it, and this runs on every maintenance pass.
  log "Package cache"
  run sudo dnf clean packages

  log "Disk usage after cleanup"
  run_sh "df -h /"
}

# ------------------------------------------------------------- 16. release ---

# Optional, never part of a plain run: moving to the next Fedora release is a
# decision, not maintenance. Downloads everything first; the actual upgrade
# happens during a reboot (dnf5 offline upgrade). Run the script once more
# afterwards to re-check everything on the new release.
stage_release() {
  step "Fedora release upgrade"

  local cur next
  cur="$(rpm -E %fedora)"
  next=$(( cur + 1 ))

  log "Bring Fedora $cur fully up to date first"
  run sudo dnf upgrade --refresh -y

  log "Download Fedora $next"
  if ! run sudo dnf system-upgrade download -y --releasever="$next"; then
    warn "Fedora $next could not be downloaded (not released yet, or a repo/package conflict above)."
    warn "nothing was changed — you stay on Fedora $cur."
    return 0
  fi

  ok "Fedora $next is downloaded and installs during the next reboot."
  ok "after it, run fedora-setup once more to re-check everything."
  if (( DRY_RUN )); then
    return 0
  fi
  if (( ! ASSUME_YES )) && ask_yes "Reboot now and install Fedora $next? [y/N] "; then
    run sudo dnf offline reboot -y
  else
    ok "when ready: sudo dnf offline reboot"
  fi
}

# ------------------------------------------------------------------- main ---

need_reboot() {
  local running newest
  running="$(uname -r)"
  newest="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -n1 || true)"
  [[ -n "$newest" && "$running" != "$newest" ]]
}

finish() {
  step "Done"

  if (( HEALTH_ISSUES > 0 )); then
    warn "$HEALTH_ISSUES health issue(s) found — see the health stage above."
  fi

  (( DRY_RUN )) || [[ -z "${LOG:-}" ]] || ok "full log: $LOG"

  if (( SESSION_PENDING )); then
    schedule_session_finalize
  fi

  if (( FIRST_RUN && FULL_RUN && ! DRY_RUN )); then
    date >"$FIRST_DONE"
    ok "first full setup finished."
    cat <<'EOT'

  Post-reboot checks (all optional, they only print information):
    vainfo | grep -i h264        # AMD hardware decode
    vulkaninfo --summary         # Vulkan freeworld driver
    ffmpeg -codecs | grep 264    # full ffmpeg
    tuned-adm active             # power profile
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver   # acpi-cpufreq is expected on a T14 Gen 1

EOT
  elif need_reboot; then
    ok "reboot when convenient to use the newest kernel."
  fi

  # Explicit: a trailing 'x && y' would make the function return 1 for the
  # whole script under 'set -e' whenever the check was negative.
  return 0
}

main() {
  # No file to run from (fresh install via `bash <(curl ...)`): clone first.
  [[ -n "$SELF_PATH" ]] || bootstrap

  # Pull a newer version of this script first: the same plain run then also
  # keeps the tool itself current.
  self_update
  start_log

  preflight

  wants config    && stage_config
  wants update    && stage_update
  wants rpmfusion && stage_rpmfusion
  wants flatpak   && stage_flatpak
  wants amd       && stage_amd
  wants media     && stage_media
  wants apps      && stage_apps
  wants audio     && stage_audio
  wants vpn       && stage_vpn
  wants gnome     && stage_gnome
  wants laptop    && stage_laptop
  wants sweep     && stage_sweep
  wants health    && stage_health
  wants cleanup   && stage_cleanup
  wants session   && stage_session
  wants release   && stage_release

  finish

  # Offer a reboot only when it is genuinely useful and a human is there.
  if (( REBOOT_PROMPT && ! ASSUME_YES && ! DRY_RUN )) && need_reboot; then
    ask_yes "Reboot now to finish the kernel/driver update? [y/N] " && run sudo systemctl reboot
  fi

  exit 0
}

main "$@"
