#!/usr/bin/env bash
# install-uscreen-fedora.sh — UScreen (Android tablet as a second monitor),
# Linux side. Standalone: not part of fedora-setup.sh.
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
#   6. Keeps the tablet app in step: saves uscreen-<ver>.apk in ~/Downloads
#      and installs it over adb on a connected tablet (retried every run
#      until a tablet has it). A new RPM is not installed without its APK.
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
SUDO_KEEPALIVE=$!

WORKDIR="$(mktemp -d -t uscreen-install.XXXXXX)"
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT
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
if ! rpm -q "kernel-devel-${KVER}" >/dev/null 2>&1; then
    sudo dnf install -y "kernel-devel-${KVER}" || {
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

# Kernels that have headers installed (/lib/modules/<k>/build is a dangling
# symlink without kernel-devel). After a kernel update without a reboot the
# running kernel is not among them, but the new one is.
kernels_with_headers() {
    local d
    for d in /lib/modules/*/build; do
        [[ -e "$d/Makefile" ]] && basename "$(dirname "$d")"
    done
    return 0
}

# Build and install evdi/<ver> for every kernel with headers; succeeds if at
# least one build worked. Replaces evdi's 'make install_dkms', which only ever
# builds for the running kernel and so fails right after a kernel update.
# Kernels that already have it are skipped. EVDI_ALL_OK=1 when every kernel
# with headers ends up with it.
EVDI_ALL_OK=0
evdi_build_all() {
    local ver="$1" k ok=0
    EVDI_ALL_OK=1
    while read -r k; do
        [[ -n "$k" ]] || continue
        # Captured, never piped into grep -q: under pipefail an early grep
        # exit can make a match look like a failure.
        local st
        st="$(dkms status "evdi/${ver}" -k "$k" 2>/dev/null || true)"
        if [[ $st == *installed* ]]; then
            ok=1
        elif sudo dkms install "evdi/${ver}" -k "$k"; then
            ok=1
        else
            EVDI_ALL_OK=0
            warn "evdi ${ver} did not build for $k — see /var/lib/dkms/evdi/${ver}/build/make.log"
        fi
    done < <(kernels_with_headers)
    [[ $ok -eq 1 ]]
}

# GNOME 51 fix (DisplayLink/evdi#597): evdi accepts framebuffers in 32 bpp
# formats its planes cannot scan out (e.g. 10-bit AR30). Mutter 51 picks
# exactly that for secondary GPUs, never falls back, and the evdi screen stays
# black with "Page flip failed" in the journal. Reject unsupported formats in
# ADDFB2, as proposed upstream. Skipped if upstream already does it.
EVDI_PATCH_MARK="drm_any_plane_has_format"
patch_evdi() {   # <module dir>
    local f="$1/evdi_fb.c"
    grep -q "$EVDI_PATCH_MARK" "$f" && return 0
    awk -v mark="$EVDI_PATCH_MARK" '
        { print }
        /Unsupported bpp/ { inbpp = 1 }
        inbpp && /^\t}$/ {
            print ""
            print "\t/* GNOME 51: refuse formats no plane supports (evdi#597) */"
            print "\tif (!" mark "(dev, mode_cmd->pixel_format, mode_cmd->modifier[0]))"
            print "\t\treturn ERR_PTR(-EINVAL);"
            inbpp = 0
        }' "$f" > "$f.new" && mv "$f.new" "$f"
    if grep -q "$EVDI_PATCH_MARK" "$f"; then
        echo "Patched evdi for GNOME 51 (evdi#597)."
    else
        warn "Could not apply the GNOME 51 evdi patch; building it unpatched (GNOME may show a black screen)."
    fi
    # Remember this source was handled, patched or not, so a release the
    # patch no longer fits is not rebuilt on every run.
    : > "$1/uscreen-patch-checked"
    return 0
}
evdi_patched() {
    [[ -e "/usr/src/evdi-$1/uscreen-patch-checked" ]] \
        || grep -q "$EVDI_PATCH_MARK" "/usr/src/evdi-$1/evdi_fb.c" 2>/dev/null
}
EVDI_REBUILT=0

