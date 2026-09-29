# Step 5: Keeping it working

```sh
bash scripts/04-maintenance-setup.sh
```

Every guide ends with "after each update, check these three things". Nobody
does. This installs a check that runs itself.

## What gets installed

`/usr/local/bin/surface-health-check`, which you can run whenever you like:

```sh
sudo surface-health-check
```

`/etc/pacman.d/hooks/99-surface-health.hook`, which runs it automatically
after any transaction touching your kernels, the bootloader, DKMS or iptsd.
It only reports; it can never make an update fail.

The `99-` prefix matters. pacman runs hooks alphabetically, so this lands after
everything that rewrites the boot configuration:

```
60-limine-mkinitcpio-remove-pre
70-dkms-install / 70-dkms-upgrade
80-limine-efi-deploy
90-mkinitcpio-install
99-omarchy-limine                  ← regenerates limine.conf
99-surface-health                  ← checks the result
```

It is the last thing that runs.

## What it checks

1. Free space on `/boot`. Each kernel image is ~150 MB and every snapshot
   keeps a copy. This partition fills up quietly and the symptom is a system
   that stops booting.
2. A boot entry per installed kernel, and `cryptdevice=` plus
   `rootflags=subvol=` in *every* `cmdline`, including snapshot entries, where
   a broken one is a trap you only find when you need it.
3. A kernel image on the ESP for every installed kernel.
4. That the firmware still starts your bootloader and not a kernel directly.
   If it does not, editing the bootloader config changes nothing, and that is
   a genuinely confusing failure.
5. DKMS modules built for every kernel. Miss this and your graphics driver is
   silently absent on one of them.
6. The services `surface-dtx-daemon`, `iio-sensor-proxy` and `iptsd`.
7. Which kernel you are on.

Exit code 0 if everything is fine, 1 otherwise, so you can use it in your own
scripts. In `--hook` mode it always exits 0.

## Known quirks of this hardware

Nothing to fix, just things to know.

Standby drains the battery. `cat /sys/power/mem_sleep` shows `[s2idle]` with
no alternative: Modern Standby only, no deep sleep. Hibernate is reliable and
Omarchy already sets it up:

```sh
swapon --show
grep -o 'resume[^ ]*' /proc/cmdline
```

The cameras do not work. `/dev/video0`…`13` exist but they are raw IPU3
pipeline nodes with no sensor driver behind them. This affects every Surface
under Linux, not just this one.

Wi-Fi is the historically weakest part. The Marvell 88W8897 has a reputation
for occasional dropouts. If it happens, it is probably not your configuration.

## When something does go wrong

```sh
sudo surface-health-check
```

then [troubleshooting.md](troubleshooting.md). Your ordered fallbacks are:

1. Reboot and pick your distribution kernel, which is untouched.
2. Boot a snapshot from the bootloader menu.
3. Undo individual changes; every step document lists how.
