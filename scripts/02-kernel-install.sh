#!/usr/bin/env bash
#
# 02-kernel-install.sh — add the linux-surface kernel beside your existing one
#
#     bash scripts/02-kernel-install.sh      (as your normal user, NOT sudo)
#
# This is the only step that touches the boot chain. It stops and asks twice:
# once so you can verify the repository key fingerprint, once before
# installing. It never reboots.
#
# Your existing kernel stays installed and stays the default. linux-surface is
# added next to it, and you pick at boot.
#
# Part of https://github.com/Overpaul-Ops/surface-book-2-omarchy — MIT licensed.

set -euo pipefail

KEYID="56C464BAAC421453"
KEYURL="https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc"
REPOSERVER="https://pkg.surfacelinux.com/arch/"
STAMP="$(date +%Y%m%d-%H%M%S)"
PKGS=(linux-surface linux-surface-headers iptsd surface-ipts-firmware)

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mOK\033[0m    %s\n' "$*"; }
warn() { printf '    \033[1;33mWARN\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

ask() {
    printf '\n\033[1;33m%s\033[0m\n' "$1"
    printf 'Continue? Type exactly  yes  : '
    read -r a
    [ "$a" = "yes" ] || die "Stopped by you. Nothing further was changed."
}

[ "$(id -u)" -ne 0 ] || die "Run as your normal user, not with sudo."

# ---------------------------------------------------------------------------
say "Step 0: prerequisites"
# ---------------------------------------------------------------------------

echo "    running kernel: $(uname -r)"
echo "    installed kernels:"
for d in /usr/lib/modules/*/; do
    [ -e "${d}pkgbase" ] && printf '      %-34s %s\n' "$(basename "$d")" "$(cat "${d}pkgbase")"
done

SBF=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)
if [ -n "$SBF" ]; then
    SB=$(od -An -t u1 "$SBF" 2>/dev/null | awk '{print $5}' || true)
    [ "$SB" = "1" ] && die "Secure Boot is ENABLED. linux-surface is unsigned and will not boot. Disable it in firmware, or use linux-surface-secureboot-mok."
    ok "Secure Boot disabled"
fi

FREE_MB=$(df -Pm /boot | awk 'NR==2{print $4}')
echo "    free on /boot: ${FREE_MB} MB"
[ "$FREE_MB" -lt 500 ] && die "Under 500 MB free on /boot. A unified kernel image needs ~150 MB, and every snapshot keeps a copy. Clean up first."
ok "enough space"

# ---------------------------------------------------------------------------
say "Step 1: snapshot"
# ---------------------------------------------------------------------------

if command -v snapper >/dev/null && sudo snapper -c root list >/dev/null 2>&1; then
    sudo snapper -c root create -d "before linux-surface" && ok "snapshot created"
    sudo snapper -c root list | tail -4 | sed 's/^/    /'
else
    warn "Snapper not available. This is the one step where you really want it."
    ask "Continue without a snapshot?"
fi

# ---------------------------------------------------------------------------
say "Step 2: repository key"
# ---------------------------------------------------------------------------

if sudo pacman-key --list-keys "$KEYID" >/dev/null 2>&1; then
    ok "key already in the keyring"
else
    echo "    Fetching from: $KEYURL"
    curl -fsSL "$KEYURL" | sudo pacman-key --add - || die "could not import the key"
    ok "key imported (NOT yet trusted)"
fi

echo
echo "    ==================== FINGERPRINT ===================="
sudo pacman-key --finger "$KEYID" | sed 's/^/    /'
echo "    ====================================================="
echo
echo "    Expected key ID: $KEYID"
echo "    Published at https://github.com/linux-surface/linux-surface/wiki/Installation-and-Setup"
echo
echo "    The last 16 characters of the fingerprint above must match that ID."
echo "    This is the moment a tampered key would be visible. Look at it."

ask "Does the fingerprint match? Answering yes signs the key locally and marks it trusted."

sudo pacman-key --lsign-key "$KEYID" || die "signing failed"
ok "key signed"

# ---------------------------------------------------------------------------
say "Step 3: repository"
# ---------------------------------------------------------------------------

if grep -q '^\[linux-surface\]' /etc/pacman.conf; then
    ok "already present in /etc/pacman.conf"
else
    sudo cp -a /etc/pacman.conf "/etc/pacman.conf.bak-${STAMP}"
    printf '\n[linux-surface]\nServer = %s\n' "$REPOSERVER" | sudo tee -a /etc/pacman.conf >/dev/null
    ok "added (backup: /etc/pacman.conf.bak-${STAMP})"
fi

# ---------------------------------------------------------------------------
say "Step 4: what will be installed"
# ---------------------------------------------------------------------------

sudo pacman -Sy || die "database sync failed"
echo
for p in "${PKGS[@]}"; do
    # pacman -Si exits 1 for an unknown package; pipefail would abort here.
    info=$(pacman -Si "$p" 2>/dev/null | awk -F': +' '/^Repository/{r=$2} /^Version/{v=$2} /^Installed Size/{s=$2} END{printf "%-14s %-20s %s", r, v, s}' || true)
    printf '      %-26s %s\n' "$p" "${info:-NOT FOUND}"
done
echo
echo "    Note: linux-surface is usually OLDER than your distribution kernel."
echo "    On the reference machine it was 6.19.8 against Omarchy's 7.2.5."
echo "    See docs/findings.md for what that actually costs."
echo
echo "    What will NOT happen:"
echo "      - your existing kernel is not removed"
echo "      - its boot entry and image are untouched"
echo "      - the default boot entry is not changed"
echo
echo "    What this triggers:"
echo "      - mkinitcpio builds a second kernel image (~150 MB on /boot)"
echo "      - DKMS rebuilds out-of-tree modules for the new kernel"
echo "      - your bootloader tool adds the menu entry itself"

ask "Install now?"

# ---------------------------------------------------------------------------
say "Step 5: install"
# ---------------------------------------------------------------------------
echo "    Read the mkinitcpio output. Warnings about missing firmware for"
echo "    hardware you do not have are normal. Errors about missing MODULES"
echo "    are not."
echo

sudo pacman -Syu --needed "${PKGS[@]}" || die "installation failed. The snapshot from step 1 is there."
ok "installed"

# ---------------------------------------------------------------------------
say "Step 6: verify BEFORE rebooting"
# ---------------------------------------------------------------------------

if [ -x /usr/local/bin/surface-health-check ]; then
    sudo /usr/local/bin/surface-health-check || true
else
    echo "    (scripts/04-maintenance-setup.sh installs a proper check; basic output follows)"
    echo "    --- kernels ---"
    for d in /usr/lib/modules/*/; do [ -e "${d}pkgbase" ] && echo "      $(basename "$d")"; done
    echo "    --- DKMS ---"
    dkms status 2>/dev/null | sed 's/^/      /' || true
    echo "    --- kernel images ---"
    sudo ls -lh /boot/EFI/Linux/ 2>/dev/null | sed 's/^/      /' || true
    echo "    --- boot menu ---"
    sudo grep -nE '^\s*(//|default_entry)' /boot/limine.conf 2>/dev/null | sed 's/^/      /' || true
    echo "    --- /boot ---"
    df -h /boot | tail -1 | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
say "Done — verify, then reboot yourself"
# ---------------------------------------------------------------------------
cat <<'EOF_SUMMARY'

    CHECK THE OUTPUT ABOVE BEFORE REBOOTING:

      1. Is there an entry for linux-surface in the boot menu?
      2. Does your original kernel still come FIRST?
      3. Does default_entry still point at the original kernel?
      4. Does the new entry's cmdline contain the same cryptdevice= and
         rootflags=subvol= as the old one? Without them an encrypted root
         will not start.
      5. Is there still room on /boot?

    Only then:

        reboot

    Press an arrow key as soon as the boot menu appears, to stop the
    countdown, then pick linux-surface.

    Your original entry stays in the menu. That is your way back — along
    with the snapshots below it.

    After booting:
        uname -r                  must contain "-surface"
        ls /dev/hidraw*           the touchscreen shows up here
                                  (NOT /dev/ipts* — that is gone in iptsd 3.x)

    TO UNDO:
      sudo pacman -Rns linux-surface linux-surface-headers iptsd surface-ipts-firmware
      # then remove the [linux-surface] block from /etc/pacman.conf
      # (a backup is next to it)

EOF_SUMMARY