# Newest version actually installed for some kernel — the fallback if the new
# one fails. Versions that are only 'added' (a failed earlier run) don't count.
DKMS_EVDI="$(dkms status evdi 2>/dev/null || true)"
OLD_EVDI="$(grep 'installed' <<<"$DKMS_EVDI" | grep -oE '^evdi/[^,: ]+' | sort -V | tail -n1 || true)"

info "evdi ${EVDI_VER} via DKMS"
if grep -qE "^evdi/${EVDI_VER//./\\.}[,:].*installed" <<<"$DKMS_EVDI" \
   && evdi_patched "$EVDI_VER"; then
    echo "evdi ${EVDI_VER} already installed with DKMS."
elif { sudo dkms remove "evdi/${EVDI_VER}" --all >/dev/null 2>&1 || true; } \
     && sudo rm -rf "/usr/src/evdi-${EVDI_VER}" \
     && git clone --depth 1 --branch "$EVDI_TAG" https://github.com/DisplayLink/evdi.git \
     && patch_evdi evdi/module \
     && sudo dkms add "$PWD/evdi/module" \
     && evdi_build_all "$EVDI_VER"; then
    EVDI_REBUILT=1
    # Drop older evdi versions so DKMS does not build several on every kernel
    # update — but only once the new one is in place for every kernel, so a
    # kernel the new version failed on keeps its working module.
    if [[ $EVDI_ALL_OK -eq 1 ]]; then
        { dkms status evdi 2>/dev/null | grep -oE '^evdi/[^,: ]+' || true; } | sort -u | while read -r old; do
            [[ "$old" == "evdi/${EVDI_VER}" ]] || sudo dkms remove "$old" --all || true
        done
    else
        warn "evdi ${EVDI_VER} did not build for every kernel; keeping older versions alongside it."
    fi
elif [[ -n "$OLD_EVDI" && "$OLD_EVDI" != "evdi/${EVDI_VER}" ]]; then
    # A brand-new evdi release that does not build yet must not take UScreen
    # down with it: keep using the version that already works.
    sudo dkms remove "evdi/${EVDI_VER}" --all >/dev/null 2>&1 || true
    sudo rm -rf "/usr/src/evdi-${EVDI_VER}"
    warn "evdi ${EVDI_VER} could not be fetched or built — keeping ${OLD_EVDI#evdi/}."
    EVDI_VER="${OLD_EVDI#evdi/}"
else
    die "evdi ${EVDI_VER} could not be fetched or built. Check /var/lib/dkms/evdi/${EVDI_VER}/build/make.log, or try another version with --evdi vX.Y.Z."
fi

# Installed is not the same as built for every kernel: after a kernel update
# DKMS may not have rebuilt it yet (or the build failed back then). Kernels
# that already have it are skipped, so this is a no-op when all is well.
evdi_build_all "$EVDI_VER" || warn "evdi ${EVDI_VER} is not built for any installed kernel."

SB_ON=0
SB_STATE="$(mokutil --sb-state 2>/dev/null || true)"
[[ ${SB_STATE,,} == *enabled* ]] && SB_ON=1
MOK=/var/lib/dkms/mok.pub
MOK_PENDING=0

# What UScreen's own install.sh sets up and the RPM does not: evdi must be
# loaded with devices (by default it creates none, so there is no virtual
# connector and no second screen), evdi + uinput must load at boot, and
# /dev/uinput must be writable by the logged-in user.
info "evdi / uinput system config"
EVDI_CHANGED=0
write_if_diff() {   # <file> <content>
    if [[ "$(cat "$1" 2>/dev/null || true)" != "$2" ]]; then
        printf '%s\n' "$2" | sudo tee "$1" >/dev/null
        echo "Wrote $1"
        EVDI_CHANGED=1
    fi
}
write_if_diff /etc/modprobe.d/uscreen-evdi.conf "options evdi initial_device_count=2"
write_if_diff /etc/modules-load.d/uscreen.conf $'evdi\nuinput'
if [[ ! -e /etc/udev/rules.d/60-uscreen-uinput.rules && ! -e /usr/lib/udev/rules.d/60-uscreen-uinput.rules ]]; then
    write_if_diff /etc/udev/rules.d/60-uscreen-uinput.rules \
        'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"'
    sudo udevadm control --reload-rules && sudo udevadm trigger || true
