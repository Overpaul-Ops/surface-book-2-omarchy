# Findings

Where the existing guidance is wrong, incomplete, or right for a different
machine. If you are adapting rather than following, this is the file to read.

Everything here was measured on one Surface Book 2 15" running Omarchy 4.0.4,
not recalled or assumed. Where a claim rests on reasoning rather than a
measurement, it says so.

---

## 1. The stock kernel may already do the hard part

The assumption in most guides is that you need `linux-surface` before anything
Surface-specific works. On this machine, Omarchy's own kernel already shipped
the complete Surface aggregator stack:

```
surface_aggregator (8 users), surface_aggregator_hub, surface_aggregator_registry,
surface_dtx, surface_hotplug, surface_acpi_notify, surface_gpe,
surface_hid, surface_hid_core, surface_kbd, surface_platform_profile,
surfacepro3_button
```

`/dev/surface/dtx` existed from the start. **Detaching therefore needed no
kernel change at all** — only a userspace daemon.

Check before you assume:

```sh
ls -l /dev/surface/dtx && echo "no kernel change needed for detaching"
```

What the stock kernel did *not* have is `ipts`/`ithc`. The touchscreen is the
only thing that genuinely requires `linux-surface`.

---

## 2. The suggested detach handler blocks every detach

The [linux-surface Runtime Power Management
wiki](https://github.com/linux-surface/surface-hotplug/wiki/Runtime-Power-Management)
suggests making `detach.sh` refuse unless the GPU is in `D3cold`:

```sh
if [ "$dgpu_state" != "D3cold" ]; then
    exit 1
fi
```

With the NVIDIA driver loaded and runtime PM off, the card sits at `D0`
permanently:

```
power_state          = D0
power/control        = on        <- runtime PM disabled
power/runtime_status = active
nvidia               refcount 20
```

So that handler aborts every single time, and nothing tells you why.

**What works instead:** unload the driver, and let the unload *be* the check.
`modprobe -r` only succeeds when nothing is using the GPU, so a running game
makes it fail and you abort with a message naming the process. The
linux-surface project says as much elsewhere: *"Unloading the module only
succeeds when no program is using the dGPU and is therefore a safe step to
avoid such crashes."*

See [files/surface-dtx/detach.sh](../files/surface-dtx/detach.sh).

---

## 3. Your compositor holds the GPU open even when it does not use it

Before any of this can work, nothing may hold the card at idle. On this
machine two processes did:

```
Hyprland (PID 1079)        -> /dev/nvidia0, /dev/nvidiactl, /dev/dri/renderD129
voxtype-osd-gtk (PID 12991) -> /dev/nvidia0, /dev/nvidiactl, /dev/nvidia-modeset
```

The obvious conclusion — "the desktop is rendering on the dGPU" — was wrong.
The Hyprland log says the opposite:

```
drm: Enumerated device .../0000:02:00.0/drm/card0
ERR drm: Skipping device .../drm/card0, not a KMS device
drm: Found 1 GPUs
drm: Starting backend for /dev/dri/card1, with driver i915
```

The compositor renders on Intel. The open file descriptors come from
**GLVND**, the dispatch layer that decides which OpenGL implementation a
program gets. By default it probes every vendor at startup, and NVIDIA's
probe opens the device.

**The fix is not to move the compositor.** It is to stop the NVIDIA libraries
being loaded at all, via `/etc/environment`:

```sh
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
__GLX_VENDOR_LIBRARY_NAME=mesa
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.json
VDPAU_DRIVER=va_gl
```

After a re-login the refcount dropped from 20 to 3 and no process held the
card. A useful side effect: the GPU now actually reaches `D3cold` when idle,
which on a laptop is real battery life.

Two caveats found the hard way:

- The wiki names `intel_icd.x86_64.json`. On this machine the file is
  `intel_icd.json`. **Check, do not copy.**
- Omarchy sets `__GLX_VENDOR_LIBRARY_NAME=nvidia` back in
  `/usr/share/omarchy/default/hypr/nvidia.lua`. Hyprland's `env` assignments
  are applied after `pam_env` and win. This only affects GLX (X11/Xwayland),
  not Wayland, so it is usually harmless — but an X11 OpenGL program will
  then hold the GPU and block detaching.

---

## 4. `find` will not locate the GPU's sysfs path

A command that appears in several guides:

```sh
find /sys/bus/pci/devices -name power_state -path '*<address>*'
```

returns nothing. The entries under `/sys/bus/pci/devices/` are symlinks, and
`find` does not follow symlinks without `-L`. Use the path directly:

```sh
/sys/bus/pci/devices/0000:02:00.0/power_state
```

Or detect it, which is what the scripts here do:

```sh
lspci -Dn | awk '$2 ~ /^030[02]:/ && $3 ~ /^10de:/ { print $1; exit }'
```

Class `0300` is a VGA controller, `0302` a 3D controller. The Surface Book 2's
GTX 1060 is `0302` — a filter for `0300` alone misses it.

---

## 5. linux-surface is older than your distribution kernel

Not newer. On this machine:

```
linux-omarchy   7.2.5
linux-surface   6.19.8
```

Nobody says this up front, and it is the real price of the touchscreen. So:
what does it actually cost?

Rather than guess, compare the drivers. Of **206 modules loaded** on the
running system, exactly **one** was missing from linux-surface:
`intel_pmc_pwrm_telemetry`, a power-telemetry module with no device function.

Three others *appeared* to be missing and were not — they are compiled into
the kernel rather than shipped as files. `modules.builtin` inside the package
settles it:

```
kernel/pinctrl/intel/pinctrl-sunrisepoint.ko
kernel/pinctrl/intel/pinctrl-intel.ko
kernel/lib/crypto/gf128mul.ko
kernel/crypto/aead.ko
kernel/fs/btrfs/btrfs.ko
```

**Comparing file listings is not enough.** A driver can be present as a
loadable `.ko` or built into the kernel image, and only the built-in one is
invisible to `ls`. The full list of 184 "missing" modules turned out to be
drivers for hardware this machine does not have — Asus, Lenovo, AyaNeo,
industrial sensors, other Wi-Fi chips.

How to check this yourself for your own kernel pair:

```sh
# what the package ships as modules
curl -s -O https://pkg.surfacelinux.com/arch/linux-surface.files
tar -xzOf linux-surface.files --wildcards 'linux-surface-*/files' \
  | grep -oE '[^/]+\.ko\.zst$' | sed 's/\.ko\.zst$//' | sort -u > surface-mods

# what you actually have loaded right now
lsmod | tail -n +2 | awk '{print $1}' | tr '_' '-' | sort -u > loaded

# the intersection is what you would lose
comm -12 loaded <(sed 's/_/-/g' surface-mods | sort -u)
```

Anything that looks missing, check against `modules.builtin` in the package
before believing it.

**One caution:** the kernel config at
`raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/arch/kernel/config`
does **not** match the shipped package. It reports `CONFIG_BTRFS_FS=m` and no
`CONFIG_HID_IPTS`, while the package contains no btrfs module and does contain
`ipts.ko`. Only `modules.builtin` from the package itself is authoritative.

---

## 6. The DKMS risk is smaller than it looks — because the kernel is older

Guides warn that installing a new kernel can break a proprietary NVIDIA driver
with `ERROR: module not found: 'nvidia'`. That applies to **precompiled**
module packages pinned to one kernel version.

With DKMS the driver is rebuilt per kernel, and because linux-surface is
*older* than the distribution kernel, a driver that already builds against the
newer one will almost certainly build against the older one. It did:

```
nvidia/580.178.04, 6.19.8-arch1-3-surface, x86_64: installed
nvidia/580.178.04, 7.2.5-3-omarchy,        x86_64: installed
```

No removal of NVIDIA was necessary, contrary to the advice in several guides.

---

## 7. On Omarchy, the boot entry writes itself

The commonly described procedure — copy the existing entry by hand, adapt the
paths, keep a backup because updates overwrite it — does not apply here.

`limine-entry-tool` generates entries for every installed kernel. The relevant
configuration lives in `/etc/default/limine` and `/etc/limine-entry-tool.d/`:

```sh
BOOT_ORDER="linux-t2, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"
KERNEL_CMDLINE[default]+=" cryptdevice=... rootflags=subvol=@ ..."
ENABLE_UKI=yes
```

`linux-surface` matches the `*` wildcard and is placed automatically **after**
`linux-omarchy`. `KERNEL_CMDLINE[default]` applies to every kernel, so the
LUKS and btrfs parameters come along by themselves. After installing, the new
entry was byte-identical to the old one apart from the image path.

**`default_entry` also stayed correct** without being touched. It is an index,
but the new entry was appended *after* the existing one, and an entry's
position cannot change because of something added later.

If you want the surface kernel as the default, do **not** edit
`default_entry` — an update will overwrite it. Use a drop-in:

```sh
# /etc/limine-entry-tool.d/zz-surface-first.conf
BOOT_ORDER="linux-surface, linux-t2, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"
```

then `sudo limine-update`. Same pattern as [Omarchy PR
#7857](https://github.com/omacom/omarchy/pull/7857).

---

## 8. `/dev/ipts*` no longer exists

Guides tell you to verify the touchscreen with `ls /dev/ipts*`. With **iptsd
3.x that path is gone** — it talks to the device through `/dev/hidraw*`
instead. An empty result is not a failure.

What you should see instead:

```
$ grep 'IPTS' /proc/bus/input/devices
N: Name="IPTS 045E:0020 Touchscreen"
N: Name="IPTSD Virtual Touchscreen 045E:0020"
N: Name="IPTSD Virtual Stylus 045E:0020"
```

Also: `systemctl enable iptsd` is unnecessary. It is a template unit started
by udev when the device appears:

```
/usr/lib/udev/rules.d/50-iptsd.rules:
  ENV{SYSTEMD_WANTS}+="iptsd@$result.service"
```

And `libinput list-devices` needs root — an empty listing as a normal user
means nothing. Use `/proc/bus/input/devices` or `hyprctl devices`.

---

## 9. An unrelated update silently kills the touchscreen

Observed: `iptsd` stopped during a package installation that had nothing to do
with it.

```
15:05:19  iptsd: Reading from file failed: Interrupted system call
15:05:19  systemd: Stopping Intel Precise Touch & Stylus Daemon...
15:05:21  Stopped.
```

Cause: the shipped unit has `StopWhenUnneeded=yes` and is pulled in by udev
via `SYSTEMD_WANTS`. Installing any package reloads udev rules, the "wants"
relationship briefly disappears, `StopWhenUnneeded` fires, and nothing starts
it again because no fresh `add` event follows.

Fix — a drop-in at
`/etc/systemd/system/iptsd@.service.d/10-iptsd-robust.conf`:

```ini
[Unit]
StopWhenUnneeded=no

[Service]
Restart=always
RestartSec=2
```

`BindsTo=%i.device` is left alone, so the service still stops correctly when
the device genuinely disappears. `Restart=always` additionally covers the
known linux-surface bug where the touchscreen stays dead after a detach and a
manual `systemctl restart iptsd` fixes it.

---

## 10. Logging out does not apply a group change when autologin is on

After `usermod -aG input`, the usual advice is to log out and back in. On this
machine that never worked, and the reason is worth knowing:

```
15:17:29  Removed session 1          <- log out
15:17:36  New session 4              <- autologin, 7 seconds later
UserStopDelaySec = 10                <- logind default
```

systemd keeps the per-user service manager alive for ten seconds after the
last session ends, in case another arrives. Autologin returns in seven. The
manager survives every logout — carrying its original supplementary groups —
and since the compositor runs under it, the whole graphical session inherits
the stale list.

```
$ ps -o lstart= -p $(pgrep -f 'systemd --user')
Fri Sep 18 14:38:42 2026            <- from before the usermod, still running
```

**Group changes need a reboot on such a system.** Environment variables do
not: `pam_env` reads `/etc/environment` fresh at every login. Two things that
look alike, with different lifetimes.

---

## 11. Small things

**The IPU3 cameras are not usable**, even though `/dev/video0` … `/dev/video13`
exist. Those are the raw pipeline nodes (`ipu3-imgu`, `Intel IPU3 CIO2`);
there is no sensor driver and no working libcamera pipeline. The device count
looks like success and is not.

**Only `s2idle` is available** — `cat /sys/power/mem_sleep` shows `[s2idle]`
with no alternative. Expect standby battery drain. Hibernate is the reliable
option and Omarchy sets it up already (`/swap/swapfile` plus `resume=` and
`resume_offset=` on the kernel command line).

**The Type Cover ID differs between models.** `omarchy-surface-touch` defaults
to `045E:09C0`; the Surface Book 2 keyboard base is `045e:0922`. Check yours
with `grep -B1 'Surface Keyboard' /proc/bus/input/devices`.

**"Omablet" is three plugins, not one.** Omablet is the control panel; it only
launches Omaqwerty (keyboard) and Omaglide (trackpad), which are separate
repositories. Installing Omablet alone gives you rotation and no keyboard.

**`/boot` fills up quietly.** Each unified kernel image is ~150 MB here, and
`limine-snapper-sync` keeps a copy per snapshot. Two kernels and six snapshots
is theoretically 1.8 GB on a 2 GB ESP. Watch it — that is check number one in
`surface-health-check`.

**Never name a shell function after a real command.** A function called `head`
used for section headings shadowed `/usr/bin/head`, so every `| head -1` in
the same script silently returned the function's output instead. The script
ran without error and produced nonsense. If you must, use `command head`.
