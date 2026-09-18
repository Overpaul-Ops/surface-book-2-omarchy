#!/usr/bin/env bash
#
# 03-tablet-setup.sh — on-screen keyboard, virtual trackpad, auto-rotation
#
#     bash scripts/03-tablet-setup.sh                 (as your normal user)
#     bash scripts/03-tablet-setup.sh --no-trackpad   skip the virtual trackpad
#
# Installs iio-sensor-proxy, wtype and ydotool from the official Arch repos,
# then three Omarchy plugins by frostmute. Also hardens iptsd against an
# unrelated-update-kills-the-touchscreen failure.
#
# Deliberately NOT installed: the PIN lock screen from omarchy-surface-touch.
# It modifies /etc/pam.d/, i.e. how you authenticate. If you want it, install
# it yourself, knowingly.
#
# Part of https://github.com/<you>/surface-book-2-omarchy — MIT licensed.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WANT_TRACKPAD=1
[ "${1:-}" = "--no-trackpad" ] && WANT_TRACKPAD=0

PKGS=(iio-sensor-proxy wtype ydotool)
P_OMABLET="https://github.com/frostmute/omarchy-omablet.git"
P_OMAQWERTY="https://github.com/frostmute/omarchy-omaqwerty.git"
P_OMAGLIDE="https://github.com/frostmute/omarchy-omaglide.git"
ID_OMABLET="io.github.frostmute.tablet-mode"
ID_OMAQWERTY="io.github.frostmute.tablet-keyboard"
ID_OMAGLIDE="io.github.frostmute.onscreen-trackpad"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mOK\033[0m    %s\n' "$*"; }
warn() { printf '    \033[1;33mWARN\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as your normal user, not with sudo."

# ---------------------------------------------------------------------------
say "Step 0: prerequisites"
# ---------------------------------------------------------------------------

case "$(uname -r)" in
    *surface*) ok "running the linux-surface kernel" ;;
    *) warn "You are NOT on the linux-surface kernel."
       warn "This will install fine, but touch — and therefore all of it —"
       warn "only works once you boot linux-surface." ;;
esac

if [ -e /sys/bus/iio/devices/iio:device0/name ]; then
    for d in /sys/bus/iio/devices/iio:device*; do
        [ -r "$d/name" ] && printf '    %-16s %s\n' "$(basename "$d")" "$(cat "$d/name")"
    done
    grep -qx 'dev_rotation' /sys/bus/iio/devices/iio:device*/name 2>/dev/null \
        && ok "rotation sensor present" \
        || warn "no 'dev_rotation' sensor — auto-rotation may not work"
else
    warn "no iio sensors — auto-rotation will not work"
fi

command -v omarchy-plugin-add >/dev/null || die "omarchy-plugin-add not found. This step is Omarchy-specific."
ok "Omarchy plugin system present"

# ---------------------------------------------------------------------------
say "Step 1: snapshot"
# ---------------------------------------------------------------------------
if command -v snapper >/dev/null && sudo snapper -c root list >/dev/null 2>&1; then
    sudo snapper -c root create -d "before tablet setup" && ok "snapshot created"
else
    warn "Snapper not available — continuing without a snapshot"
fi

# ---------------------------------------------------------------------------
say "Step 2: packages from the official repos"
# ---------------------------------------------------------------------------
echo "    iio-sensor-proxy  exposes the rotation sensor on D-Bus"
echo "    wtype             types text into Wayland windows"
echo "    ydotool           synthesises key combinations via /dev/uinput"
echo
echo "    Two tools for what looks like one job, because Wayland deliberately"
echo "    forbids one program sending keystrokes to another. wtype uses the"
echo "    virtual-keyboard protocol; ydotool goes through the kernel for"
echo "    combinations the compositor itself grabs, like Super+<key>."
echo

sudo pacman -S --needed "${PKGS[@]}" || die "package installation failed"
for p in "${PKGS[@]}"; do ok "$(pacman -Q "$p")"; done

# ---------------------------------------------------------------------------
say "Step 3: services"
# ---------------------------------------------------------------------------

# iio-sensor-proxy is a D-Bus-activated SYSTEM service on Arch, despite what
# some plugin READMEs claim about --user.
if systemctl list-unit-files iio-sensor-proxy.service 2>/dev/null | grep -q iio-sensor-proxy; then
    sudo systemctl enable --now iio-sensor-proxy.service && ok "iio-sensor-proxy.service" \
        || warn "iio-sensor-proxy.service did not start"
else
    warn "no iio-sensor-proxy unit — it is probably D-Bus activated on demand"
fi

# ydotool needs access to /dev/uinput, which is root:input 0660.
if ! id -nG | tr ' ' '\n' | grep -qx input; then
    echo
    warn "Your user is not in the 'input' group. ydotool cannot open /dev/uinput"
    warn "without it, so Super+<key> from the on-screen keyboard and the whole"
    warn "virtual trackpad will not work."
    echo
    echo "    What this grants: read access to every device under /dev/input/,"
    echo "    which means any program running as you could log your keystrokes."
    echo "    On a single-user laptop this is common practice — many distributions"
    echo "    do it by default — but it is a real change and you should decide it."
    echo
    printf '    Add your user to the "input" group? Type exactly  yes  (anything else skips): '
    read -r a
    if [ "$a" = "yes" ]; then
        sudo usermod -aG input "$USER" && ok "added to 'input' — takes effect after a REBOOT"
        warn "Logging out is often NOT enough: with autologin, systemd keeps the"
        warn "user manager alive (UserStopDelaySec, 10s) and you get back sooner."
        warn "Group membership is fixed when that manager starts. Reboot."
    else
        warn "skipped — ydotool will stay broken, and so will the trackpad"
    fi
