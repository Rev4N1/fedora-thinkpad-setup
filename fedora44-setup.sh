#!/usr/bin/env bash
#
# Fedora 44 post-install setup — ThinkPad T14 Gen 1 AMD, GNOME
#
# Target:  Fedora 44 Workstation (GNOME 50), ThinkPad T14 Gen 1 AMD
#          (Renoir / Ryzen 4000), dnf5
# Scope:   RPM Fusion, full codecs, AMD VA-API/Vulkan freeworld, Flathub,
#          Helium + VS Code + Spotifast/Nuvio/Discord, EasyEffects with the
#          T14 Gen 1 Dolby speaker profile, WireGuard, GNOME desktop tweaks,
#          ThinkPad power/firmware/fingerprint, health checks, deep cleanup.
#
# Usage:
#   ./fedora44-setup.sh                 # set up, or maintain, the laptop
#   ./fedora44-setup.sh --dry-run       # print commands, change nothing
#   ./fedora44-setup.sh amd media apps  # run only the named stages
#   ./fedora44-setup.sh --yes           # skip the "Proceed?" question
#
# The same plain run serves for a fresh install and for upkeep: every stage
# checks what is already done and skips it, so re-running it just updates
# everything (including the GitHub-only apps), puts back any setting that
# drifted, checks the machine's health and cleans up.
#
# Stages: config update rpmfusion flatpak amd media apps audio vpn gnome
#         laptop sweep health cleanup
#
# Files next to this script that are picked up if present:
#   wireguard/*.conf  — your WireGuard tunnels, imported into NetworkManager
#                       (they contain private keys: keep them out of git)
#
# Every real run is logged to ~/.local/state/fedora-setup/logs/.
#
# Read this before you run it. It is not official Fedora documentation.

set -Eeuo pipefail

# ---------------------------------------------------------------- settings ---

DRY_RUN=0
ASSUME_YES=0
STAGES=()

ALL_STAGES=(config update rpmfusion flatpak amd media apps audio vpn gnome laptop sweep health cleanup)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Remembers which GitHub release of each app is installed, the last btrfs
# scrub, whether the first full setup has finished, and keeps run logs — so
# re-runs only do what is due.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-setup"

# Set once the first full run completes. Until then, one-time advice (log
# out, enroll a fingerprint, ...) is printed; afterwards re-runs stay quiet.
FIRST_DONE="$STATE_DIR/first-setup.done"
FIRST_RUN=1
[[ -f "$FIRST_DONE" ]] && FIRST_RUN=0

# ---------------------------------------------------------------- plumbing ---

C_OK=$'\033[1;32m'; C_INFO=$'\033[1;34m'; C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'

