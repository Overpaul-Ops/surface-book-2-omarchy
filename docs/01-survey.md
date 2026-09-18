# Step 1 — Survey

```sh
bash scripts/00-survey.sh
```

Read-only. Changes nothing. Run it even if you intend to do everything by
hand: it tells you which of this repository's assumptions hold on your
machine, and several of them decide how much work is ahead of you.

## The questions it answers

### Does `/dev/surface/dtx` exist?

The single most useful thing to know. If it does, your kernel already has the
detach driver and **you can do all of [step 2](02-detach.md) without touching
the kernel at all**. On the reference machine it did, which was a pleasant
surprise — Omarchy ships the complete Surface aggregator stack.

If it does not, do [step 3](03-kernel.md) first.

### Is there a discrete GPU, and what state is it in?

```
discrete GPU: 0000:02:00.0
  power_state            D0
  power/control          on
  power/runtime_status   active
```

`control = on` means runtime power management is disabled: the card never
powers down, and it is still live when you detach the base. That is the
problem step 2 solves.

No NVIDIA GPU at all is a simpler life — the GPU parts are skipped.

### Who is holding the GPU open?

If your compositor appears in this list, detaching will always be refused
until that is fixed. It is normal, it is not your fault, and step 2 addresses
it. See [findings #3](findings.md#3-your-compositor-holds-the-gpu-open-even-when-it-does-not-use-it)
for why a compositor that renders on the *Intel* GPU still opens the NVIDIA
one.

### Is Secure Boot on?

`linux-surface` is not signed by Microsoft. With Secure Boot enabled it will
not boot, and step 3 refuses to run.

### How much room is on `/boot`?

Each unified kernel image is around 150 MB, and every snapshot keeps a copy.
Under 500 MB free, clean up before adding a second kernel.

### Is there more than one bootloader config?

A known trap: `/boot/limine.conf` and `/boot/EFI/limine/limine.conf` drifting
apart, so a kernel update leaves you with a config pointing at files that no
longer exist. If the survey finds two, resolve which one is live **before**
step 3.

### Does `BOOT_ORDER` have a wildcard?

```
BOOT_ORDER="linux-t2, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"
```

That `*` is why no hand-written boot entry is needed on Omarchy — see
[findings #7](findings.md#7-on-omarchy-the-boot-entry-writes-itself).

### Is Snapper set up?

Your way back. If it is not, consider setting it up before going further; the
scripts will warn you and ask.

## What to do with the output

Keep it. Comparing before and after is how you tell what a step actually did.

```sh
bash scripts/00-survey.sh > survey-before.txt
```

It is also the right thing to attach to an issue.
