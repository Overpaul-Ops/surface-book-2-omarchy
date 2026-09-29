#!/usr/bin/env bash
#
# 04-maintenance-setup.sh — a health check that runs itself after updates
#
#     bash scripts/04-maintenance-setup.sh      (as your normal user)
#
# Installs:
#   /usr/local/bin/surface-health-check         run it whenever you like
#   /etc/pacman.d/hooks/99-surface-health.hook  runs it automatically
#
# The hook fires after any transaction touching your kernels, the bootloader,
# DKMS or iptsd. It only reports — it can never make an update fail.
#
# This replaces the "remember to check these three things after every update"
# advice that every guide gives and nobody follows.
#
# Part of https://github.com/Overpaul-Ops/surface-book-2-omarchy — MIT licensed.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mOK\033[0m    %s\n' "$*"; }
die()  { printf '\n\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as your normal user, not with sudo."

say "Step 1: the check program"
sudo install -Dm755 "$REPO/files/bin/surface-health-check" /usr/local/bin/surface-health-check
ok "/usr/local/bin/surface-health-check"

say "Step 2: the pacman hook"
sudo install -Dm644 "$REPO/files/pacman/99-surface-health.hook" \
    /etc/pacman.d/hooks/99-surface-health.hook
ok "/etc/pacman.d/hooks/99-surface-health.hook"

echo
echo "    pacman runs hooks in alphabetical order, so this one lands after"
echo "    everything that rewrites the boot configuration:"
echo
for h in /etc/pacman.d/hooks/*.hook /usr/share/libalpm/hooks/*.hook; do
    [ -e "$h" ] || continue
    basename "$h"
done | sort | grep -E 'limine|mkinitcpio|dkms|surface' | sed 's/^/      /' || true
echo
echo "    It therefore sees the final state, not an intermediate one."

say "Step 3: baseline run"
sudo /usr/local/bin/surface-health-check || true

say "Done"
cat <<'EOF_SUMMARY'

    CHECK ANY TIME:
        sudo surface-health-check

    AUTOMATIC:
        Runs after every update that touches kernels, bootloader, DKMS or
        iptsd. Watch for the "Surface: ..." line at the end of the output.

    WHAT IT CHECKS:
        1. free space on /boot (each kernel image is ~150 MB, and every
           snapshot keeps a copy — this partition fills up quietly)
        2. a boot entry for every installed kernel, and cryptdevice= plus
           rootflags=subvol= in EVERY cmdline, including snapshot entries
        3. a kernel image on the ESP for every installed kernel
        4. that the firmware still starts your bootloader and not a kernel
           directly — otherwise editing the bootloader config does nothing
        5. DKMS modules built for every installed kernel
        6. surface-dtx-daemon, iio-sensor-proxy, iptsd
        7. which kernel you are on

    TO UNDO:
        sudo rm /etc/pacman.d/hooks/99-surface-health.hook
        sudo rm /usr/local/bin/surface-health-check

EOF_SUMMARY
