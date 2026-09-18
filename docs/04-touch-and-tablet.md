# Step 4 — Touch and tablet mode

```sh
bash scripts/03-tablet-setup.sh
bash scripts/03-tablet-setup.sh --no-trackpad   # if you never need a pointer
```

Requires the linux-surface kernel from [step 3](03-kernel.md) to be booted.

## Touch needs nothing from you

Once you boot `linux-surface`, `iptsd` starts itself. It is a template unit
that udev activates when the device appears, and it picks the configuration
for your exact model:

```
iptsd: Loading config /usr/share/iptsd/surface-book-2-15.conf
iptsd: Connected to device 045E:0020
iptsd: Running in Touchscreen mode
```

The `systemctl enable iptsd` that guides tell you to run is unnecessary.

Four input devices appear:

```
IPTS 045E:0020 Touchscreen            the raw sensor
IPTS 045E:0020
IPTSD Virtual Touchscreen 045E:0020   processed finger input
IPTSD Virtual Stylus 045E:0020        the pen
```

The middle step matters. For IPTS the kernel only delivers a raw sensor image
— which areas are being pressed. `iptsd` turns that into fingers, palm
rejection and stylus pressure in userspace. That is why the kernel alone is
not enough.

```
touchscreen hardware
  └─ ipts.ko              raw data (only in linux-surface)
      └─ /dev/hidraw1
          └─ iptsd        turns pressure images into touches
              └─ IPTSD Virtual Touchscreen / Stylus
                  └─ your compositor
```

## What the script adds

**Packages**, all from the official Arch repositories — nothing compiled, no
AUR:

| | |
|---|---|
| `iio-sensor-proxy` | exposes the rotation sensor on D-Bus |
| `wtype` | types text into Wayland windows |
| `ydotool` | synthesises key combinations via `/dev/uinput` |

Two tools for what looks like one job, because Wayland deliberately forbids
one program sending keystrokes to another — that is how keyloggers work.
`wtype` uses the `virtual-keyboard` protocol, which compositors allow for
exactly this. `ydotool` goes through the kernel instead, which is needed for
combinations the compositor grabs for itself, like `Super`+key.

**Plugins** — three separate ones by [frostmute](https://github.com/frostmute):

| | |
|---|---|
| Omablet | rotation, auto-rotate, control panel |
| Omaqwerty | on-screen keyboard |
| Omaglide | virtual trackpad |

Omablet only *launches* the other two. Installing it alone gives you rotation
and no keyboard — see
[findings #11](findings.md#11-small-things).

**A drop-in for iptsd** that keeps the touchscreen alive when an unrelated
package installation reloads udev rules. Without it, touch dies silently after
some future update. See
[findings #9](findings.md#9-an-unrelated-update-silently-kills-the-touchscreen).

## The `input` group

`ydotool` needs `/dev/uinput`, which is `root:input` mode 0660. The script
asks before adding you, because it is a real change: members of `input` can
read every device under `/dev/input/`, which means any program running as you
could log your keystrokes.

On a single-user laptop this is common — several distributions do it by
default. Arch leaves it to you. Decline and the keyboard still types, but
`Super`+key and the whole trackpad will not work.

**It takes effect after a reboot, not after logging out** — see
[findings #10](findings.md#10-logging-out-does-not-apply-a-group-change-when-autologin-is-on).

## Testing

The keyboard can stay attached; no detaching needed.

- **Omaqwerty** — tap the icon, type into a text field. Then try a `Super`
  combination, which exercises ydotool specifically.
- **Omaglide** — one finger moves the pointer, tap is left click, **two-finger
  tap is right click**, two fingers dragging scrolls. Right click is something
  a bare touchscreen cannot do at all.
- **Omablet** — enable auto-rotate and tilt the device. Watch whether the
  *touch input* rotates with the screen, not just the image. That is the part
  that usually goes wrong.

## What is not installed

The PIN lock screen from
[omarchy-surface-touch](https://github.com/javon27/omarchy-surface-touch)
modifies `/etc/pam.d/`, i.e. how you authenticate. If that goes wrong you
cannot log into your own machine. Install it yourself, knowingly, or not at
all.
