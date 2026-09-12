# Custom firmware bring-up checklist

Copy this into your own notes for a new `<DEVICE>` bring-up and tick items off as you go. Each
line names the failure it catches — read `SKILL.md` §4/§6/§7 for the reasoning behind any item
that isn't self-explanatory.

## Before the first flash

- [ ] Every capability that can write flash, select a boot partition, or arm an on-device
      update path is behind its own Kconfig-style gate, default OFF.
- [ ] "Scan/validate an update" and "actually write it" are two separate gates, not one.
- [ ] A minimum-uptime (or equivalent) gate exists before any USB/recovery personality your
      board relies on for reflashing switches away from itself on a bad-image boot.
- [ ] `hw_config.h` (or your project's equivalent) exists as the single home for reverse-
      engineered constants, each with an evidence grade in its own comment.
- [ ] Protocol/container code that both the device and the host tooling need lives in a shared
      tree, with test vectors both sides run.

## Display bring-up (work top to bottom, don't skip ahead)

- [ ] Reset preamble and init table replayed byte-for-byte, same delays, same order, before any
      of your own additions.
- [ ] Checked for a vendor post-first-frame "display enable" (or equivalent) command that the
      init table alone doesn't cover — exhaustively cross-referenced every call site of the
      panel's own byte-send routine, not just read the init table.
- [ ] Display-origin / scroll-line (or equivalent) register explicitly set to a known value at
      init, even if the vendor firmware never touches it.
- [ ] Confirmed the window-program / partial-update path's granularity (page/block size) before
      attributing any shift to framebuffer math.
- [ ] Checked for mirrored blocks (a bit-order bug) as a distinct symptom from a whole-image
      shift (an origin-register bug) — they look different once you know to look.
- [ ] A per-transaction (e.g. per-byte) transport fallback exists and is the default, unless a
      batched/bulk path has actually been verified on real hardware, not just simulated.
- [ ] Transactions-per-unit-sent (or equivalent) is logged per phase, so a batched path's actual
      behavior is a log line, not a guess.
- [ ] A boot self-test renders: (1) a dense/checkerboard pattern, (2) border + banner + version +
      reset reason, (3) a line-sweep test, (4) any recovery-gate message, (5) a resting screen —
      in that order, with no host required for any of it.

## Task stacks and power

- [ ] No writer/streaming/hashing path is called directly from a boot task whose stack was only
      sized for launching other tasks.
- [ ] Every local buffer above ~1 KB is heap-allocated, or the task's stack is explicitly sized
      for it plus every library frame underneath it.
- [ ] The RTOS's stack-overflow canary/guard is enabled.
- [ ] High-water-mark logging exists for every task sized by inspection rather than measurement.
- [ ] No code path calls a blocking primitive with a non-zero timeout while the scheduler is
      suspended — a real mutex guards shared resources instead.
- [ ] The power-cut sequence is correct starting at its first instruction (brownout can stop
      every pad from driving mid-sequence) — not merely correct by the time a spin loop after it
      gets to run.
- [ ] If the power-off button is the same physical button used to power the device on, the cut
      waits for a debounced release, not a fixed timeout.
- [ ] USB PHY/personality state is restored deliberately, both early in boot and in a shutdown-
      hook callback that runs immediately before every soft reset.
- [ ] Any power latch is held or released explicitly on every boot path, before any peripheral
      driver that might reconfigure that pin runs.

## Every build/release

- [ ] Stale generated config deleted before `set-target`/reconfigure.
- [ ] Zero warnings, zero errors.
- [ ] Version string and host-visible handshake/patch field bumped together.
- [ ] Protocol/container unit tests (and fuzz tests, if present) pass against the packaged
      artifact, not just the source build.
- [ ] Protected config values grepped from the actual generated config post-build, not assumed
      from source defaults.
- [ ] Release row recorded — see `release-row.md`.
