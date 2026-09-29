#!/usr/bin/env bash
#
# /etc/surface-dtx/detach.sh
#
# Run as root by surface-dtx-daemon when the detach button is pressed.
# The exit code decides what happens next:
#
#     exit 0    -> open the latch, the display may be removed
#     exit != 0 -> abort, the display stays locked
#
# On a Surface Book 2 the discrete GPU sits in the keyboard base and
# physically disappears from the PCI bus when you detach. A loaded driver
# must not experience that.
#
# The safety check here is the module unload itself: `modprobe -r` only
# succeeds when no process is using the GPU. If a game is running, the unload
# fails, we abort, and the user gets a notification naming the process.
#
# This is deliberately *not* the check the linux-surface wiki suggests
# (abort unless the GPU is already in D3cold). With the NVIDIA driver loaded
# and runtime PM off, the GPU sits at D0 permanently and that check blocks
# every detach forever.
#
# Part of https://github.com/Overpaul-Ops/surface-book-2-omarchy — MIT licensed.

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

# Leave empty to detect the discrete GPU automatically. Set it to a PCI
# address like "0000:02:00.0" to pin it.
DGPU_ADDR=""

# Set to 1 to additionally require the GPU to reach D3cold before unlocking.
# Off by default: an unloaded driver is the more direct and more reliable
# proof that nothing is touching the card. Some Pascal cards never report
# D3cold, and with this on you would never be able to detach.
STRICT_D3COLD=0

# Abort the detach if a mounted USB volume cannot be unmounted. The USB ports
# are in the base, so a half-written stick would be yanked out. Set to 0 to
# only warn.
ABORT_ON_BUSY_USB=1

# ---------------------------------------------------------------------------

log() { logger -t surface-dtx -- "$*"; }

# Send a desktop notification from this root context to the logged-in session.
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

# First NVIDIA display or 3D controller on the bus.
# Class 0300 = VGA controller, 0302 = 3D controller. Vendor 10de = NVIDIA.
detect_dgpu() {
    lspci -Dn 2>/dev/null | awk '$2 ~ /^030[02]:/ && $3 ~ /^10de:/ { print $1; exit }'
}

# Processes holding the GPU open, as "name (PID 1234)" per line.
#
# There is no "who is using the GPU" command. But on Linux the GPU is a file,
# and /proc/<pid>/fd/ lists every file a process has open. So: walk all
# processes and look for the device nodes.
gpu_holders() {
    local rnode p pid comm fd target
    rnode="$(readlink -f "/dev/dri/by-path/pci-${DGPU_ADDR}-render" 2>/dev/null)"
    for p in /proc/[0-9]*; do
        pid="${p##*/}"
        comm="$(cat "$p/comm" 2>/dev/null)" || continue
        for fd in "$p"/fd/*; do
            target="$(readlink "$fd" 2>/dev/null)" || continue
            case "$target" in
                /dev/nvidia|/dev/nvidia[0-9]*|/dev/nvidiactl|/dev/nvidia-modeset|/dev/nvidia-uvm*)
                    printf '%s (PID %s)\n' "$comm" "$pid"; break ;;
            esac
            if [ -n "$rnode" ] && [ "$target" = "$rnode" ]; then
                printf '%s (PID %s)\n' "$comm" "$pid"; break
            fi
        done
    done | sort -u
}

# ---------------------------------------------------------------------------
# 1. Unmount USB volumes
# ---------------------------------------------------------------------------

failed_umount=""
for usb_dev in /dev/disk/by-id/usb-*; do
    [ -e "$usb_dev" ] || continue
    dev="$(readlink -f "$usb_dev")"
    if mount -l | grep -q "^${dev}[[:space:]]"; then
        log "unmounting $dev"
        umount "$dev" 2>/dev/null || failed_umount="${failed_umount}${dev} "
    fi
done

if [ -n "$failed_umount" ]; then
    log "busy USB volumes: $failed_umount"
    notify critical "Detach aborted" \
        "These USB volumes are still in use and could not be unmounted:

${failed_umount}

They are probably open in a file manager."
    [ "$ABORT_ON_BUSY_USB" = "1" ] && exit 1
fi

# ---------------------------------------------------------------------------
# 2. Unload the NVIDIA driver
# ---------------------------------------------------------------------------

[ -n "$DGPU_ADDR" ] || DGPU_ADDR="$(detect_dgpu)"

if [ -z "$DGPU_ADDR" ]; then
    log "no NVIDIA dGPU found, skipping GPU handling"
elif [ ! -d "/sys/bus/pci/devices/${DGPU_ADDR}" ]; then
    log "dGPU ${DGPU_ADDR} not present, skipping GPU handling"
else
    DGPU_SYS="/sys/bus/pci/devices/${DGPU_ADDR}"

    if lsmod | grep -q '^nvidia '; then
        for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
            lsmod | grep -q "^${m} " && modprobe -r "$m" 2>/dev/null
        done

        if lsmod | grep -q '^nvidia '; then
            holders="$(gpu_holders)"
            [ -n "$holders" ] || holders="(no process identified — possibly a background service)"

            log "abort: nvidia driver busy. Held by: $(echo "$holders" | tr '\n' ',')"
            notify critical "Detach aborted" \
                "The graphics card is still in use and cannot be powered down.

Please close first:
${holders}"
            exit 1
        fi
        log "nvidia modules unloaded"
    fi

    # 3. Let the card power down
    [ -w "$DGPU_SYS/power/control" ] && echo auto > "$DGPU_SYS/power/control"

    state=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        state="$(cat "$DGPU_SYS/power_state" 2>/dev/null)"
        [ "$state" = "D3cold" ] && break
        sleep 0.3
    done
    log "dGPU power_state=$state"

    if [ "$state" != "D3cold" ] && [ "$STRICT_D3COLD" = "1" ]; then
        log "abort: dGPU in $state, not D3cold (STRICT_D3COLD=1)"
        notify critical "Detach aborted" \
            "The graphics card is in state ${state} instead of D3cold."
        exit 1
    fi
fi

log "ready to detach"
exit 0