fi
sudo modprobe uinput 2>/dev/null || true
[[ $EVDI_CHANGED -eq 0 ]] && echo "Already configured."

# Mutter 51 leaks a dma-buf on every frame it copies to a DisplayLink/evdi
# output (mutter#5101, fixed by mutter!5300), eating GPU memory fast once the
# screen works. Copying through the CPU avoids that path. Only affects
# secondary-GPU outputs. Remove once Fedora's mutter carries the fix.
MUTTER_CHANGED=0
MUTTER_ENV=/etc/environment.d/90-uscreen-mutter.conf
MUTTER_VER="$(rpm -q --qf '%{VERSION}' mutter 2>/dev/null || true)"
if [[ "$MUTTER_VER" == 51.* ]]; then
    sudo mkdir -p /etc/environment.d
    if [[ "$(cat "$MUTTER_ENV" 2>/dev/null || true)" != "MUTTER_DEBUG_MULTI_GPU_FORCE_COPY_MODE=primary-gpu-cpu" ]]; then
        echo "MUTTER_DEBUG_MULTI_GPU_FORCE_COPY_MODE=primary-gpu-cpu" | sudo tee "$MUTTER_ENV" >/dev/null
        echo "Wrote $MUTTER_ENV (mutter $MUTTER_VER copy-mode workaround)."
        MUTTER_CHANGED=1
    fi
elif [[ -e "$MUTTER_ENV" ]]; then
    # Newer mutter: the leak is fixed, GPU copying is cheaper again.
    sudo rm -f "$MUTTER_ENV"
    echo "Removed $MUTTER_ENV (mutter ${MUTTER_VER:-not installed} no longer needs it)."
    MUTTER_CHANGED=1
fi

evdi_count() { cat /sys/devices/evdi/count 2>/dev/null || echo 0; }

# /sys/module rather than 'lsmod | grep -q': under pipefail, grep quitting
# early can make the pipeline report "not loaded" when it is.
if [[ -d /sys/module/evdi ]]; then
    echo "evdi module already loaded ($(evdi_count) device(s))."
    if [[ "$(evdi_count)" -lt 1 ]]; then
        # Loaded earlier without initial_device_count: reload so the option
        # applies, or, if something holds it, add a device for this boot.
        if { sudo modprobe -r evdi && sudo modprobe evdi; } 2>/dev/null; then
            echo "evdi reloaded ($(evdi_count) device(s))."
        elif echo 1 | sudo tee /sys/devices/evdi/add >/dev/null; then
            echo "Added an evdi device for this boot ($(evdi_count) device(s))."
        else
            warn "evdi has no devices. Reboot so /etc/modprobe.d/uscreen-evdi.conf applies."
        fi
        EVDI_CHANGED=1
    fi
elif sudo modprobe evdi 2>/dev/null; then
    echo "evdi module loaded."
elif [[ $SB_ON -eq 1 && -r $MOK && "$(sudo mokutil --test-key "$MOK" 2>&1 || true)" != *"already enrolled"* ]]; then
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

# ---------- 4. Release: Linux RPM + tablet APK ----------
# The RPM and the APK share a session token, so they are handled as a pair:
#   - the API lists the real asset names (no guessing '-1.x86_64'),
#   - both are downloaded and checksummed BEFORE anything is installed,
#   - a new RPM is not installed while its APK is unavailable (that would
#     break the tablet connection until a matching APK appears),
#   - the APK is pushed to every connected, authorised tablet over adb, and
#     re-tried on later runs until one has it — independent of the RPM.
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/uscreen-installer"
mkdir -p "$STATE"
APK_DIR="$HOME/Downloads"

info "Finding UScreen release ${TAG:-(latest)}"
if [[ -n "$TAG" ]]; then
    API="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
else
    API="https://api.github.com/repos/${REPO}/releases/latest"
