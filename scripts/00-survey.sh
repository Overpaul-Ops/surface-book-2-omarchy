#!/usr/bin/env bash
#
# 00-survey.sh — what does this machine actually look like?
#
# READ-ONLY. Changes nothing. Run this first, even if you intend to do
# everything by hand: it tells you which of this repository's assumptions
# hold on your device.
#
#     bash scripts/00-survey.sh
#     bash scripts/00-survey.sh > survey.txt    # to attach to an issue
#
# Some checks need root (on Omarchy /boot is mode 0700). The script asks for
# sudo once and skips those parts if you decline.
#
# Part of https://github.com/<you>/surface-book-2-omarchy — MIT licensed.

hdr() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

SUDO=""
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif sudo -n true 2>/dev/null; then
    SUDO="sudo"
else
    printf 'Some checks need root. Enter your password, or press Ctrl-C to skip them.\n'
    sudo -v 2>/dev/null && SUDO="sudo" || printf '\nContinuing without root; /boot checks will be skipped.\n'
fi
root_run() { [ -n "$SUDO" ] || { note "(needs root — skipped)"; return 1; }; $SUDO "$@"; }

hdr "Device"
cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null
cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null
note "Expected: Microsoft Corporation / Surface Book 2"

hdr "OS and kernel"
grep -E '^(PRETTY_NAME|BUILD_ID)=' /etc/os-release
echo "running: $(uname -r)"
echo "installed kernels:"
for d in /usr/lib/modules/*/; do
    [ -e "${d}pkgbase" ] && printf '  %-34s %s\n' "$(basename "$d")" "$(cat "${d}pkgbase")"
done

hdr "Surface driver stack in the running kernel"
lsmod | grep -i surface | awk '{printf "  %-30s %s users\n", $1, $3}' || echo "  none loaded"

hdr "Detach interface — the key question for step 1"
if [ -e /dev/surface/dtx ]; then
    ls -l /dev/surface/dtx
    echo "  -> present: detaching works WITHOUT changing the kernel"
else
    echo "  /dev/surface/dtx MISSING"
    echo "  -> your kernel has no DTX driver; do the kernel step first"
fi

hdr "Touchscreen"
lspci -nn 2>/dev/null | grep -i 'itouch' || echo "  no iTouch controller found"
ls /dev/hidraw* 2>/dev/null >/dev/null && for h in /sys/class/hidraw/hidraw*; do
    n=$(grep -h '^HID_NAME=' "$h/device/uevent" 2>/dev/null | cut -d= -f2-)
    printf '  %-10s %s\n' "$(basename "$h")" "$n"
done
grep -E '^N: Name=".*IPTS' /proc/bus/input/devices 2>/dev/null || echo "  no IPTS input devices (expected without linux-surface)"
echo "  note: iptsd 3.x uses /dev/hidraw*, NOT /dev/ipts* — an empty /dev/ipts* is normal"

hdr "Graphics"
lspci -Dnn | grep -Ei 'vga|3d controller|display'
DGPU=$(lspci -Dn 2>/dev/null | awk '$2 ~ /^030[02]:/ && $3 ~ /^10de:/ { print $1; exit }')
if [ -n "$DGPU" ]; then
    echo "  discrete GPU: $DGPU"
    for f in power_state power/control power/runtime_status; do
        [ -r "/sys/bus/pci/devices/$DGPU/$f" ] && printf '    %-22s %s\n' "$f" "$(cat "/sys/bus/pci/devices/$DGPU/$f")"
    done
    if [ "$(cat "/sys/bus/pci/devices/$DGPU/power/control" 2>/dev/null)" = "on" ]; then
        note "control 'on' means runtime power management is OFF: the card"
        note "never powers down and is still live when you detach. Step 1 fixes this."
    fi
else
    echo "  no NVIDIA discrete GPU found — the GPU parts of step 1 will be skipped"
fi
echo "  render nodes:"
ls -l /dev/dri/by-path/ 2>/dev/null | grep render | sed 's/^/    /'

hdr "Who is holding the discrete GPU open?"
if [ -n "$DGPU" ]; then
    rnode=$(readlink -f "/dev/dri/by-path/pci-${DGPU}-render" 2>/dev/null)
    # Collect first, then decide. A `for ... done | sort` runs in a subshell,
    # so a flag set inside it never reaches the test afterwards.
    holders=$(for p in /proc/[0-9]*; do
        comm=$(cat "$p/comm" 2>/dev/null) || continue
        for fd in "$p"/fd/*; do
            t=$(readlink "$fd" 2>/dev/null) || continue
            case "$t" in
                /dev/nvidia|/dev/nvidia[0-9]*|/dev/nvidiactl|/dev/nvidia-modeset|/dev/nvidia-uvm*)
                    echo "  $comm (PID ${p##*/})"; break ;;
            esac
            [ -n "$rnode" ] && [ "$t" = "$rnode" ] && { echo "  $comm (PID ${p##*/})"; break; }
        done
    done 2>/dev/null | sort -u)
    [ -n "$holders" ] && echo "$holders" || echo "  nobody — this is the goal"
    note "If your compositor is in this list, detaching will always be blocked."
    note "Step 1 fixes that by pointing GLVND at Mesa."
