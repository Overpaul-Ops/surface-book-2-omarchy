#!/usr/bin/env bash
#
# /etc/surface-dtx/attach.sh
#
# Run as root after the display has been re-attached, and also when a detach
# was aborted after detach.sh had already succeeded. The exit code has no
# effect on the mechanism.
#
# Brings the discrete GPU back: waits for the PCI bus to re-enumerate the
# base, reloads the NVIDIA modules, and re-enables runtime power management.
#
# Part of https://github.com/Overpaul-Ops/surface-book-2-omarchy — MIT licensed.

DGPU_ADDR=""          # empty = detect automatically

log() { logger -t surface-dtx -- "$*"; }

notify() {
    local urgency="$1" title="$2" body="$3"
    local rt uid user
    for rt in /run/user/*; do
        [ -S "$rt/bus" ] || continue
        uid="${rt##*/}"
        case "$uid" in (*[!0-9]*) continue ;; esac
        [ "$uid" -ge 1000 ] 2>/dev/null || continue
        user="$(getent passwd "$uid" | cut -d: -f1)"
        [ -n "$user" ] || continue
        runuser -u "$user" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
            notify-send -a "Surface detach" -u "$urgency" -- "$title" "$body" \
            >/dev/null 2>&1 || true
    done
}

detect_dgpu() {
    lspci -Dn 2>/dev/null | awk '$2 ~ /^030[02]:/ && $3 ~ /^10de:/ { print $1; exit }'
}

# The base takes a moment to come back on the PCI bus.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$DGPU_ADDR" ] || DGPU_ADDR="$(detect_dgpu)"
    [ -n "$DGPU_ADDR" ] && [ -d "/sys/bus/pci/devices/${DGPU_ADDR}" ] && break
    sleep 1
done

if [ -z "$DGPU_ADDR" ] || [ ! -d "/sys/bus/pci/devices/${DGPU_ADDR}" ]; then
    log "no dGPU after re-attach"
    notify normal "Re-attached" \
        "The graphics card was not found. A reboot will bring it back if you need it."
    exit 0
fi

DGPU_SYS="/sys/bus/pci/devices/${DGPU_ADDR}"

if ! lsmod | grep -q '^nvidia '; then
    if modprobe nvidia_drm 2>/dev/null || modprobe nvidia 2>/dev/null; then
        log "nvidia modules reloaded"
    else
        log "could not reload nvidia modules"
        notify normal "Re-attached" \
            "The graphics card could not be re-initialised. A reboot will fix it."
        exit 0
    fi
fi

[ -w "$DGPU_SYS/power/control" ] && echo auto > "$DGPU_SYS/power/control"
log "re-attached, dGPU available again (power_state=$(cat "$DGPU_SYS/power_state" 2>/dev/null))"
exit 0
