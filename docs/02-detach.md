# Step 2: Detaching the display

```sh
bash scripts/01-detach-setup.sh
```

Needs no kernel change if [the survey](01-survey.md) found `/dev/surface/dtx`.
This is a perfectly good place to stop if you do not care about the
touchscreen.

## What is actually hard here

On a Surface Book 2 the discrete GPU and the second battery are in the
keyboard base, and the base disconnects while the machine is running. A loaded
graphics driver must not experience that.

So something has to power the GPU down *before* the latch opens, and refuse to
open it if that is not possible.

## How the machine already supports this

Pressing the detach button does not unlock anything. It notifies the kernel,
which notifies `surface-dtx-daemon`, which runs a script and looks at its exit
code:

```
button pressed → kernel → surface-dtx-daemon → /etc/surface-dtx/detach.sh
                                                        │
                            exit 0  ────────────────────→ open the latch
                            exit ≠0 ────────────────────→ abort, stay locked
```

Your script *is* the macro on the detach button. That is the intended design,
not a workaround.

## What the handler does

```
1. unmount USB volumes         (the ports are in the base)
2. unload the NVIDIA modules
   ├─ fails → something is using the GPU → exit 1 + notification naming it
   └─ succeeds → continue
3. set power/control=auto, let the card fall to D3cold
4. exit 0 → latch opens
```

Unloading is the safety check. `modprobe -r` only succeeds when no process
holds the device, so a running game makes it fail. You cannot detach into a
crash.

This is deliberately different from the check most guides suggest. See
[findings #2](findings.md#2-the-suggested-detach-handler-blocks-every-detach).

## The prerequisite nobody mentions

For the unload to ever succeed, nothing may hold the GPU at idle. By default
NVIDIA's OpenGL libraries open it on every program start just to enumerate it.
The script points GLVND at Mesa in `/etc/environment` to stop that.

Consequence: programs use the Intel GPU by default. For the discrete one:

```sh
nvidia-run steam
```

This is the normal setup for a hybrid-graphics laptop, and it noticeably
improves battery life, because the card finally reaches `D3cold` when idle.

## After running the script

Reboot. `/etc/environment` is only read at login, and if your machine uses
autologin, logging out may not be enough. See
[findings #10](findings.md#10-logging-out-does-not-apply-a-group-change-when-autologin-is-on).

Then test without detaching anything:

```sh
cat /sys/bus/pci/devices/<addr>/power_state    # expect D3cold
sudo /etc/surface-dtx/detach.sh; echo "exit: $?"
```

`exit: 0` and no notification means you are ready. `exit: 1` with a
notification naming a process means it is working correctly, so close that
program and try again.

Only then press the button for real: wait for the notification before lifting
the display, use it for a few minutes, re-attach.

Watch it happen with `journalctl -t surface-dtx -f`.

## Expect this

Detached, you cannot operate the machine yet. Keyboard and trackpad are in the
base, and the touchscreen needs [step 3](03-kernel.md). For now this test only
proves that detaching and re-attaching are mechanically and electrically
clean.