fi
REL="$(curl -fsSL --max-time 30 "$API" 2>/dev/null || true)"
RPM_URL="" APK_URL="" SUMS_URL=""
if [[ -n "$REL" ]]; then
    TAG="$(grep -m1 '"tag_name"' <<<"$REL" | cut -d'"' -f4 || true)"
    RPM_URL="$(grep -m1 -oE 'https://[^"]+/uscreen-[^"/]+\.x86_64\.rpm' <<<"$REL" || true)"
    APK_URL="$(grep -m1 -oE 'https://[^"]+\.apk' <<<"$REL" || true)"
    SUMS_URL="$(grep -m1 -oE 'https://[^"]+/SHA256SUMS' <<<"$REL" || true)"
fi
if [[ -z "$RPM_URL" ]]; then
    # API rate limit (60 requests/hour without a token) or a network hiccup:
    # fall back to the release redirect and the usual asset names.
    if [[ -z "$TAG" ]]; then
        URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" || true)"
        TAG="${URL##*/}"
    fi
    [[ "$TAG" == v* ]] || die "Could not determine the UScreen release (got: '${TAG}')."
    BASE="https://github.com/${REPO}/releases/download/${TAG}"
    RPM_URL="$BASE/uscreen-${TAG#v}-1.x86_64.rpm"
    APK_URL="$BASE/uscreen.apk"
    SUMS_URL="$BASE/SHA256SUMS"
fi
VER="${TAG#v}"
RPM="${RPM_URL##*/}"
APK_FILE="$APK_DIR/uscreen-${VER}.apk"
echo "Release: $TAG"

CUR_VER="$(rpm -q --qf '%{VERSION}' uscreen 2>/dev/null || true)"
[[ $CUR_VER == *"not installed"* ]] && CUR_VER=""
NEED_RPM=0; [[ "$CUR_VER" == "$VER" ]] || NEED_RPM=1
NEED_APK=0; [[ $GET_APK -eq 1 && ! -s "$APK_FILE" ]] && NEED_APK=1

if [[ $NEED_RPM -eq 0 && $NEED_APK -eq 0 ]]; then
    echo "uscreen $VER is installed and its APK is saved — nothing to download."
fi

APK_OK=0; [[ $GET_APK -eq 1 && -s "$APK_FILE" ]] && APK_OK=1
if [[ $NEED_APK -eq 1 ]]; then
    info "Downloading the tablet app (${APK_URL##*/})"
    curl -fL --progress-bar -o "${APK_URL##*/}" "$APK_URL" && APK_OK=1 \
        || warn "APK download failed: $APK_URL"
fi
if [[ $NEED_RPM -eq 1 ]]; then
    info "Downloading $RPM"
    curl -fL --progress-bar -o "$RPM" "$RPM_URL" || die "Download failed: $RPM_URL"
fi

# Verify whatever was downloaded against the release's SHA256SUMS.
if [[ $NEED_RPM -eq 1 || $NEED_APK -eq 1 ]]; then
    if [[ -n "$SUMS_URL" ]] && curl -fsL -o SHA256SUMS "$SUMS_URL"; then
        info "Verifying checksums"
        LISTED=0
        for f in "$RPM" "${APK_URL##*/}"; do
            [[ -s "$f" ]] || continue
            # Exact file-name match (a regex would treat the dots as wildcards).
            if awk -v f="$f" '{ n = $2; sub(/^\*/, "", n) } n == f { found = 1 } END { exit !found }' SHA256SUMS; then
                LISTED=1
            else
                warn "SHA256SUMS does not list $f; not verified."
            fi
        done
        # --ignore-missing: SHA256SUMS lists assets that were not downloaded.
        if [[ $LISTED -eq 1 ]]; then
            sha256sum -c --ignore-missing --quiet SHA256SUMS \
                || die "Checksum mismatch — aborting, nothing was installed."
        fi
    else
        warn "No SHA256SUMS for $TAG; downloads not verified."
    fi
fi

