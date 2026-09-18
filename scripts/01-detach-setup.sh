#!/usr/bin/env bash
#
# 01-detach-setup.sh — detaching the display, safely
#
#     bash scripts/01-detach-setup.sh        (as your normal user, NOT sudo)
#
# Installs surface-dtx-daemon, points GLVND at Mesa so nothing holds the
# discrete GPU at idle, lets the GPU power down, and installs a detach
# handler that unloads the NVIDIA driver before the latch opens — aborting
# with a readable notification if something is still using it.
#
# Needs no kernel change if /dev/surface/dtx already exists. Run
# scripts/00-survey.sh first to find out.
#
# Everything is reversible; the summary at the end says how.
#
# Part of https://github.com/<you>/surface-book-2-omarchy — MIT licensed.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mOK\033[0m    %s\n' "$*"; }
warn() { printf '    \033[1;33mWARN\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as your normal user, not with sudo. The AUR helper refuses to run as root."

# ---------------------------------------------------------------------------
say "Step 0: prerequisites"
# ---------------------------------------------------------------------------

[ -e /dev/surface/dtx ] || die "/dev/surface/dtx is missing. Your kernel has no DTX driver — do scripts/02-kernel-install.sh first."
ok "/dev/surface/dtx present"

AUR=""
for h in yay paru pikaur trizen; do command -v "$h" >/dev/null && { AUR="$h"; break; }; done
[ -n "$AUR" ] || die "No AUR helper found (yay, paru, ...). surface-dtx-daemon lives in the AUR."
ok "AUR helper: $AUR"

DGPU="$(lspci -Dn 2>/dev/null | awk '$2 ~ /^030[02]:/ && $3 ~ /^10de:/ { print $1; exit }')"
if [ -n "$DGPU" ]; then
    ok "discrete GPU: $DGPU  ($(lspci -s "${DGPU#0000:}" | cut -d: -f3- | sed 's/^ //'))"
else
    warn "No NVIDIA discrete GPU found. GPU handling will be skipped."
    warn "That is fine — it just means there is less that can go wrong."
fi

df -h /boot 2>/dev/null | sed 's/^/    /' || true

# ---------------------------------------------------------------------------
say "Step 1: snapshot"
# ---------------------------------------------------------------------------

if command -v snapper >/dev/null && sudo snapper -c root list >/dev/null 2>&1; then
    sudo snapper -c root create -d "before detach setup" && ok "snapshot created"
else
    warn "Snapper not available — you have no easy way back."
    printf '\nContinue anyway? Type exactly  yes  : '
    read -r a; [ "$a" = "yes" ] || die "Stopped."
fi

# ---------------------------------------------------------------------------
say "Step 2: surface-dtx-daemon"
# ---------------------------------------------------------------------------
echo "    From the AUR, maintained by qzed — the linux-surface lead developer."
echo "    Depends only on dbus and gcc-libs. It is not a kernel module."
echo

"$AUR" -S --needed surface-dtx-daemon || die "installation failed"
ok "$(pacman -Q surface-dtx-daemon)"

# ---------------------------------------------------------------------------
say "Step 3: keep the shipped handlers"
# ---------------------------------------------------------------------------

sudo mkdir -p /etc/surface-dtx
for f in detach.sh attach.sh detach_abort.sh; do
    if [ -f "/etc/surface-dtx/$f" ] && [ ! -f "/etc/surface-dtx/$f.orig" ]; then
        sudo cp -a "/etc/surface-dtx/$f" "/etc/surface-dtx/$f.orig"
        ok "kept original as /etc/surface-dtx/$f.orig"
    fi
done

# ---------------------------------------------------------------------------
if [ -n "$DGPU" ]; then
say "Step 4: point GLVND at Mesa"
# ---------------------------------------------------------------------------
echo "    NVIDIA's OpenGL libraries open the discrete GPU on every program"
echo "    start, just to enumerate it. That alone is enough to make the driver"
echo "    unloadable — and therefore to make detaching impossible."
echo
echo "    After this, programs use the Intel GPU by default. For the discrete"
echo "    one, prefix with:  nvidia-run <program>"
echo

MESA_EGL=/usr/share/glvnd/egl_vendor.d/50_mesa.json
INTEL_ICD=""
for c in /usr/share/vulkan/icd.d/intel_icd.x86_64.json /usr/share/vulkan/icd.d/intel_icd.json; do
    [ -f "$c" ] && { INTEL_ICD="$c"; break; }
done
[ -f "$MESA_EGL" ] || warn "$MESA_EGL not found — is mesa installed?"
[ -n "$INTEL_ICD" ] || warn "no Intel Vulkan ICD found — skipping VK_ICD_FILENAMES"
echo "    Using: $MESA_EGL"
echo "           ${INTEL_ICD:-(none)}"

if grep -q 'surface-book-2-omarchy' /etc/environment 2>/dev/null; then
    ok "/etc/environment already configured"
else
    sudo cp -a /etc/environment "/etc/environment.bak-${STAMP}" 2>/dev/null || true
    {
        printf '\n# --- surface-book-2-omarchy: default to the Intel GPU ---------------\n'
        printf '# Stops the NVIDIA libraries from opening the discrete GPU on every\n'
        printf '# program start, so it can be powered down before detaching.\n'
        printf '# Use "nvidia-run <program>" for the discrete GPU.\n'
        printf '__EGL_VENDOR_LIBRARY_FILENAMES=%s\n' "$MESA_EGL"
        printf '__GLX_VENDOR_LIBRARY_NAME=mesa\n'
        [ -n "$INTEL_ICD" ] && printf 'VK_ICD_FILENAMES=%s\n' "$INTEL_ICD"
        printf 'VDPAU_DRIVER=va_gl\n'
    } | sudo tee -a /etc/environment >/dev/null
    ok "/etc/environment extended (backup: /etc/environment.bak-${STAMP})"
fi

warn "Your desktop may override __GLX_VENDOR_LIBRARY_NAME. On Omarchy,"
warn "/usr/share/omarchy/default/hypr/nvidia.lua sets it back to 'nvidia'."
warn "That only affects GLX (X11/Xwayland), not Wayland, so it is usually"
warn "harmless — but an X11 OpenGL program will then block detaching."

# ---------------------------------------------------------------------------
say "Step 5: let the GPU power down"
# ---------------------------------------------------------------------------

sudo install -Dm644 "$REPO/files/udev/80-nvidia-runtime-pm.rules" \
    /etc/udev/rules.d/80-nvidia-runtime-pm.rules
ok "/etc/udev/rules.d/80-nvidia-runtime-pm.rules"

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=pci --attr-match=vendor=0x10de || true
echo auto | sudo tee "/sys/bus/pci/devices/${DGPU}/power/control" >/dev/null || true
printf '    power/control = %s\n' "$(cat "/sys/bus/pci/devices/${DGPU}/power/control")"
printf '    power_state   = %s\n' "$(cat "/sys/bus/pci/devices/${DGPU}/power_state")"

# ---------------------------------------------------------------------------
say "Step 6: nvidia-run"
# ---------------------------------------------------------------------------
sudo install -Dm755 "$REPO/files/bin/nvidia-run" /usr/local/bin/nvidia-run
ok "/usr/local/bin/nvidia-run"
fi   # end of GPU-only section

# ---------------------------------------------------------------------------
say "Step 7: detach and attach handlers"
# ---------------------------------------------------------------------------

sudo install -Dm755 "$REPO/files/surface-dtx/detach.sh" /etc/surface-dtx/detach.sh
sudo install -Dm755 "$REPO/files/surface-dtx/attach.sh" /etc/surface-dtx/attach.sh
ok "/etc/surface-dtx/detach.sh"
ok "/etc/surface-dtx/attach.sh"

echo "    Daemon configuration points at:"
grep -A1 '^\[handler' /etc/surface-dtx/surface-dtx-daemon.conf 2>/dev/null \
    | grep -E 'exec|handler' | sed 's/^/      /' || warn "could not read surface-dtx-daemon.conf"

# ---------------------------------------------------------------------------
say "Step 8: services"
# ---------------------------------------------------------------------------

sudo systemctl enable --now surface-dtx-daemon.service && ok "surface-dtx-daemon.service"
systemctl --user enable --now surface-dtx-userd.service && ok "surface-dtx-userd.service (notifications)" \
    || warn "user daemon not started — you will get no notifications"

# ---------------------------------------------------------------------------
say "Done — do not detach yet"
# ---------------------------------------------------------------------------
cat <<EOF_SUMMARY

    Installed / changed:
      /etc/environment                              (backup alongside)
      /etc/udev/rules.d/80-nvidia-runtime-pm.rules
      /etc/surface-dtx/detach.sh                    (original kept as .orig)
      /etc/surface-dtx/attach.sh                    (original kept as .orig)
      /usr/local/bin/nvidia-run
      services: surface-dtx-daemon, surface-dtx-userd

    NEXT — in this order:

    1. Log out and back in, or reboot.
       /etc/environment is only read at login, so your running compositor
       still holds the GPU until then.

       If your machine uses autologin, log out may NOT be enough: systemd
       keeps the user manager alive for UserStopDelaySec (10s by default),
       and autologin usually returns faster than that. Reboot instead.

    2. Check that nothing holds the GPU any more:

         cat /sys/bus/pci/devices/${DGPU:-<addr>}/power_state
         sudo /etc/surface-dtx/detach.sh; echo "exit: \$?"

       Expected: D3cold, and exit 0 with no notification.
       An exit of 1 with a notification naming a process means it worked
       correctly — that process is still using the GPU.

    3. Only then press the detach button for real.

    TO UNDO:
      sudo rm /etc/udev/rules.d/80-nvidia-runtime-pm.rules
      sudo cp /etc/surface-dtx/detach.sh.orig /etc/surface-dtx/detach.sh
      sudo cp /etc/surface-dtx/attach.sh.orig /etc/surface-dtx/attach.sh
      sudo rm /usr/local/bin/nvidia-run
      # remove the block at the end of /etc/environment

EOF_SUMMARY