else
    ok "already in the 'input' group"
fi

YD=""
for u in ydotool.service ydotoold.service; do
    systemctl --user list-unit-files "$u" 2>/dev/null | grep -q "$u" && { YD="$u"; break; }
done
if [ -n "$YD" ]; then
    systemctl --user reset-failed "$YD" 2>/dev/null || true
    systemctl --user enable --now "$YD" 2>/dev/null && ok "$YD" \
        || warn "$YD not running yet — expected until you reboot"
else
    warn "no ydotool user unit found"
fi

# ---------------------------------------------------------------------------
say "Step 4: keep the touchscreen alive across updates"
# ---------------------------------------------------------------------------
echo "    The shipped iptsd unit has StopWhenUnneeded=yes. Reloading udev"
echo "    rules — which pacman does on nearly every install — briefly drops"
echo "    the binding and stops iptsd for good. The touchscreen then dies"
echo "    after an unrelated update, with no obvious cause."
echo "    The same drop-in also covers a known linux-surface bug where the"
echo "    touchscreen stays dead after detaching."
echo

sudo install -Dm644 "$REPO/files/systemd/10-iptsd-robust.conf" \
    /etc/systemd/system/iptsd@.service.d/10-iptsd-robust.conf
sudo systemctl daemon-reload
ok "/etc/systemd/system/iptsd@.service.d/10-iptsd-robust.conf"

HID=""
for h in /sys/class/hidraw/hidraw*; do
    grep -qs 'HID_NAME=.*IPTS' "$h/device/uevent" && { HID="$(basename "$h")"; break; }
done
if [ -n "$HID" ]; then
    sudo systemctl start "iptsd@dev-${HID}.service" 2>/dev/null || true
    systemctl is-active "iptsd@dev-${HID}.service" >/dev/null 2>&1 \
        && ok "iptsd@dev-${HID}.service running" \
        || warn "iptsd@dev-${HID}.service not running"
else
    warn "no IPTS hidraw device — boot the linux-surface kernel first"
fi

# ---------------------------------------------------------------------------
say "Step 5: plugins"
# ---------------------------------------------------------------------------
echo "    Three separate plugins by frostmute. Omablet is the control panel;"
echo "    it only launches the other two, so it does not give you a keyboard"
echo "    on its own."
echo

add_plugin() {
    local url="$1" id="$2" label="$3"
    if [ -d "$HOME/.config/omarchy/plugins/$id" ]; then
        ok "$label already installed"
    else
        omarchy-plugin-add "$url" --enable || die "$label failed to install"
        ok "$label installed"
    fi
}

add_plugin "$P_OMABLET"   "$ID_OMABLET"   "Omablet (rotation, control panel)"
add_plugin "$P_OMAQWERTY" "$ID_OMAQWERTY" "Omaqwerty (on-screen keyboard)"
if [ "$WANT_TRACKPAD" = "1" ]; then
    add_plugin "$P_OMAGLIDE" "$ID_OMAGLIDE" "Omaglide (virtual trackpad)"
else
    echo "    Omaglide skipped (--no-trackpad)."
    echo "    Add it later with:"
    echo "      omarchy-plugin-add $P_OMAGLIDE --enable"
fi

# ---------------------------------------------------------------------------
say "Step 6: restart the shell"
# ---------------------------------------------------------------------------
omarchy-restart-shell && ok "shell restarted" || warn "restart failed — log out and back in"

# ---------------------------------------------------------------------------
say "Done"
# ---------------------------------------------------------------------------
cat <<EOF_SUMMARY

    You should now have new icons in the bar:
      Omablet     rotation, auto-rotate on/off
      Omaqwerty   on-screen keyboard, sizes S/M/L/Full
$([ "$WANT_TRACKPAD" = "1" ] && echo "      Omaglide    virtual trackpad")

    IF YOU JUST JOINED THE 'input' GROUP: reboot before testing. ydotool
    cannot work until then, and without ydotool the trackpad does nothing
    and Super+<key> on the keyboard does nothing.

    TEST (keyboard can stay attached):
      - tap the Omaqwerty icon, type into a text field
      - tap the Omaglide icon: one finger moves the pointer, tap = left click,
        TWO-finger tap = right click, two fingers dragging = scroll
      - tap the Omablet icon, enable auto-rotate, tilt the device.
        Watch whether touch input rotates WITH the screen — that is the part
        that usually goes wrong.

    TO UNDO:
      omarchy plugin remove $ID_OMABLET
      omarchy plugin remove $ID_OMAQWERTY
      omarchy plugin remove $ID_OMAGLIDE
      sudo rm -r /etc/systemd/system/iptsd@.service.d
      sudo pacman -Rns iio-sensor-proxy wtype ydotool
      sudo gpasswd -d "$USER" input

EOF_SUMMARY
