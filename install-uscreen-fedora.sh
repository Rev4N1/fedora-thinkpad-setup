#!/usr/bin/env bash
# install-uscreen-fedora.sh — UScreen (Android tablet as a second monitor),
# Linux side. Standalone: not part of fedora44-setup.sh.
#
# Safe to re-run to update: every step skips itself when already done, and a
# new UScreen release is only downloaded when one is out.
#
# What it does, following docs/installation.md from the UScreen repo:
#   1. Enables RPM Fusion (stock Fedora has no full ffmpeg)
#   2. Installs build deps + android-tools + kernel-devel
#   3. Builds and installs the evdi kernel module from DisplayLink/evdi via DKMS
#      (evdi is not packaged for Fedora)
#   4. Installs or upgrades the uscreen RPM, verifying its checksum
#   5. Enables the systemd *user* service
#   6. Saves uscreen.apk for the tablet whenever the version changes
#
# Run as your normal user (NOT with sudo): ./install-uscreen-fedora.sh
# Options:  --tag v1.2.8      install a specific release instead of latest
#           --evdi v1.15.1    evdi version to build (default: latest release)
#           --no-apk          don't download the Android APK

set -euo pipefail

REPO="majmichu1/UScreen"
EVDI_TAG=""
EVDI_FALLBACK="v1.15.1"
TAG=""
GET_APK=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)    TAG="$2"; shift 2 ;;
        --evdi)   EVDI_TAG="$2"; shift 2 ;;
        --no-apk) GET_APK=0; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

info()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- sanity checks ----------
[[ $EUID -eq 0 ]] && die "Run this as your normal user, not root. It calls sudo where needed (the uscreen service is a *user* unit)."
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == "fedora" ]] || die "This script is for Fedora (detected: ${ID:-unknown})."
[[ -e /run/ostree-booted ]] && die "Atomic/ostree system detected (Silverblue, Kinoite, Bazzite...). Use the tarball installer (uscreen-<ver>-linux-x86_64.tar.gz → ./scripts/install.sh) instead."
[[ "$(uname -m)" == "x86_64" ]] || die "Only x86_64 packages are published."
command -v sudo >/dev/null || die "sudo is required."

sudo -v   # ask for the password once up front
# Keep sudo warm: an evdi build plus downloads can outlast its 5-minute timeout.
while true; do sudo -n true 2>/dev/null || true; sleep 60; kill -0 "$$" 2>/dev/null || exit 0; done &

WORKDIR="$(mktemp -d -t uscreen-install.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

# ---------- 1. RPM Fusion ----------
info "Enabling RPM Fusion (free + nonfree)"
if rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    echo "RPM Fusion already enabled."
else
    FV="$(rpm -E %fedora)"
    sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FV}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FV}.noarch.rpm"
fi

# ---------- 2. Dependencies ----------
info "Installing dependencies (android-tools, dkms, kernel headers, build tools)"
KVER="$(uname -r)"
# 'kernel-devel' (unversioned) is what keeps evdi working after kernel
# updates: dnf then installs the matching headers with every new kernel, and
# DKMS rebuilds the module for it automatically. The versioned one covers the
# kernel running right now.
NEED=()
for p in android-tools dkms git gcc make curl libdrm-devel kernel-devel; do
    rpm -q "$p" >/dev/null 2>&1 || NEED+=("$p")
