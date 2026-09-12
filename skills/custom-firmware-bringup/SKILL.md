---
name: custom-firmware-bringup
description: Bring up custom firmware on a reverse-engineered device without bricking it or chasing avoidable first-boot failures - component layout, config gates that stay off by default, a display bring-up checklist, task stack budgeting, power-latch and USB-PHY handling, and a per-release build/package/verify loop. Use when writing or debugging the first builds of custom firmware for an existing device.
---

# Custom firmware bring-up

A worked example (`byok-mod`, github.com/hyderhusainarastu/byok-mod) hit five separate
multi-hour first-boot failures on the same device, and every one turned out to be a small,
well-known mistake with a one-line preventive check: an init table replayed faithfully but
missing the vendor's own post-first-frame display-enable step (panel ACKs every byte and stays
blank); a controller row-scroll register holding a non-zero power-on value that nothing in
either firmware ever clears (image shifted a fixed number of rows); a multi-KB scratch buffer
declared as a plain local inside a boot task whose stack was never sized for it (boot loop the
instant that code path runs); a power-cut GPIO asserted while the brownout detector is actively
resetting the core and stops driving every pad (device restarts instead of powering off); and a
blocking call made while the scheduler is suspended (an assert-triggered reboot with no
exception, no register dump, nothing that looks like the code that caused it). None of these are
exotic. A checklist that front-loads all five, before the first flash, is worth days.

## 1. When to use

- Writing the first custom firmware build for a device whose stock behavior has already been
  reverse-engineered (see `hardware-recon` and `firmware-image-analysis`).
- Debugging a first-boot symptom that looks bizarre from the device's own output — blank
  screen with no error, an image that renders but looks subtly wrong, a boot loop with no
  obvious cause, a device that restarts instead of powering off, a crash with no useful trace.
- Planning the config-gate layout for anything that can write flash, arm a bootloader-visible
  update path, or otherwise turn a reversible mistake into an irreversible one.
- Setting up the per-release build/package/verify loop before the first device install.

## 2. Component layout

One directory per subsystem (display, power, storage, USB, RTC, battery, …), each with its own
public header and its own Kconfig if it has anything worth gating. Two conventions pay for
themselves immediately:

- **A single shared `hw_config.h`** (or equivalent) holding every reverse-engineered constant —
  GPIO numbers, bus addresses, register values, timing constants, opcode bytes — with its
  **evidence grade in a comment next to the value**, not in a separate document nobody rereads
  mid-edit:

  ```c
  /* [CONFIRMED] file 0x1153FC: sim_send() -- one i2c_master_transmit(dev, &b, 1, 1000ms)
   *   per byte, disable_ack_check=1 on both devices. Re-derive: <path to the analysis doc>. */
  #define <PANEL>_I2C_ADDR_CMD   0x38
  ```

  When a value is later confirmed or corrected on real hardware, edit the grade in place and
  say what changed the grade — never silently upgrade a comment's confidence without a new,
  stated observation backing it.

- **Protocol and container code lives in a shared tree** (a `common/` directory used by both
  the device firmware and the host tooling), with test vectors both sides run against. A
  framing bug or a tar-parsing bug caught by a host-side unit test costs a test run; the same
  bug caught by installing a corrupt update on the device costs a recovery.

## 3. Config gates: every risky capability defaults OFF

Anything that can overwrite flash, select which partition boots next, or change what a
first-time USB enumeration looks like belongs behind its own Kconfig `bool`, defaulting `n`,
with a help text that states in full sentences: what turning it on actually does, exactly what
it does NOT touch, and what the fallback is if it misbehaves. Two gates worth calling out
because they are easy to conflate into one flag and shouldn't be:

- **"Scan and validate an update" vs. "actually write it."** Keep these as two separate
  options. The first can run on every boot harmlessly (it only logs what it *would* install);
  the second is the one that erases and rewrites a flash partition. Arming the second without
  the first being exercised first, on a device you have exactly one of, throws away your one
  cheap dry run.