log()  { printf '%s==>%s %s\n'   "$C_INFO" "$C_OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n'  "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s  !!%s %s\n'  "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s ERR%s %s\n'  "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }

step() { printf '\n%s%s%s\n' "$C_INFO" "────── $* ──────" "$C_OFF"; }

# run CMD... — echoes then executes, or just echoes under --dry-run
run() {
  printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_OFF"
  (( DRY_RUN )) && return 0
  "$@"
}

# run_sh 'shell string' — for commands needing brace expansion, globs or pipes
run_sh() {
  printf '%s  $ %s%s\n' "$C_DIM" "$1" "$C_OFF"
  (( DRY_RUN )) && return 0
  bash -c "$1"
}

# report 'shell string' 'warning' — run a read-only check and only print its
# output, plus the warning, when it found something. Keeps re-runs quiet.
report() {
  printf '%s  $ %s%s\n' "$C_DIM" "$1" "$C_OFF"
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

# gset SCHEMA KEY VALUE — a GNOME preference for the *current user*.
# Never call this under sudo: it would write to root's dconf, not yours.
gset() {
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    warn "no session bus — skipping GNOME setting: $1 $2"
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

flatpak_install() {
  local missing=() p
  for p in "$@"; do
    flatpak info "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    ok "flatpaks already installed: $*"
    return 0
  fi
  run flatpak install -y --noninteractive flathub "${missing[@]}"
}

# gh_rpm PKG OWNER/REPO ASSET_REGEX — install or upgrade an app that is only
# published as an RPM on GitHub Releases (no dnf repo, so 'dnf upgrade' never
# sees new versions). The installed release tag is remembered, so re-runs
# skip the download unless a newer release is out.
gh_rpm() {
  local pkg="$1" repo="$2" pattern="$3" json tag url stamp
  stamp="$STATE_DIR/$pkg.tag"

  if ! json="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest")"; then
    warn "could not reach GitHub for $pkg — skipping (try again later)"
    return 0
  fi
  tag="$(grep -m1 '"tag_name"' <<<"$json" | cut -d'"' -f4 || true)"
  url="$(grep -m1 -oE "https://[^\"]+/$pattern" <<<"$json" || true)"
  if [[ -z "$url" ]]; then
    warn "no RPM matching '$pattern' in $repo release ${tag:-?} — skipping $pkg"
    return 0
  fi

  if installed "$pkg" && [[ "$(cat "$stamp" 2>/dev/null)" == "$tag" ]]; then
    ok "$pkg $tag is current"
    return 0
  fi
  run sudo dnf install -y "$url"
  (( DRY_RUN )) || printf '%s\n' "$tag" >"$stamp"
}

# Report the failing STAGE, not the line inside the run() helper where the
# error surfaces — otherwise every failure reads "line 46: $@", which says
# nothing about what actually broke.
on_err() {
  local code=$? cmd="$BASH_COMMAND" i stage=""
  for (( i = 0; i < ${#FUNCNAME[@]}; i++ )); do
    case "${FUNCNAME[i]}" in
      stage_*|preflight) stage="${FUNCNAME[i]}"; break ;;
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

# ------------------------------------------------------------------- args ---

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*)        die "unknown flag: $arg" ;;
    *)
      [[ " ${ALL_STAGES[*]} " == *" $arg "* ]] \
        || die "unknown stage: $arg (valid: ${ALL_STAGES[*]})"
      STAGES+=("$arg") ;;
  esac
done
(( ${#STAGES[@]} )) || STAGES=("${ALL_STAGES[@]}")

mkdir -p "$STATE_DIR/logs"
if (( ! DRY_RUN )); then
  LOG="$STATE_DIR/logs/$(date +%Y-%m-%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
  # Keep the 15 most recent logs.
  ls -1t "$STATE_DIR"/logs/*.log 2>/dev/null | tail -n +16 | xargs -r rm -f
fi

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

  local ver
  ver="$(rpm -E %fedora)"
  if [[ "$ver" != "44" ]]; then
    warn "this script targets Fedora 44; detected Fedora $ver."
    warn "dnf5 syntax below may not match your release. Continuing in 5s — Ctrl-C to abort."
    (( DRY_RUN )) || sleep 5
  else
    ok "Fedora 44 detected"
  fi

  if dnf --version 2>/dev/null | grep -q '^dnf5'; then
    ok "dnf5 in use"
  else
    warn "dnf5 not detected — 'config-manager setopt' and friends may fail."
  fi

  # Word boundaries matter here: a bare 'ati' also matches "compATIble controller".
  if have lspci && lspci | grep -Ei 'VGA|3D controller|Display' \
       | grep -qiE '\b(amd|ati|radeon)\b'; then
    ok "AMD GPU detected"
  else
    warn "no AMD GPU detected. The 'amd' stage assumes AMD graphics."
    warn "skip it by naming the other stages explicitly (see --help)."
  fi

  have curl || die "curl not found — it is needed to fetch the GitHub-only apps."

  if (( DRY_RUN )); then
    warn "DRY RUN — nothing will be changed."
  else
    log "Stages to run: ${STAGES[*]}"
    log "Logging to: $LOG"
  fi

  if (( ! DRY_RUN && ! ASSUME_YES )); then
    # 'read' fails on EOF — which is what you get when the script is
    # double-clicked from Files or started by a .desktop launcher. Left
    # unhandled that aborts with a baffling error, in a window that closes
    # too fast to read. Piping a 'y' in still works.
    if ! read -rp "Proceed? [y/N] " reply; then
      die "no input on stdin — open a terminal and run:  $0
     (double-clicking cannot work: this asks before changing anything)"
    fi
    [[ "$reply" =~ ^[Yy]$ ]] || die "aborted — nothing was changed."
  fi

  if (( ! DRY_RUN )); then
    # Cache sudo up front and keep it warm for the whole run.
    sudo -v
    # '|| true' + 'trap - ERR': the loop inherits the ERR trap (set -E), and
    # a single failed refresh must not print a bogus "script failed".
    ( trap - ERR
      while true; do sudo -n true 2>/dev/null || true; sleep 60; kill -0 "$$" 2>/dev/null || exit 0; done ) &
  fi
}

# ------------------------------------------------------------ 1. dnf config ---

stage_config() {
  step "1. dnf5 tuning"

  local conf=/etc/dnf/dnf.conf
  local -a settings=(
    "max_parallel_downloads=10"   # default is 3
    "installonly_limit=2"         # keep 2 kernels instead of 3
  )
  local kv key
  for kv in "${settings[@]}"; do
    key="${kv%%=*}"
    if sudo grep -q "^${key}=" "$conf" 2>/dev/null; then
      ok "$key already set"
    else
      run_sh "echo '$kv' | sudo tee -a $conf >/dev/null"
    fi
  done

  log "Hostname"
  local desired="benja-laptop" current
  current="$(hostnamectl --static 2>/dev/null || true)"
  if [[ "$current" == "$desired" ]]; then
    ok "hostname already '$desired'"
  else
    run sudo hostnamectl set-hostname "$desired"
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
  dnf_install fwupd
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
  dnf_install rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data

  # Cisco OpenH264 repo — dnf5 syntax. The old '--set-enabled' form is gone.
  run sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

  # No 'dnf upgrade' here: the sweep stage updates everything, RPM Fusion
  # packages included, once all repos are in place.
}

# -------------------------------------------------------------- 4. flatpak ---

stage_flatpak() {
  step "4. Flathub"

  dnf_install flatpak

  # Fedora's own remotes duplicate and shadow Flathub apps — drop them.
  local r
  for r in fedora fedora-testing; do
    if flatpak remotes --columns=name | grep -qx "$r"; then
      run_sh "sudo flatpak remote-delete --force $r || true"
    else
      ok "remote '$r' not present"
    fi
  done

  # The guide's "Option 1: Full Repository" — the whole of Flathub, including
  # community-packaged apps. Adding the remote is only half of it: Fedora ships
  # Flathub pre-added but *filtered* to a handful of apps, and the filter
  # survives remote-add. Clearing it is what actually gives you the full set.
  run flatpak remote-add --if-not-exists flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo
  run_sh "sudo flatpak remote-modify --no-filter --enable flathub || true"

  # No 'flatpak update' here: the sweep stage updates both scopes.
}

# --------------------------------------------------------- 5. amd graphics ---

stage_amd() {
  step "5. AMD graphics (Vulkan + VA-API)"

  # mesa-vulkan-drivers is deliberately NOT in this list. It is already on a
  # Workstation install, and after the freeworld swap below it is *replaced*
  # by mesa-vulkan-drivers-freeworld — so asking for it by name on a re-run
  # hits a package conflict, and dnf then "helpfully" satisfies the request
  # with the i686 build instead, dragging in ~350 MB of 32-bit libraries.
  dnf_install vulkan-loader vulkan-tools mesa-libGLU libva-utils

  # Fedora 44 note — this is the fix from the cherry-picked commit:
  # the 'mesa-va-drivers' subpackage no longer exists (VA-API moved back into
  # mesa-dri-drivers), so the old 'dnf swap mesa-va-drivers ...' now fails.
  # Install the RPM Fusion freeworld driver alongside instead.
  dnf_install mesa-va-drivers-freeworld

  # Vulkan is still a genuine swap, per RPM Fusion's Howto/Multimedia.
  # Three states to handle so re-runs are safe:
  if installed mesa-vulkan-drivers-freeworld; then
    ok "mesa-vulkan-drivers-freeworld already installed — nothing to swap"
  elif installed mesa-vulkan-drivers; then
    run_sh 'sudo dnf swap -y mesa-vulkan-drivers{,-freeworld}'
  else
    # Neither present (unusual) — install freeworld directly rather than
    # pulling in the stock driver only to swap it straight back out.
    dnf_install mesa-vulkan-drivers-freeworld
  fi

  # Guard against the 32-bit stack sneaking in via a conflict fallback.
  if rpm -q mesa-vulkan-drivers.i686 >/dev/null 2>&1; then
    warn "mesa-vulkan-drivers.i686 is installed — you have no 32-bit games or Wine."
    warn "remove it with:  sudo dnf remove mesa-vulkan-drivers.i686 && sudo dnf autoremove"
  fi

  # Deliberately omitted:
  #   - the .i686 freeworld libraries: only needed for 32-bit Steam/Wine/Proton.
  #   - mesa-vdpau-drivers-freeworld: VDPAU is legacy, and everything on a
  #     modern GNOME/Wayland desktop goes through VA-API.
}

# ---------------------------------------------------------------- 6. media ---

stage_media() {
  step "6. Codecs and hardware acceleration"

  # Fedora ships the codec-stripped ffmpeg-free; swap in the full RPM Fusion build.
  if installed ffmpeg; then
    ok "full ffmpeg already installed"
  else
    run sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
  fi

  # 'install', not the old 'groupupdate' — that subcommand is gone in dnf5.
  # Once the group is installed its packages update with the sweep stage, so
  # skip the slow group resolve on re-runs.
  if dnf group list --installed 2>/dev/null | grep -qw multimedia; then
    ok "@multimedia group already installed"
  else
    run_sh 'sudo dnf install -y @multimedia \
        --setopt="install_weak_deps=False" \
        --exclude=PackageKit-gstreamer-plugin'
  fi

  # dnf5 cannot pull RPM Fusion packages into Fedora's groups (see stage 3),
  # so the patent-encumbered GStreamer plugins — what GNOME apps use for
  # H.264/H.265/AAC — have to be asked for by name.
  dnf_install gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly

  dnf_install libva libva-utils

  # Cisco OpenH264 (repo enabled in stage 3) for GStreamer apps. Helium is
  # Chromium-based and brings its own codecs, so it does not need this.
  dnf_install openh264 gstreamer1-plugin-openh264
}

# ----------------------------------------------------------------- 7. apps ---

stage_apps() {
  step "7. Applications"

  log "Archive + AppImage support"
  dnf_install p7zip p7zip-plugins unrar fuse fuse-libs

  log "Visual Studio Code"
  if installed code; then
    ok "code already installed"
  else
    run sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    run_sh 'printf "%s\n" \
      "[code]" \
      "name=Visual Studio Code" \
      "baseurl=https://packages.microsoft.com/yumrepos/vscode" \
      "enabled=1" \
      "autorefresh=1" \
      "type=rpm-md" \
      "gpgcheck=1" \
      "gpgkey=https://packages.microsoft.com/keys/microsoft.asc" \
      | sudo tee /etc/yum.repos.d/vscode.repo >/dev/null'
    run sudo dnf install -y code
  fi

  log "Helium browser"
  # Official COPR from imput (the Helium devs). Helium deliberately ships no
  # Flatpak — Chromium's sandbox cannot work inside one. Being a dnf repo,
  # it updates with every 'dnf upgrade' from here on.
  local helium_was_installed=0
  installed helium-bin && helium_was_installed=1
  if dnf repolist --enabled 2>/dev/null | grep -q 'imput:helium'; then
    ok "Helium COPR already enabled"
  else
    run sudo dnf copr enable -y imput/helium
  fi
  dnf_install helium-bin

  # Make it the default browser — only on first install, so a later choice
  # of yours is never overridden by a maintenance run.
  if (( ! helium_was_installed && ! DRY_RUN )); then
    local desktop="" f
    for f in /usr/share/applications/*helium*.desktop; do
      [[ -e "$f" ]] && { desktop="${f##*/}"; break; }
    done
    if [[ -n "$desktop" ]] && have xdg-settings && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
      run_sh "xdg-settings set default-web-browser '$desktop' || true"
    else
      warn "set Helium as default yourself: Settings > Apps > Default Apps"
    fi
  fi

  log "Spotifast + Nuvio (GitHub releases)"
  # Neither has a dnf repo or Flathub listing, so 'dnf upgrade' cannot update
  # them. gh_rpm checks for a newer release on every run instead — this is
  # why re-running the script is how they stay updated.
  # Spotifast needs Spotify Premium to play (free accounts can only browse).
  # Nuvio is alpha software — expect frequent releases.
  gh_rpm spotifast crmne/spotifast          'spotifast-[0-9.]+-[0-9]+\.x86_64\.rpm'
  gh_rpm nuvio     NuvioMedia/NuvioDesktop  'Nuvio-Linux-x86_64-[^"/]+\.rpm'

  log "Discord"
  # Flatpak: Discord ships no Fedora package, and its tarball self-updates
  # in a way that breaks under a package manager.
  flatpak_install com.discordapp.Discord

  # No 'timedatectl set-local-rtc 0' step: that only matters when dual-booting
  # Windows, and Fedora already keeps the hardware clock in UTC on its own.
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

stage_audio() {
  step "8. Audio (EasyEffects + T14 Gen 1 speaker profile)"

  # The Fedora package rather than the Flatpak: it updates with the system,
  # and keeps its data in ~/.local/share/easyeffects where we put files below.
  dnf_install easyeffects

  local data="$HOME/.local/share/easyeffects" name src
  run mkdir -p "$data/irs" "$data/output"

  log "Impulse response files"
  # Copy from a local checkout of the repo next to this script if there is
  # one, otherwise download. Existing files are never overwritten.
  local local_dir="$SCRIPT_DIR/linux-thinkpad-speaker-improvements-main/$SPEAKER_IRS_MODEL"
  for name in "${SPEAKER_IRS[@]}"; do
    if [[ -f "$data/irs/$name.irs" ]]; then
      ok "$name.irs already in place"
    elif [[ -f "$local_dir/$name.irs" ]]; then
      run cp "$local_dir/$name.irs" "$data/irs/$name.irs"
    else
      src="https://raw.githubusercontent.com/$SPEAKER_IRS_REPO/main/$SPEAKER_IRS_MODEL/$name.irs"
      run_sh "curl -fsSL -o '$data/irs/$name.irs' '$src' || { rm -f '$data/irs/$name.irs'; echo '  !! could not download $name.irs'; }"
    fi
  done

  log "Output preset: $SPEAKER_PRESET"
  # Convolver followed by a limiter — the convolution boosts some frequencies
  # enough to clip without one. Written once; your later tweaks in the
  # EasyEffects UI are kept on re-runs.
  local preset="$data/output/$SPEAKER_PRESET.json"
  if [[ -f "$preset" ]]; then
    ok "preset already exists — leaving your version alone"
  elif (( DRY_RUN )); then
    printf '%s  $ write %s%s\n' "$C_DIM" "$preset" "$C_OFF"
  else
    cat >"$preset" <<'JSON'
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
    ok "wrote $preset"
    # Shown only on the run that creates the preset, not on every re-run.
    cat <<EOT

  One-time steps in EasyEffects (they cannot be scripted reliably):
    1. Presets (top bar) > Output > load "$SPEAKER_PRESET".
    2. Preferences > enable "Launch service at system startup".
    3. With the laptop speakers selected, autoload the preset for that
       device, and a flat/empty preset for headphones — the Dolby curve is
       tuned for the internal speakers only.
  Swap profiles any time in the Convolver: Music / Movie / Voice / Game.

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
    ok "no tunnel configs in $dir — set them up yourself, or drop *.conf files there"
    return 0
  fi

  # Import each tunnel once. The connection takes the file's name, so keep
  # names to 15 characters or fewer (the Linux interface-name limit).
  for f in "$dir"/*.conf; do
    name="$(basename "$f" .conf)"
    if nmcli -g NAME connection show 2>/dev/null | grep -qxF "$name"; then
      ok "tunnel '$name' already imported"
    else
      run sudo nmcli connection import type wireguard file "$f"
    fi
    # The files hold private keys: only nag when they are readable by others.
    if (( $(stat -c '0%a' "$f") & 077 )); then
      warn "$f is readable by others — it holds a private key: chmod 600 '$f'"
    fi
  done
}

# --------------------------------------------------------------- 10. gnome ---

stage_gnome() {
  step "10. GNOME"

  dnf_install gnome-tweaks
  flatpak_install com.mattjakeman.ExtensionManager

  log "Touchpad"
  # GNOME ships tap-to-click OFF by default, which surprises most laptop users.
  gset org.gnome.desktop.peripherals.touchpad tap-to-click true
  gset org.gnome.desktop.peripherals.touchpad natural-scroll true
  # Pointer speed runs -1.0 (slowest) .. 1.0 (fastest); 0.0 is the default.
  gset org.gnome.desktop.peripherals.touchpad speed 0.45

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

  log "Extensions: Dash to Dock + Blur my Shell + Caffeine"
  # All three are packaged by Fedora, so use those rather than
  # extensions.gnome.org: they are built against the GNOME 50 shell F44 ships,
  # and they update with the system instead of breaking on a shell upgrade.
  dnf_install \
    gnome-shell-extension-dash-to-dock \
    gnome-shell-extension-blur-my-shell \
    gnome-shell-extension-caffeine
  if have gnome-extensions; then
    run_sh "gnome-extensions enable dash-to-dock@micxgx.gmail.com || true"
    run_sh "gnome-extensions enable blur-my-shell@aunetx      || true"
    run_sh "gnome-extensions enable caffeine@patapon.info     || true"
  fi

  # Ptyxis is the default GNOME terminal since F41. The widely-copied
  # transparency snippet relies on $PTYXIS_PROFILE, which only exists *inside*
  # a running Ptyxis — so resolve the default profile UUID properly instead.
  if have gsettings && gsettings list-schemas | grep -qx 'org.gnome.Ptyxis'; then
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
    ok "Ptyxis not installed — skipping terminal transparency"
  fi

  (( FIRST_RUN )) || return 0
  cat <<'EOT'

  Dash to Dock, Blur my Shell and Caffeine are installed and enabled. Log
  out and back in for them to load (Wayland cannot reload the shell live);
  configure them from Extension Manager after that.

  Touchpad speed is set to 0.45 on a -1.0..1.0 scale. Adjust it in this
  script, not in Settings — every re-run puts the script's value back.

EOT
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

  dnf_install tuned tuned-ppd
  run sudo systemctl enable --now tuned
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
  if systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
    ok "fstrim.timer already enabled"
  else
    run sudo systemctl enable --now fstrim.timer
  fi

  log "Boot time"
  # NetworkManager-wait-online holds boot until the network is fully up. It
  # only matters for servers mounting network shares at boot; on a laptop it
  # just adds seconds (more on Wi-Fi). WireGuard via NetworkManager does not
  # need it either.
  if systemctl is-enabled NetworkManager-wait-online.service >/dev/null 2>&1; then
    run sudo systemctl disable NetworkManager-wait-online.service
  else
    ok "NetworkManager-wait-online already disabled"
  fi

  log "Swap (Fedora uses zram by default — no swap partition needed)"
  run_sh "zramctl || true"

  # --- ThinkPad-specific ---------------------------------------------------
  local model
  model="$(cat /sys/class/dmi/id/product_version 2>/dev/null || true)"
  if [[ "$model" != *ThinkPad* ]]; then
    ok "not a ThinkPad (${model:-unknown}) — skipping ThinkPad extras"
    return 0
  fi

  log "ThinkPad detected: $model"

  local thr=/sys/class/power_supply/BAT0/charge_control_end_threshold
  if [[ -r $thr ]]; then
    ok "battery charge limit: $(<"$thr")% (left at 100% as you asked)"
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
  dnf_install fprintd fprintd-pam
  # No 'systemctl enable fprintd': the unit is static (no [Install] section)
  # because it is D-Bus activated — it starts on demand and exits when idle.
  # Enabling it is a no-op and '--now' would leave a daemon running for nothing.
  # The hints only show until a finger is enrolled.
  if fprintd-list "$USER" 2>/dev/null | grep -q ' - #[0-9]'; then
    ok "fingerprint enrolled"
  elif (( ! DRY_RUN )); then
    warn "enroll a finger (interactive, run it yourself):  fprintd-enroll"
    warn "then enable it for login/sudo with:              sudo authselect enable-feature with-fingerprint"
  fi
}

# --------------------------------------------------------------- 12. sweep ---

stage_sweep() {
  step "12. Final update sweep"

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
  run_sh "sudo fwupdmgr update -y --no-reboot-check || true"

  ok "everything is current."
}

# -------------------------------------------------------------- 13. health ---

stage_health() {
  step "13. Health check"

  # Report-only, except the monthly btrfs scrub. Nothing here changes config.

  log "Failed system services"
  local failed
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
  if [[ -z "$failed" ]]; then
    ok "no failed services"
  else
    printf '%s\n' "$failed"
    warn "inspect with: systemctl status <unit>   and   journalctl -u <unit> -b"
  fi
  failed="$(systemctl --user --failed --no-legend --plain 2>/dev/null || true)"
  [[ -z "$failed" ]] || { printf '%s\n' "$failed"; warn "failed user services above"; }

  log "Errors logged since this boot (last 15)"
  run_sh "journalctl -b -p err --no-pager -q 2>/dev/null | tail -n 15 || true"

  log "Reboot needed?"
  local running newest
  running="$(uname -r)"
  newest="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -n1 || true)"
  if [[ -n "$newest" && "$running" != "$newest" ]]; then
    warn "running kernel $running, but $newest is installed — reboot to use it."
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
    warn "root filesystem is ${use}% full — performance and updates suffer past ~90%."
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
    run_sh "sudo btrfs device stats / | grep -v ' 0\$' || echo '  no device errors'"
  fi

  log "SSD health"
  dnf_install smartmontools
  run_sh "sudo smartctl -H /dev/nvme0n1 2>/dev/null | grep -iE 'result|status' || true"
}

# ------------------------------------------------------------- 14. cleanup ---

stage_cleanup() {
  step "14. Cleanup"

  # Order matters: everything that needs repo metadata runs FIRST, and
  # 'dnf clean all' is dead last. Cleaning the cache up front would force
  # every later dnf command to re-download all metadata.

  log "Tools needed for the checks below"
  dnf_install rpmconf remove-retired-packages clean-rpm-gpg-pubkey symlinks

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
  # Filtered with grep: dnf5's --exclude does not reliably hide installed ones.
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

# ------------------------------------------------------------------- main ---

main() {
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

  step "Done"
  (( DRY_RUN )) || ok "full log: $LOG"

  # The first-install advice below is shown once, after the first complete
  # run; later runs are upkeep and only need the reboot reminder.
  if (( ! FIRST_RUN )); then
    ok "reboot if the health check said a newer kernel is waiting."
    return 0
  fi
  (( DRY_RUN )) || [[ ${#STAGES[@]} -ne ${#ALL_STAGES[@]} ]] || date >"$FIRST_DONE"
  ok "log out and back in for the GNOME extensions, then reboot for the kernel/drivers."
  cat <<'EOT'

  Post-reboot checks:
    vainfo | grep -i h264        # AMD hardware decode
    vulkaninfo --summary         # Vulkan freeworld driver
    ffmpeg -codecs | grep 264    # full ffmpeg
    tuned-adm active             # power profile
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver   # acpi-cpufreq is expected here

EOT
}

main "$@"
