# Surface Book 2 on Omarchy

Getting the detachable display, the touchscreen, the pen and tablet-mode
controls working on a Microsoft Surface Book 2 running
[Omarchy](https://omarchy.org) 4.x, without breaking the installation you
already have.

---

## Read this first

This was written by [Claude Code](https://claude.com/claude-code), working on
one real machine in one long session with its owner. Every command here was
run on that machine, and every claim was checked against it rather than
recalled from memory. That is the reason to trust it, and also the reason to
be careful: the sample size is one.

- Tested on exactly one device, specified in full below.
- Not tested on the 13.5" model, the GTX 1050 variant, Surface Book 1 or 3,
  installations without LUKS, installations without Limine, or anything with
  Secure Boot enabled.
- Everything here is reversible, and every step says how. But this touches
  your kernel and your bootloader. Read before you run.
- Take a snapshot first. Every script in this repository does that for you if
  Snapper is present. Do not skip it.

Licence: MIT. Use it, fork it, copy pieces into your own setup, publish your
own version. No attribution required, though a link back helps the next person
find it.

### The machine this was built on

Where yours differs, expect the details to differ with it.

| | |
|---|---|
| Model | Microsoft Surface Book 2, 15" |
| CPU | Intel Core i7-8650U (Kaby Lake-R), 4 cores / 8 threads |
| Integrated GPU | Intel UHD Graphics 620 (`8086:5917`) |
| Discrete GPU | NVIDIA GeForce GTX 1060 Mobile (`10de:1c20`), in the keyboard base |
| Memory | 16 GB |
| Storage | Samsung NVMe, 256 GB |
| Internal display | 3240x2160, eDP |
| Distribution | Omarchy 4.0.4 |
| Kernels | linux-omarchy 7.2.5 and linux-surface 6.19.8, side by side |
| Disk layout | LUKS + btrfs, subvolume `@` |
| Bootloader | Limine, unified kernel images enabled |
| Secure Boot | disabled |

---

## Credits

This stands entirely on other people's work:

- [linux-surface](https://github.com/linux-surface/linux-surface) supplied the
  kernel patches, `iptsd` and `surface-dtx-daemon`. None of this exists
  without them.
- [Omarchy](https://omarchy.org), and specifically `limine-entry-tool`, which
  turned the scariest part of this (a hand-written bootloader entry that
  disappears on update) into something that handles itself.
- [frostmute](https://github.com/frostmute) wrote Omablet, Omaqwerty and
  Omaglide, used unchanged for tablet mode.
- [javon27](https://github.com/javon27) wrote omarchy-surface-touch, whose
  approach to the on-screen keyboard and rotation informed this even where it
  was not used directly.

---

## Why this exists

When this was written there was no complete guide for this device. There were
pieces:

| Source | Covers | Gap |
|---|---|---|
| [linux-surface wiki](https://github.com/linux-surface/linux-surface/wiki) | kernel, iptsd, general Surface support | nothing Omarchy-specific |
| [Omarchy PR #7857](https://github.com/omacom/omarchy/pull/7857) | linux-surface as a boot option | not merged; touchscreen only, no dGPU, no detach |
| [javon27/omarchy-surface-touch](https://github.com/javon27/omarchy-surface-touch) | OSK, rotation, trackpad, PIN lock | built for Surface Pro; writes to `/etc/pam.d/`; Type Cover ID does not match the Book 2 |
| [frostmute/omarchy-omablet](https://github.com/frostmute/omarchy-omablet) | rotation, OSK, virtual trackpad | tablet mode only |

None of them covers what makes the Surface Book 2 different from every other
Surface: the discrete GPU and the second battery live in the keyboard base,
and the base physically disconnects while the machine is running. That is what
this repository is mostly about.

---

## What works after following this

| | |
|---|---|
| Detach and re-attach the display | ✅ with an automatic safety check |
| Discrete GPU powered down before detaching | ✅ refuses to unlock if something is using it |
| Touchscreen | ✅ |
| Pen | ✅ set up but untested; no pen was available |
| On-screen keyboard | ✅ |
| Virtual trackpad, incl. right-click | ✅ |
| Auto-rotation with touch following | ✅ |
| Hibernate | ✅ (Omarchy already sets this up) |
| Cameras | ❌ IPU3 support is unfinished, on every Surface |
| Suspend battery life | ⚠️ Modern Standby only; expect drain |

---

## What you need to know before you start

You will end up with two kernels. Omarchy's own kernel stays installed and
stays the default. `linux-surface` is added *next to* it. You pick at boot.

```
Omarchy
  ├─ linux-omarchy      7.2.x     ← default, no touchscreen
  ├─ linux-surface      6.19.x    ← touchscreen works
  └─ Snapshots
```

linux-surface is older than Omarchy's kernel, not newer. On this machine that
cost exactly one driver out of 206 loaded, an Intel power-telemetry module.
See [docs/findings.md](docs/findings.md) for how that was measured. It is the
honest price of the touchscreen, and better known before you start than after.

Keeping Omarchy's kernel as the default is deliberate: it is your way back
from anything that goes wrong.

---

## Quick start

```sh
git clone https://github.com/Overpaul-Ops/surface-book-2-omarchy.git
cd surface-book-2-omarchy

bash scripts/00-survey.sh   # read-only: what does your machine look like?
./install.sh                # then this, as often as it takes
```

`install.sh` shows you where you stand and does everything that can be done
right now:

```
Surface Book 2 on Omarchy — setup status

  [✓]  Detach         Detach and re-attach the display safely
  [✓]  Kernel         linux-surface, for the touchscreen
  [!]  Tablet         On-screen keyboard, trackpad, rotation
       installed, but needs a reboot to take effect
  [ ]  Maintenance    Health check after every update

  running kernel: 6.19.8-arch1-3-surface (touchscreen available)

  Next: reboot (step 3 (Tablet) needs it), then run ./install.sh again.
```

| | |
|---|---|
| `./install.sh` | status, then a menu |
| `./install.sh --all` | everything possible, stopping at the next reboot |
| `./install.sh --status` | just look |
| `./install.sh --dry-run` | what would happen, changing nothing |
| `./install.sh --step 3` | one specific step |

Run it as your normal user, not with `sudo`. It calls `sudo` where needed, and
`yay` refuses to run as root.

It cannot all happen in one go, and no script can change that. Three points
genuinely require a reboot before the next step means anything:

```
  step 1  detach          /etc/environment only applies at login
             ▼ reboot
  step 2  kernel          touch needs the new kernel RUNNING
             ▼ reboot, and pick it in the boot menu — only you can do that
  step 3  tablet mode     the 'input' group only applies at login
             ▼ reboot
  step 4  maintenance
```

So `install.sh` stops cleanly at each boundary, offers to reboot, and resumes
where it left off next time. It reads your system rather than a file it wrote
earlier, so it still tells the truth if you did part of it by hand or came
back a month later.

The five scripts under `scripts/` also work on their own if you prefer that.

Start with `00-survey.sh` either way. It changes nothing and tells you which
of this repository's assumptions hold on *your* machine.

### Afterwards: make it the default

Until you do this, the boot menu still picks your old kernel when the
countdown runs out, so you get no touchscreen unless you catch the menu every
time.

```sh
./install.sh --step 5
```

Deliberately not part of `--all`. Give the new kernel a few days first. See
[docs/06-default-kernel.md](docs/06-default-kernel.md).

---

## The steps, in detail

Each of these is a standalone document. If you only want detaching and not the
touchscreen, stop after step 1. That is a perfectly good place to stop, and it
needs no kernel change at all.

1. [Survey](docs/01-survey.md): what your machine already has. On this device,
   Omarchy's stock kernel already contained the whole Surface aggregator stack
   including the detach driver.
2. [Detaching](docs/02-detach.md): `surface-dtx-daemon` plus a handler that
   powers the discrete GPU down before unlocking the latch, and refuses to
   unlock when something is still using it.
3. [The kernel](docs/03-kernel.md): adding `linux-surface` beside Omarchy's
   kernel, and why the Limine entry needs no manual editing.
4. [Touch and tablet mode](docs/04-touch-and-tablet.md): `iptsd`, on-screen
   keyboard, virtual trackpad, auto-rotation.
5. [Maintenance](docs/05-maintenance.md): a health check that runs itself
   after every kernel or bootloader update.
6. [Booting linux-surface by default](docs/06-default-kernel.md): once it has
   earned your trust, so you stop having to catch the boot menu.

Two more worth reading:

- [Findings](docs/findings.md) collects the places where the existing guides
  are wrong, incomplete, or right for a different Surface. This is the most
  useful file here if you are adapting rather than following.
- [Troubleshooting](docs/troubleshooting.md) lists symptoms and what they mean.

---

## The one thing people get wrong

The obvious detach handler, the one the linux-surface wiki suggests, checks
whether the GPU is in `D3cold` and aborts if it is not:

```sh
if [ "$dgpu_state" != "D3cold" ]; then
    exit 1
fi
```

On a machine with the NVIDIA driver loaded and runtime power management off,
the GPU sits at `D0` permanently. That handler blocks every detach, forever,
and it is not obvious why.

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

For this to work at all, nothing may hold the GPU open at idle. By default,
NVIDIA's OpenGL libraries open it on *every* program start just to look at it.
Fixing that is the other half of step 1.