done
if [[ ${#NEED[@]} -eq 0 ]]; then
    echo "All dependencies already installed."
else
    sudo dnf install -y "${NEED[@]}"
fi

# Headers for the running kernel. After a kernel update without a reboot
# they may already be gone from the repos — that is fine: DKMS builds evdi
# for the new kernel (whose headers came with 'kernel-devel' above) and it
# loads after the reboot.
KDEVEL_OK=1
if ! rpm -q "kernel-devel-${KVER}" >/dev/null 2>&1; then
    sudo dnf install -y "kernel-devel-${KVER}" || {
        KDEVEL_OK=0
        warn "No headers available for the running kernel ($KVER) — a newer kernel is probably installed."
        warn "evdi will be built for it; reboot into it, then run this script again."
    }
fi

info "Replacing ffmpeg-free with RPM Fusion's ffmpeg"
if rpm -q ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg already installed."
else
    sudo dnf install -y --allowerasing ffmpeg
fi

# ---------- 3. evdi kernel module ----------
if [[ -z "$EVDI_TAG" ]]; then
    # Newer kernels regularly need a newer evdi, so default to the latest.
    EVDI_TAG="$(curl -fsSL https://api.github.com/repos/DisplayLink/evdi/releases/latest 2>/dev/null \
                | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
    [[ "$EVDI_TAG" == v* ]] || { warn "Could not look up the latest evdi; using $EVDI_FALLBACK."; EVDI_TAG="$EVDI_FALLBACK"; }
fi

EVDI_VER="${EVDI_TAG#v}"
# Whatever version is registered now — the fallback if the new one fails.
OLD_EVDI="$({ dkms status evdi 2>/dev/null || true; } | grep -oE '^evdi/[^,: ]+' | sort -V | tail -n1 || true)"

info "evdi ${EVDI_VER} via DKMS"
if dkms status evdi 2>/dev/null | grep -q "^evdi/${EVDI_VER}[,:]"; then
    echo "evdi ${EVDI_VER} already registered with DKMS."
elif git clone --depth 1 --branch "$EVDI_TAG" https://github.com/DisplayLink/evdi.git \
     && ( cd evdi/module && sudo make install_dkms ); then
    # Drop older evdi versions so DKMS does not build several on every kernel update.
    { dkms status evdi 2>/dev/null | grep -oE '^evdi/[^,: ]+' || true; } | sort -u | while read -r old; do
        [[ "$old" == "evdi/${EVDI_VER}" ]] || sudo dkms remove "$old" --all || true
    done
elif [[ -n "$OLD_EVDI" ]]; then
    # A brand-new evdi release that does not build yet must not take UScreen
    # down with it: keep using the version that already works.
    sudo dkms remove "evdi/${EVDI_VER}" --all >/dev/null 2>&1 || true
    warn "evdi ${EVDI_VER} could not be fetched or built — keeping ${OLD_EVDI#evdi/}."
    EVDI_VER="${OLD_EVDI#evdi/}"
else
    die "evdi ${EVDI_VER} could not be fetched or built. Check /var/lib/dkms/evdi/${EVDI_VER}/build/make.log, or try another version with --evdi vX.Y.Z."
fi

# Registered is not the same as built for this kernel: after a kernel update
# DKMS may not have rebuilt it yet (or the build failed back then).
if [[ $KDEVEL_OK -eq 1 ]] && ! dkms status evdi -k "$KVER" 2>/dev/null | grep -q 'installed'; then
    info "Building evdi ${EVDI_VER} for the running kernel ($KVER)"
    sudo dkms install "evdi/${EVDI_VER}" -k "$KVER" \
      || warn "evdi build for $KVER failed — see /var/lib/dkms/evdi/${EVDI_VER}/build/make.log"
fi

SB_ON=0
if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
    SB_ON=1
fi
MOK=/var/lib/dkms/mok.pub
MOK_PENDING=0

# /sys/module rather than 'lsmod | grep -q': under pipefail, grep quitting
# early can make the pipeline report "not loaded" when it is.
if [[ -d /sys/module/evdi ]]; then
    echo "evdi module already loaded."
elif sudo modprobe evdi 2>/dev/null; then
    echo "evdi module loaded."
elif [[ $SB_ON -eq 1 ]] && [[ -r $MOK ]] && ! sudo mokutil --test-key "$MOK" 2>/dev/null | grep -q 'already enrolled'; then
    # The usual first-install case: DKMS signed the module with its own key,
    # which the firmware does not trust until it is enrolled.
    MOK_PENDING=1
    warn "Secure Boot is ON and the DKMS signing key is not enrolled yet, so evdi was rejected."
    warn "Enroll it (you will set a one-time password), then reboot and choose 'Enroll MOK' in the blue screen:"
    warn "    sudo mokutil --import $MOK"
    warn "Continuing with the rest of the install; evdi will load after that reboot."
else
    warn "Could not load evdi right now. Check 'sudo dmesg | tail' and 'dkms status evdi'."
    warn "If the kernel was just updated, reboot into it and run this script again."
fi

# ---------- 4. UScreen RPM ----------
if [[ -z "$TAG" ]]; then
    info "Finding latest UScreen release"
    URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")"
    TAG="${URL##*/}"
    [[ "$TAG" == v* ]] || die "Could not determine latest release tag (got: $TAG)."
fi
VER="${TAG#v}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
RPM="uscreen-${VER}-1.x86_64.rpm"
echo "Release: $TAG"

UPDATED=0
if [[ "$(rpm -q --qf '%{VERSION}' uscreen 2>/dev/null || true)" == "$VER" ]]; then
    echo "uscreen $VER is already installed — nothing to download."
    GET_APK=0
else
    info "Downloading $RPM"
    curl -fL --progress-bar -o "$RPM" "$BASE/$RPM" || die "Download failed: $BASE/$RPM"
    if [[ $GET_APK -eq 1 ]]; then
        curl -fL --progress-bar -o uscreen.apk "$BASE/uscreen.apk" || { warn "APK download failed."; GET_APK=0; }
    fi

    if curl -fsL -o SHA256SUMS "$BASE/SHA256SUMS"; then
        info "Verifying checksums"
        if ! grep -q " \*\?${RPM}\$" SHA256SUMS; then
            # Otherwise sha256sum fails with "no file was verified", which
            # would read as a mismatch.
            warn "SHA256SUMS does not list $RPM; skipping verification."
        else
            sha256sum -c --ignore-missing SHA256SUMS || die "Checksum mismatch — aborting."
        fi
    else
        warn "No SHA256SUMS found; skipping verification."
    fi

    info "Installing UScreen $VER"
    sudo dnf install -y --allowerasing "./$RPM"
    UPDATED=1
fi

# ---------- 5. User service ----------
info "uscreen user service"
systemctl --user daemon-reload
if [[ $UPDATED -eq 1 ]]; then
    systemctl --user enable uscreen && systemctl --user restart uscreen \
      || warn "Service failed to start — run 'uscreen doctor'."
    # udev rule for /dev/uinput needs a reload/re-login to apply
    sudo udevadm control --reload-rules && sudo udevadm trigger || true
else
    systemctl --user enable --now uscreen || warn "Service failed to start — run 'uscreen doctor'."
fi

# ---------- 6. APK ----------
if [[ $GET_APK -eq 1 ]]; then
    DEST="$HOME/Downloads"; mkdir -p "$DEST"
    cp uscreen.apk "$DEST/uscreen-${VER}.apk"
    echo "Tablet app saved to: $DEST/uscreen-${VER}.apk"
fi

# ---------- done ----------
if [[ $UPDATED -eq 0 ]]; then
    info "UScreen is up to date ($VER)."
    [[ $MOK_PENDING -eq 0 ]] || warn "evdi still needs the DKMS key enrolled — see the Secure Boot warning above."
    exit 0
fi

info "Done!"
cat <<EOF

Next steps:
  1. Tablet: install uscreen-${VER}.apk (or via USB:  adb install -r ~/Downloads/uscreen-${VER}.apk)
     and enable USB debugging (Settings → About → tap Build number 7× → Developer options).
  2. Plug the tablet in and accept the "Allow USB debugging" prompt.
  3. It should appear as a new monitor. If not, run:  uscreen doctor
EOF
[[ $MOK_PENDING -eq 0 ]] || echo "  !  Secure Boot: enroll the DKMS key (see warning above) and reboot, or evdi will not load."
echo "  Tip: log out and back in (or reboot) so the module/udev changes fully apply."
echo "  Remember: update the Linux package and the APK together (they share a session token)."
