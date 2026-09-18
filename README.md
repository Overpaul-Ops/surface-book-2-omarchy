# Surface Book 2 on Omarchy

Getting the detachable display, the touchscreen, the pen and tablet-mode
controls working on a **Microsoft Surface Book 2** running
[Omarchy](https://omarchy.org) 4.x — without breaking the installation you
already have.

---

## ⚠️ Read this first

**This was written by [Claude Code](https://claude.com/claude-code), working
on one real machine, in one long session with its owner.** Every command here
was actually run on that machine, and every claim was checked against it
rather than recalled from memory. That is the reason to trust it, and also the
reason to be careful: it is a sample size of one.

- **Tested on exactly one device:** Surface Book 2 15", Kaby Lake-R, GTX 1060
  Mobile, Omarchy 4.0.4, LUKS + btrfs, Limine, Secure Boot off.
- **Not tested on:** the 13.5" model, the GTX 1050 variant, Surface Book 1 or
  3, installations without LUKS, installations without Limine, or anything
  with Secure Boot enabled.
- **Everything here is reversible**, and every step says how. But this touches
  your kernel and your bootloader. Read before you run.
- **Take a snapshot first.** Every script in this repository does that for
  you if Snapper is present. Do not skip it.

If something here is wrong, please open an issue — a correction from a second
machine is worth more than anything else this repository could receive.

**Licence: MIT.** Use it, fork it, copy pieces into your own setup, publish
your own version. No attribution required, though a link back helps the next
person find it.

---

## Why this exists

When this was written there was no complete guide for this device. There were
pieces:

| Source | Covers | Gap |
|---|---|---|
| [linux-surface wiki](https://github.com/linux-surface/linux-surface/wiki) | kernel, iptsd, general Surface support | nothing Omarchy-specific |
| [Omarchy PR #7857](https://github.com/omacom/omarchy/pull/7857) | linux-surface as a boot option | **not merged**; touchscreen only, no dGPU, no detach |
| [javon27/omarchy-surface-touch](https://github.com/javon27/omarchy-surface-touch) | OSK, rotation, trackpad, PIN lock | built for Surface Pro; writes to `/etc/pam.d/`; Type Cover ID does not match the Book 2 |
| [frostmute/omarchy-omablet](https://github.com/frostmute/omarchy-omablet) | rotation, OSK, virtual trackpad | tablet mode only |

None of them covers the thing that makes the Surface Book 2 different from
every other Surface: **the discrete GPU and the second battery live in the
keyboard base, and the base physically disconnects while the machine is
running.** That is the part this repository is really about.

---

## What works after following this

| | |
|---|---|
| Detach and re-attach the display | ✅ with an automatic safety check |
| Discrete GPU powered down before detaching | ✅ refuses to unlock if something is using it |
| Touchscreen | ✅ |
| Pen | ✅ set up (untested — no pen was available) |
| On-screen keyboard | ✅ |
| Virtual trackpad, incl. right-click | ✅ |
| Auto-rotation with touch following | ✅ |
| Hibernate | ✅ (Omarchy already sets this up) |
| Cameras | ❌ IPU3 support is unfinished, on every Surface |
| Suspend battery life | ⚠️ Modern Standby only; expect drain |

---

## What you need to know before you start

**You will end up with two kernels.** Omarchy's own kernel stays installed and
stays the default. `linux-surface` is added *next to* it. You pick at boot.

```
Omarchy
  ├─ linux-omarchy      7.2.x     ← default, no touchscreen
  ├─ linux-surface      6.19.x    ← touchscreen works
  └─ Snapshots
```

This matters more than it sounds: **linux-surface is older than Omarchy's
kernel**, not newer. On this machine that cost exactly one driver — an Intel
power-telemetry module — out of 206 loaded. See
[docs/findings.md](docs/findings.md) for how that was measured. But it is the
honest price, and you should know about it before you start rather than after.

Keeping Omarchy's kernel as the default is deliberate: it is your way back
from anything that goes wrong.

---

## Quick start

Clone, then run the scripts in order. Each one stops and asks before it
changes anything important, and each one can be run again safely.

```sh
git clone https://github.com/<you>/surface-book-2-omarchy.git
cd surface-book-2-omarchy

bash scripts/00-survey.sh            # read-only: what does your machine look like?
bash scripts/01-detach-setup.sh      # detach + dGPU handling
bash scripts/02-kernel-install.sh    # linux-surface, then reboot and pick it
bash scripts/03-tablet-setup.sh      # on-screen keyboard, trackpad, rotation
bash scripts/04-maintenance-setup.sh # automatic health check after updates
```

**Run them as your normal user, not with `sudo`.** They call `sudo` themselves
where it is needed. `yay` refuses to run as root, and one of the steps needs
it.

Start with `00-survey.sh` even if you plan to do everything by hand. It
changes nothing and tells you which of the assumptions below hold on *your*
machine.

---

## The steps, in detail

Each of these is a standalone document. If you only want detaching and not the
touchscreen, stop after step 1 — that is a perfectly good place to stop, and
it needs no kernel change at all.

1. **[Survey](docs/01-survey.md)** — what your machine already has. On this
   device, Omarchy's stock kernel already contained the whole Surface
   aggregator stack including the detach driver.
2. **[Detaching](docs/02-detach.md)** — `surface-dtx-daemon` plus a handler
   that powers the discrete GPU down before unlocking the latch, and refuses
   to unlock when something is still using it.
3. **[The kernel](docs/03-kernel.md)** — adding `linux-surface` beside
   Omarchy's kernel, and why the Limine entry needs no manual editing.
4. **[Touch and tablet mode](docs/04-touch-and-tablet.md)** — `iptsd`,
   on-screen keyboard, virtual trackpad, auto-rotation.
5. **[Maintenance](docs/05-maintenance.md)** — a health check that runs itself
   after every kernel or bootloader update.

Two more worth reading:

- **[Findings](docs/findings.md)** — the places where the existing guides are
  wrong, incomplete, or right for a different Surface. This is the most useful
  file here if you are adapting rather than following.
- **[Troubleshooting](docs/troubleshooting.md)** — symptoms and what they mean.

---

## The one thing people get wrong

The obvious detach handler — the one the linux-surface wiki suggests — checks
whether the GPU is in `D3cold` and aborts if it is not:

```sh
if [ "$dgpu_state" != "D3cold" ]; then
    exit 1
fi
```

On a machine with the NVIDIA driver loaded and runtime power management off,
the GPU sits at `D0` permanently. That handler blocks **every** detach,
forever, and it is not obvious why.

The handler in this repository does the opposite: it *actively unloads* the
NVIDIA modules. That is the safety check, because unloading only succeeds when
no process is using the GPU. If a game is running, the unload fails, the
handler aborts, and you get a notification naming the process:

```
Detach aborted

The graphics card is still in use and cannot be powered down.

Please close first:
steam (PID 4711)
```

For this to work at all, nothing may hold the GPU open at idle — and by
default, NVIDIA's OpenGL libraries open it on *every* program start just to
look at it. Fixing that is the other half of step 1.

---

## Credits

This stands entirely on other people's work:

- **[linux-surface](https://github.com/linux-surface/linux-surface)** — the
  kernel patches, `iptsd`, and `surface-dtx-daemon`. None of this exists
  without them.
- **[Omarchy](https://omarchy.org)** — and specifically `limine-entry-tool`,
  which turned the scariest part of this (a hand-written bootloader entry that
  disappears on update) into something that handles itself.
- **[frostmute](https://github.com/frostmute)** — Omablet, Omaqwerty and
  Omaglide, used unchanged for tablet mode.
- **[javon27](https://github.com/javon27)** — omarchy-surface-touch, whose
  approach to the on-screen keyboard and rotation informed this even where it
  was not used directly.

---

## Contributing

Corrections from other machines are the most valuable thing you can send. If
you run this on a 13.5", a GTX 1050 model, or without LUKS, please open an
issue saying what differed — even if everything worked.

The output of `bash scripts/00-survey.sh` is a good thing to attach. It is
read-only and prints no secrets, but read it before you paste it.