UPDATED=0
if [[ $NEED_RPM -eq 1 ]]; then
    if [[ $GET_APK -eq 1 && $APK_OK -eq 0 && -n "$CUR_VER" ]]; then
        warn "Keeping uscreen $CUR_VER: the $VER APK could not be downloaded, and a"
        warn "PC/tablet version mismatch breaks the connection. Run this again later."
    else
        info "Installing UScreen $VER"
        sudo dnf install -y "./$RPM"
        UPDATED=1
    fi
fi

if [[ $NEED_APK -eq 1 && $APK_OK -eq 1 && -s "${APK_URL##*/}" ]]; then
    mkdir -p "$APK_DIR"
    cp "${APK_URL##*/}" "$APK_FILE"
    # Older copies saved by this script are useless now (wrong token).
    for f in "$APK_DIR"/uscreen-*.apk; do
        [[ "$f" == "$APK_FILE" || ! -e "$f" ]] || rm -f "$f"
    done
    echo "Tablet app saved to: $APK_FILE"
fi

# ---------- 5. User service ----------
info "uscreen user service"
systemctl --user daemon-reload
if [[ $UPDATED -eq 1 || $EVDI_CHANGED -eq 1 ]]; then
    systemctl --user enable uscreen && systemctl --user restart uscreen \
      || warn "Service failed to start — run 'uscreen doctor'."
    # udev rule for /dev/uinput needs a reload/re-login to apply
    sudo udevadm control --reload-rules && sudo udevadm trigger || true
else
    systemctl --user enable --now uscreen || warn "Service failed to start — run 'uscreen doctor'."
fi

# ---------- 6. APK onto the tablet ----------
# Installed with adb whenever the tablet is plugged in and authorised; the
# version pushed last is remembered, so a run without the tablet just says
# so and the next run with it attached finishes the job.
TABLET_STAMP="$STATE/apk-on-tablet"
TABLET_VER="$(cat "$TABLET_STAMP" 2>/dev/null || true)"
if [[ $GET_APK -eq 1 && -s "$APK_FILE" && "$TABLET_VER" != "$VER" ]]; then
    info "Tablet app $VER"
    DEVS=""
    command -v adb >/dev/null && DEVS="$(adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }' || true)"
    if [[ -z "$DEVS" ]]; then
        warn "No authorised tablet on USB, so the tablet still has ${TABLET_VER:-an unknown version}."
        warn "Plug it in (allow USB debugging) and run this script again, or:  adb install -r $APK_FILE"
    else
        PUSHED=0
        while read -r dev; do
            if adb -s "$dev" install -r "$APK_FILE" >/dev/null; then
                echo "Installed uscreen $VER on tablet $dev."
                PUSHED=1
            else
                warn "adb install failed on $dev — install $APK_FILE on it by hand."
            fi
        done <<<"$DEVS"
        [[ $PUSHED -eq 1 ]] && printf '%s\n' "$VER" >"$TABLET_STAMP"
    fi
fi

# ---------- done ----------
REBOOT_MSG=""
if [[ $EVDI_REBUILT -eq 1 && -d /sys/module/evdi ]]; then
    REBOOT_MSG="evdi was rebuilt but the old module is still loaded (GNOME holds it): REBOOT so the new one is used."
elif [[ $MUTTER_CHANGED -eq 1 ]]; then
    REBOOT_MSG="Log out and back in (or reboot) so GNOME picks up $MUTTER_ENV."
fi

if [[ $UPDATED -eq 1 ]]; then
    info "UScreen updated to $VER."
else
    info "UScreen is at ${CUR_VER:-$VER}."
fi
[[ -z "$REBOOT_MSG" ]] || warn "$REBOOT_MSG"
[[ $MOK_PENDING -eq 0 ]] || warn "Secure Boot: enroll the DKMS key (see the warning above) and reboot, or evdi will not load."
if [[ -z "$CUR_VER" && $UPDATED -eq 1 ]]; then
    cat <<EOF

First-time setup on the tablet:
  1. Enable USB debugging (Settings → About → tap Build number 7× → Developer options).
  2. Plug it in, accept "Allow USB debugging", and run this script again —
     it installs the app over USB. It then shows up as a new monitor.
  3. If not:  uscreen doctor
EOF
fi
