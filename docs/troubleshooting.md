# Troubleshooting

Symptoms, what they usually mean, and what to do. Start with:

```sh
sudo surface-health-check
```

If you have not installed it yet, it is in
[files/bin/surface-health-check](../files/bin/surface-health-check) and you can
run it straight from the clone.

---

## Booting

### The machine does not boot after installing linux-surface

Reboot, press an arrow key at the menu, pick your original kernel. It is
untouched and it works. Below it are the snapshots, which also boot.

This is exactly why `default_entry` is left pointing at the original kernel
until the new one has proven itself over several days.

Once you are back in, `sudo surface-health-check` will usually name the
problem, most often a boot entry whose `cmdline` lost `cryptdevice=` or
`rootflags=subvol=`.

### The boot menu does not show linux-surface

```sh
sudo limine-update
sudo surface-health-check
```

`limine-entry-tool` regenerates entries from the installed kernels. If the
entry is still missing afterwards, check `BOOT_ORDER`:

```sh
grep -rh BOOT_ORDER /etc/limine-entry-tool.d/*.conf /etc/default/limine
```

It needs a `*` wildcard, or an explicit `linux-surface`, for the new kernel to
be placed.

### Changes to the bootloader config have no effect

Your firmware is probably starting a kernel directly instead of the
bootloader.

```sh
sudo efibootmgr | head -5
```

If the first entry in `BootOrder` is not Limine, reorder it:

```sh
sudo efibootmgr -o <limine-number>,<the rest>
```

### The boot menu auto-boots before you can choose

Press an arrow key the moment it appears. To give yourself more time, set a
timeout in `/boot/limine.conf`:

```
timeout: 10
```

---

## Detaching

### Nothing happens when I press the detach button

```sh
systemctl is-active surface-dtx-daemon.service
journalctl -t surface-dtx -n 20
```

You can also trigger it over D-Bus, which tells you whether the button or the
daemon is at fault:

```sh
busctl call --system org.surface.dtx /org/surface/dtx org.surface.dtx Request
```

And read the current state:

```sh
busctl --system get-property org.surface.dtx /org/surface/dtx org.surface.dtx DeviceMode
busctl --system get-property org.surface.dtx /org/surface/dtx org.surface.dtx LatchStatus
```

### "Detach aborted", the graphics card is still in use

Working as intended. The notification names the processes. Close them and
press again.