- **A minimum-uptime gate before a USB personality switches** (e.g. before the device stops
  presenting a serial/recovery interface and switches to whatever mode a full boot puts it
  in). A device that can switch away from its own recovery interface in under a second, from a
  cold boot with a bad image, has no window left to intervene from the host side at all.

**After every build, grep the generated config file for the values you meant to protect** —
not before, and not from the source Kconfig defaults. A per-build sdkconfig override
(`sdkconfig.defaults`) can silently re-arm a gate that the component's own default keeps off,
and the only way to know what a given image actually shipped with is to read the config file
`idf.py` (or your toolchain's equivalent) actually generated:

```
grep -E '^CONFIG_<PROJECT>_(ALLOW_.*_WRITE|.*_ARMED|.*_MIN_UPTIME_MS)=' <build-dir>/sdkconfig
```

Do this as a release-checklist line item, not an occasional sanity check — it is the only way
that "I turned the dangerous flag off" and "the image I actually flashed has the dangerous flag
off" stay the same claim.

## 4. Display bring-up checklist, in order

Work through these **in this order** before concluding anything is a framebuffer bug. Full
tickable version: `references/bringup-checklist.md`.

1. **Replay the vendor's reset preamble and init table verbatim** before adding anything of
   your own. Byte-for-byte, same delays, same order. A panel that ACKs every byte and renders
   nothing is not evidence the transport is wrong — see step 2 before touching the transport.
2. **Send the vendor's post-first-frame display-enable command, if one exists.** Some
   controllers need one more command *after* the first full frame reaches display RAM, not
   during the init table — worth grepping every instance of the panel's own opcode-sending
   function for calls the init-table replay doesn't cover. In the worked example, the vendor's
   own bring-up sent one extra command exactly once, right after the first full-screen write,
   with a parameter differing from the init table's own use of the same opcode by a single bit
   — found only by an exhaustive cross-reference of every call site of the vendor's own
   byte-send routine, not by reading the init table alone. A panel that ACKs everything and
   stays blank, with 0 bus errors, is this failure mode far more often than a wiring or
   transport problem.
3. **Explicitly zero (or otherwise set to a known value) the scroll/start-line or equivalent
   display-origin register at init**, even if the vendor firmware never touches it. A
   controller's row-granular origin register is not guaranteed to reset to zero on power-on,
   and if neither the vendor firmware nor yours ever programs it, both firmwares are simply
   inheriting whatever value the silicon happened to come up with — which can differ between
   units of the same board. The symptom is a fixed, non-page-aligned pixel shift with no
   mirroring and no wrap: the far end of the image doesn't reappear at the other edge, it's
   simply gone, and the vacated rows/columns show whatever the controller's own RAM happens to
   hold, not your framebuffer's content.
4. **Check page vs. row (or equivalent block vs. fine) granularity before concluding a shift is
   a framebuffer bug.** If the window-program or partial-update path only ever addresses
   8-row (or N-unit) blocks, no framebuffer-side offset can produce a shift that isn't a
   multiple of that block size — the arithmetic alone rules a whole class of "maybe I have an
   off-by-one in my rect math" hypotheses in or out before you touch any code.
5. **Verify bit order within a byte/word by looking for vertically (or otherwise) mirrored
   bands, not a shift.** A wrong bit-within-byte assumption mirrors each block of rows, it does
   not move the image — text and graphics inside each block come out upside-down or reversed
   relative to the block above/below it, while whole-image shifts and mirrored-block artifacts
   have visibly different signatures once you know to look for the difference.
6. **Keep a per-transaction (e.g. per-byte) transport path as the fallback** whenever a
   batched/bulk transfer path has never actually been exercised on real glass. A bulk transfer
   that the target part cannot sustain can still return success on the host side — the
   controller silently drops or corrupts bytes it can't absorb in time, with no bus-level error
   raised, because the error (if any) shows up only as "did the panel actually latch every byte
   into its own RAM," which a `disable_ack_check`-style flag (common on displays for speed)
   means the bus transaction layer cannot see at all. When a bulk path is ever suspected, flip
   back to the byte-for-byte path you have direct evidence for — from the vendor's own
   disassembly or datasheet, not from an assumption of how the part should behave — before
   spending more time on the theory that the framebuffer math is wrong.
7. **Instrument transactions, bytes, and errors per phase, and log the ratio.** A getter that
   reports transactions-per-byte-sent (1.000 on a pure per-byte path, far below 1 on a batched
   path) turns "is the bulk path actually doing what I think" into a one-line log check instead
   of a guess, and is cheap enough to leave compiled into every build permanently.

## 5. A boot self-test that renders without a host

Give the device a fixed sequence of self-contained boot screens that need no host connection at
all, run once per boot, in this order — each phase earns its keep by isolating a different
failure class:

1. **Checkerboard** — a dense, full-height, alternating pattern. Nothing sparse can hide a
   partial-write or corruption failure the way a mostly-blank screen can.
2. **Border + banner + version** — a thin full-perimeter border (proves all four edges of the
   addressable area are reachable) plus firmware version and reset-reason text (the version
   confirms which build is actually running; the reset reason is the one channel that still
   works when everything else — including your own USB console — is dead).
3. **A horizontal/vertical line test** — sweeps that make any row- or column-granular shift or
   mirroring immediately visible, rather than something you have to infer from a photo of
   dense text.
4. **A gate/mode message** — whatever your recovery-mode-entry gesture is, drawn plainly, so a
   device that boots into recovery instead of normal operation says so on the glass instead of
   looking indistinguishable from a hang.
5. **A resting screen** — the same content as step 2, left up indefinitely as the idle state,
   so "does the device work at all" has an answer within seconds of any boot, cold or warm,
   with zero host software involved.

A first install that renders nothing beyond phase 1, or renders phases inconsistently across
otherwise-identical boots, is itself diagnostic — see §4 above for what to check first, and
particularly whether a WAKE/power button gesture also happens to sit on the same GPIO used to
power the unit on (§6 below) before assuming the self-test code itself is broken.

## 6. Task stacks

- **Never call a writer/streaming path directly from a boot task's own body**, especially the
  very first task your runtime creates (often sized only for launching other tasks, not for
  doing real work itself). Give any code that opens files, streams a partition write, or runs a
  cryptographic hash over a large buffer its own dedicated task with a stack sized for what it
  actually needs — measured or margin-estimated, and documented as which.
- **Heap-allocate any local buffer above roughly 1 KB** rather than declaring it on a task's own
  stack, or size the task's stack explicitly around every large local it declares plus every
  library call frame underneath it (a streaming write into a partition or filesystem routinely
  pulls in a checksum/hash update, a block-device driver, and a filesystem layer, all stacked on
  top of your own locals — budget for the whole chain, not just your own function).
- **Enable the stack-overflow canary/guard your RTOS provides**, and treat its failure text as
  exactly what it says: a plain stack overflow produces no exception, no register dump, and no
  "corrupted" marker beyond an unwinder giving up at the end of an already-trashed stack — do
  not go looking for a flash-corruption or cache-coherency bug when the panic text already named
  the cause.
- **Log the high-water mark** (`uxTaskGetStackHighWaterMark()` or equivalent) for any
  task you sized by inspection rather than measurement, and revisit the stack size once a real
  device capture gives you an actual number instead of margin-by-inspection.
- **Never call a blocking primitive with a non-zero timeout while the scheduler is suspended.**
  Wrapping a drawing/refresh call in a scheduler-suspend section to protect a shared resource is
  a reasonable instinct, but if anything inside that section reaches a bus transaction with a
  real timeout (I2C, SPI, anything using the same semaphore/queue primitives your RTOS uses
  everywhere else), the very first suspended-scheduler call to it asserts immediately — every
  time, unconditionally, regardless of whether the underlying hardware was actually busy. Use a
  real mutex around the shared resource instead of suspending the whole scheduler.

## 7. Power and USB

- **A power-cut GPIO plus an active brownout detector means every pad stops driving mid-
  sequence, not just at the end of it.** As the rail collapses toward the brownout threshold,
  the detector resets the core and every pad — including the very GPIO you just asserted to cut
  power — stops driving. If the same physical button used to power the device *on* is still
  being pressed at the instant you assert that cut, the button's own still-held press can look
  exactly like a fresh power-on request to the board's own power circuit, and the device
  restarts instead of turning off. The fix is a debounced wait for the button's **release**
  before asserting the cut — no fixed timeout, because a fixed delay just moves the coincidence
  around rather than removing it — and the sequence has to be correct starting at its very first
  instruction, not "eventually correct once the spin loop after it gets a chance to run": once
  the rail is falling, there may be no further instructions.
- **Deliberately restore any USB PHY / personality state your runtime can leave stranded across
  a soft reset.** A software reset that doesn't power-cycle the board can leave the low-level
  USB/JTAG mux in whatever state your USB stack last put it in, because that mux commonly lives
  in a domain that survives a CPU-only reset — stranding your own recovery console on every
  soft-reset path (an update-triggered reboot, a crash-and-restart, an explicit restart command)
  until the next full power cycle. Restore it explicitly and early in the boot path, and again
  in a shutdown-hook style callback that runs immediately *before* every soft reset, not only on
  the boot that follows one.
- **Hold or release any power latch explicitly on every boot path**, including the very first
  action your firmware takes, before any peripheral or driver is initialized that might itself
  reset that pin's configuration.

## 8. Build hygiene and the per-release loop

1. **Delete the stale generated config before switching targets or reconfiguring.** A generated
   config file (e.g. `sdkconfig`) can persist stale values across a target switch or a defaults
   change; the safe sequence is `rm -f <generated-config> && <toolchain> set-target <target> &&
   <toolchain> build`, every time, not only the first time.
2. **Build with zero warnings, zero errors** — a warning that shows up once and is dismissed
   tends to still be there, unexamined, at the release that actually matters.
3. **Bump the firmware's own version string AND its host-visible handshake/patch field
   together.** A host tool that identifies firmware capability from a protocol field, not a
   human-readable string, needs that field bumped every release or it silently believes it's
   talking to an older build than the one actually running.
4. **Package, then run both the static checks (protocol/container unit tests, fuzz tests if you
   have them) and any host-side integration tests** against the packaged artifact, not just the
   source tree — a packaging bug is invisible to a test that only ever built from source.
5. **Record the release row** (version, artifact paths and sizes, hashes, the exact build
   command used, which tests ran and their result, the first-boot result once performed, and
   what changed) before moving to the next change — see `references/release-row.md` for the
   full field list and `${CLAUDE_PLUGIN_ROOT}/templates/decision-record.md` for the separate
   record a course-changing decision deserves. A table of these rows is what turns "which build
   is on the device right now" from a guess into a lookup.

## References

- `references/bringup-checklist.md` — §4's display checklist as a tickable list, plus §6/§7 as
  short pre-flash checks.
- `references/release-row.md` — the per-release record field list and a filled worked example.
- `${CLAUDE_PLUGIN_ROOT}/templates/decision-record.md` — for a course-changing decision that a
  release row alone doesn't capture (e.g. choosing a dedicated task over growing a shared
  stack, or deferring a stock-parity behavior to a later release).
- `${CLAUDE_PLUGIN_ROOT}/templates/incident-report.md` — the shape to write up a first-boot
  failure in, once one of the checks above catches something.
