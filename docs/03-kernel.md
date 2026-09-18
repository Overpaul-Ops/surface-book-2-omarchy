# Step 3 — The linux-surface kernel

```sh
bash scripts/02-kernel-install.sh
```

The only step that touches the boot chain, and the only one with real risk.
It stops and asks twice, and it never reboots.

## Why it is needed

The touchscreen hardware is present and idle, waiting for a driver that has
never been merged into the mainline kernel:

```
00:16.4 Intel iTouch Controller [8086:9d3e]     bound to mei_me
MEI client 0000:00:16.4-3e8d0870-271a-4208-8eb5-9acb9402ae04
```

Your distribution kernel has no `ipts` module. `linux-surface` does.

## What it costs

`linux-surface` is **older** than your distribution kernel, not newer. On the
reference machine, 6.19.8 against Omarchy's 7.2.5.

Measured, not guessed: of 206 loaded modules, exactly one was missing — an
Intel power-telemetry module with no device function. Everything else that
appeared missing was compiled into the kernel instead of shipped as a file.
See [findings #5](findings.md#5-linux-surface-is-older-than-your-distribution-kernel),
including how to run the comparison for your own pair of kernels.

## Both kernels coexist

```
Omarchy
  ├─ linux-omarchy      7.2.x     ← stays the default, no touchscreen
  ├─ linux-surface      6.19.x    ← touchscreen works
  └─ Snapshots
```

Same operating system, same files, same home directory, same everything —
only the kernel differs. `/etc/os-release` does not change. Your existing
entry is your way back from anything that goes wrong.

## The key fingerprint

The script stops and shows it before trusting the repository key:

```
pub   rsa4096 2020-01-20 [SC]
      87DEFA4AB94A99A4C8C3112556C464BAAC421453
uid                      linux-surface
```

The last 16 characters must be `56C464BAAC421453`, as published in the
[linux-surface installation
guide](https://github.com/linux-surface/linux-surface/wiki/Installation-and-Setup).
Adding a package repository means letting it install software as root, so
this is worth ten seconds of your attention.

Note that `pacman-key --add` and `pacman-key --lsign-key` are two separate
things: the first only stores the key, the second is what grants trust. The
script pauses between them on purpose.

## Verify before rebooting

The script prints everything you need. Check:

1. Is there an entry for `linux-surface`?
2. Does your original kernel still come first?
3. Does `default_entry` still point at it?
4. Does the new entry's `cmdline` contain the same `cryptdevice=` and
   `rootflags=subvol=` as the old one?

Point 4 is the one that would leave you with a system that cannot unlock its
own disk. On Omarchy the entry is generated automatically and came out
byte-identical — see
[findings #7](findings.md#7-on-omarchy-the-boot-entry-writes-itself) — but
check anyway.

## Then reboot

Press an arrow key as the menu appears to stop the countdown, pick
`linux-surface`, enter your disk password as usual.

The moment the password prompt appears, you already know bootloader, kernel
and initramfs all work.

If it does not boot: reboot, pick your original kernel. Nothing is lost.

## After booting

```sh
uname -r                    # contains "-surface"
ls /dev/hidraw*             # the touchscreen appears here
```

Not `/dev/ipts*` — that is gone in iptsd 3.x. See
[findings #8](findings.md#8-devipts-no-longer-exists).

## Making it the default

Not yet. Give it several days of ordinary use first. When you are ready, do
not edit `default_entry` — an update overwrites it. Use a drop-in:

```sh
sudo tee /etc/limine-entry-tool.d/zz-surface-first.conf <<'EOF'
BOOT_ORDER="linux-surface, linux-t2, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"
EOF
sudo limine-update
sudo surface-health-check
```

Your original kernel stays directly below it in the menu.