If it names your compositor, the `/etc/environment` part of step 1 has not
taken effect. Reboot (not just log out, see
[findings #10](findings.md#10-logging-out-does-not-apply-a-group-change-when-autologin-is-on)),
then check:

```sh
echo "$__EGL_VENDOR_LIBRARY_FILENAMES"    # should point at 50_mesa.json
```

If it names an X11 program, remember that Omarchy sets
`__GLX_VENDOR_LIBRARY_NAME=nvidia` back in its Hyprland config. Either close
the program before detaching, or override that variable in your own Hyprland
config.

### Detaching is always refused, with no obvious reason

You are probably running the `D3cold`-only handler. Check:

```sh
cat /sys/bus/pci/devices/<addr>/power_state    # D0?
cat /sys/bus/pci/devices/<addr>/power/control  # "on"?
```

`D0` plus `on` means the card never powers down and that handler can never
succeed. Use the one in this repository instead, see
[findings #2](findings.md#2-the-suggested-detach-handler-blocks-every-detach).

### No notifications at all

```sh
systemctl --user is-active surface-dtx-userd.service
notify-send test "does this appear?"
```

The user daemon delivers them, and something must be listening on
`org.freedesktop.Notifications` (on Omarchy that is `quickshell`).

### The notification shows a black-and-pink checkerboard instead of an icon

That is the "icon not found" placeholder. `surface-dtx-userd` asks for the
icon name `input-tablet`, which not every icon theme has. Drop a copy into the
fallback theme:

```sh
mkdir -p ~/.local/share/icons/hicolor/scalable/devices
cp /usr/share/icons/Adwaita/scalable/devices/input-tablet.svg \
   ~/.local/share/icons/hicolor/scalable/devices/
```

`hicolor` is the last theme in every inheritance chain, and
`~/.local/share/icons` is searched before `/usr/share/icons`, so this survives
updates and theme changes.

### The keyboard or trackpad do not work after re-attaching

```sh
journalctl -t surface-dtx -n 20
grep -c 'Microsoft Surface Keyboard' /proc/bus/input/devices    # expect 7
```

If the discrete GPU did not come back, `attach.sh` says so. A reboot restores
it.

---

## Touchscreen

### No touch at all

First: are you on the right kernel?

```sh
uname -r     # must contain "-surface"
```

This is by far the most common cause. The default boot entry is the
distribution kernel, which has no IPTS driver.

Then:

```sh
systemctl list-units 'iptsd@*' --all
journalctl -u 'iptsd@*' -b
```

### Touch worked, then stopped after an update

The known one. See
[findings #9](findings.md#9-an-unrelated-update-silently-kills-the-touchscreen).

Immediate fix:

```sh
grep -l IPTS /sys/class/hidraw/*/device/uevent      # gives you hidrawN
sudo systemctl start iptsd@dev-hidrawN.service
```

Permanent fix: install the drop-in from
[files/systemd/10-iptsd-robust.conf](../files/systemd/10-iptsd-robust.conf),
which `scripts/03-tablet-setup.sh` does for you.

### `ls /dev/ipts*` finds nothing

Expected. iptsd 3.x uses `/dev/hidraw*`. See
[findings #8](findings.md#8-devipts-no-longer-exists).

### Touch is offset after rotating

The screen rotated but the touch transform did not follow. Omablet is supposed
to keep them in sync; check that auto-rotate is enabled in its panel rather
than the screen having been rotated some other way.

To see the current state:

```sh
hyprctl monitors | grep -E 'Monitor|transform'
hyprctl devices | grep -iA2 touch
```

---

## Tablet mode

### The on-screen keyboard types nothing

```sh
systemctl --user is-active ydotool.service
journalctl --user -u ydotool.service -b | tail
```

`failed to open uinput device: Permission denied` means your user is not in
the `input` group, or the change has not taken effect yet.

```sh
id | grep input          # is it in THIS session?
getent group input       # is it in the system database?
```

If it is in the database but not in your session, reboot. Logging out is
not enough with autologin, see
[findings #10](findings.md#10-logging-out-does-not-apply-a-group-change-when-autologin-is-on).

If the service is stuck in `failed` after enough restart attempts:

```sh
systemctl --user reset-failed ydotool.service
systemctl --user start ydotool.service
```

### Ordinary typing works but Super+key does not

That is exactly the split between the two tools: `wtype` handles text,
`ydotool` handles combinations the compositor grabs for itself. So `ydotool`
is the broken half, see above.

### The virtual trackpad does nothing

Same cause. Omaglide is entirely built on ydotool.

### Auto-rotation does nothing

```sh
systemctl is-active iio-sensor-proxy.service
monitor-sensor          # tilt the device, watch for events; Ctrl-C to stop
ls /sys/bus/iio/devices/*/name | xargs -I{} sh -c 'echo -n "{}: "; cat {}'
```

You need a `dev_rotation` sensor. Without it there is nothing to rotate by.

### The bar icons did not appear after installing the plugins

```sh
omarchy-plugin-list | grep frostmute
omarchy restart shell
```

If they are listed as `enabled` but invisible, log out and back in.

---

## Space and updates

### `/boot` is full

```sh
df -h /boot
sudo du -sh /boot/* | sort -h
sudo snapper -c root list
```

Each kernel image is around 150 MB, and `limine-snapper-sync` keeps a copy per
snapshot. Delete old snapshots:

```sh
sudo snapper -c root delete <number>
```

Then confirm the boot entries are still intact:

```sh
sudo surface-health-check
```

### An update ran and I want to be sure nothing broke

```sh
sudo surface-health-check
```

With the pacman hook installed this runs on its own; look for the
`Surface: ...` line at the end of the update output.