fi

hdr "Boot setup"
echo "  bootloader packages:"
pacman -Q 2>/dev/null | grep -EI 'limine|grub|systemd-boot|refind|efibootmgr' | sed 's/^/    /'
echo "  /boot:"
df -h /boot | sed 's/^/    /'
note "Each unified kernel image is ~150 MB and every snapshot keeps a copy."
note "Under 500 MB free, stop and clean up before adding a kernel."
root_run ls -l /boot/EFI/Linux/ 2>/dev/null | sed 's/^/    /'
echo "  limine config locations:"
root_run find /boot -iname 'limine.conf' 2>/dev/null | sed 's/^/    /'
note "More than one is a known trap: they drift apart and a kernel update"
note "can leave you with a config pointing at files that no longer exist."
echo "  BOOT_ORDER:"
grep -rhE '^BOOT_ORDER' /etc/limine-entry-tool.d/*.conf /etc/default/limine 2>/dev/null | sed 's/^/    /'
note "A '*' wildcard means linux-surface is placed automatically — no manual entry needed."

hdr "EFI boot order"
root_run efibootmgr 2>/dev/null | head -8 | sed 's/^/    /'
note "If something other than Limine is first, editing limine.conf changes nothing."

hdr "Secure Boot"
SBF=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)
if [ -n "$SBF" ]; then
    SB=$(od -An -t u1 "$SBF" 2>/dev/null | awk '{print $5}')
    [ "$SB" = "1" ] && echo "  ENABLED — linux-surface is unsigned and will not boot" \
                    || echo "  disabled — fine"
fi

hdr "Encryption and filesystem"
grep -oE 'cryptdevice=[^ ]*|rootflags=[^ ]*|root=[^ ]*' /proc/cmdline | sed 's/^/    /'
findmnt -no FSTYPE / | sed 's/^/    root fs: /'

hdr "Snapshots"
command -v snapper >/dev/null && root_run snapper -c root list 2>/dev/null | tail -6 | sed 's/^/    /' \
    || echo "  snapper not installed — you have no easy way back. Consider setting it up first."

hdr "Sensors (for auto-rotation)"
for d in /sys/bus/iio/devices/iio:device*; do
    [ -r "$d/name" ] && printf '  %-16s %s\n' "$(basename "$d")" "$(cat "$d/name")"
done
[ -e /sys/bus/iio/devices/iio:device0 ] || echo "  none — auto-rotation will not work"

hdr "AUR helper"
for h in yay paru pikaur trizen; do command -v "$h" >/dev/null && echo "  $h"; done

hdr "Summary"
printf '  %-38s %s\n' "detach without kernel change:" "$([ -e /dev/surface/dtx ] && echo YES || echo no)"
printf '  %-38s %s\n' "discrete GPU present:" "$([ -n "$DGPU" ] && echo "$DGPU" || echo no)"
printf '  %-38s %s\n' "touchscreen usable now:" "$(grep -q 'IPTSD Virtual' /proc/bus/input/devices 2>/dev/null && echo YES || echo "no — needs linux-surface")"
printf '  %-38s %s\n' "free on /boot:" "$(df -Pm /boot | awk 'NR==2{print $4" MB"}')"
echo
echo "Next: docs/01-survey.md explains what these numbers mean."
