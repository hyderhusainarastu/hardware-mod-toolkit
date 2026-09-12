---
name: mcu-safe-backup
description: Identify and back up an MCU flash read-only before any modification. Find the download-mode window, run identification and partition-table reads, take a two-pass verified full dump, and establish a tested recovery path. Use before any operation that could write, erase, or brick a device, and when auditing whether a backup is actually sufficient to recover.
---

# mcu-safe-backup

The rule "no write until a verified backup and a tested recovery path both
exist" is easy to say and hard to operationalise. This skill is the
operational half: how to find the window into download mode without a
strap pin, how to run a read-only session that cannot accidentally become
a write, how to take a dump that is actually verified rather than merely
taken, and how to draw the line between "we have a backup" and "we have a
recovery path" — they are not the same claim, and treating them as
equivalent is the single most common way this kind of project convinces
itself it is safer than it is.

The concrete commands below are `esptool` / Espressif-chip flavored,
because that is the worked example this project's process was built
against (github.com/hyderhusainarastu/byok-mod). The pattern generalizes
to any vendor flashing tool (STM32CubeProgrammer, nrfjprog/nrfutil, a
J-Link, a vendor SDK's own flasher): dry-run by default, refuse
write/erase arguments at the argument-parsing level *and* again on the
assembled command, verify with two independent reads instead of one, and
make the one sanctioned write (if any) a hardcoded constant re-derived
from the device's own on-chip map rather than a value trusted from a
datasheet or a CLI flag.

Reference implementation: `${CLAUDE_PLUGIN_ROOT}/scripts/mcu-backup-window.sh`
(plugin install) or `scripts/mcu-backup-window.sh` (repo checkout) —
`identify` / `partition-table` / `dump` subcommands, dry-run by default,
argument-level refusal of anything containing write/erase/efuse. Fill-in
recovery-ladder template: `references/recovery-plan.md` in this skill
directory.

## 1. Preconditions — what must be true before a single write is considered

Do not treat any of these as satisfied until it is written down with
evidence attached, not asserted from memory:

- [ ] **A verified dump exists.** Not "a dump was taken" — *verified*,
  meaning two independent reads were compared and matched (§5). A single
  read proves nothing: it could be truncated, corrupted in transit, or
  read from the wrong offset, and a hash of one file confirms nothing
  about whether that file is what the chip actually holds.
- [ ] **The partition map (or equivalent flash layout) has been decoded
  from the device's own flash, not assumed from a vendor default or a
  tutorial.** Devices that ship a customized layout routinely relocate
  the exact region you're about to touch — see the offset trap in §8.
- [ ] **An identified return-to-stock path exists** — something that can
  put a known-good image back and has actually been exercised, not just
  described. A stock updater rehearsed once against a spare card/medium
  counts; a procedure that has only ever been typed into a markdown file
  does not.
- [ ] **The owner's go-ahead for this specific write, at this specific
  moment, is recorded** — a decision record (see
  `templates/decision-record.md`), not a standing policy. "We backed up
  weeks ago" does not authorize today's write; the backup verifies the
  device, the go-ahead authorizes the action.

Until every box above is checked, the only sanctioned activity is
reading. If a task pushes toward a write before this list is satisfied,
the answer is to stop and close the gap, not to proceed carefully.

## 2. Finding the window

Many small devices hand the shared USB PHY from a debug/download bridge
to the running application some fixed time after boot — often a handful
of seconds — after which the debug bridge stops enumerating and the
normal reset sequence a flashing tool relies on stops working. This
matters because it means download mode is not permanently available: it
exists in a *window*, and the window closes on its own even if you do
nothing wrong.

**How to detect it:**
- Watch the host's device list (`ls /dev/cu.*` on macOS, `dmesg -w` /
  `udevadm monitor` on Linux) across a cold boot. If a debug-bridge node
  (e.g. a USB-CDC/JTAG interface) appears at power-on and later
  disappears while the device keeps running, that disappearance marks
  the hand-off; the interval before it is your window.
- Cross-reference firmware boot logs if you have them (a UART console,
  or the same debug bridge before it hands off) for a literal log line
  about claiming the USB peripheral for the application — that log
  timestamp, if present, is a more precise window measurement than
  guessing from `dmesg` polling.
- If the flashing tool has its own automatic reset-into-download-mode
  sequence (many do, driven by control-line toggling rather than a
  physical strap pin), it only works while the debug bridge still owns
  the port — i.e., inside the window. Outside it, the tool's own
  auto-reset silently fails or the port vanishes entirely.

**Entering deliberately vs. by accident.** Once you understand the
window, you can choose to trigger a reset *into* it on purpose (a
power-cycle immediately followed by the tool's connect attempt) rather
than racing an uncontrolled boot. Once the tool's connect sequence lands
inside the window, the chip drops into its ROM/bootloader download mode
and *stays there* — the application does not resume — as long as every
subsequent command tells the tool not to reset the device again
(commonly a `--after no-reset` / `no_reset` style flag). This lets you
chain identify → partition-table → dump in one download-mode session
without re-racing the window for every command.

**The multi-MCU reset trap.** If the device has more than one
microcontroller (a main SoC plus a companion MCU, a separate display
controller, etc.), resetting *one* of them via the debug/download path
does not necessarily reset the others. A reset that only touches the
main chip can leave a companion MCU or display controller running with
stale state — observed on real hardware as visual artifacts, wrong
contrast, or unresponsive input until a full power cycle. **The reliable
way to exit a download-mode session is to unplug the cable and do a full
power-off/power-on with the device's own power switch, not a
debug-bridge-only reset.** Document this exit procedure once and follow
it every time; do not assume a "soft reset" flag on the flashing tool
resets the whole board.

## 3. The read-only session

Structure every read-only session the same way, in this order:

1. **Chip identification** — a command that reads the chip's ID/revision
   without touching flash (e.g. `chip-id` / `chip_id`).
2. **Flash identification** — the flash die's JEDEC ID and detected
   capacity (e.g. `flash-id` / `flash_id`). Do not trust a silkscreen or
   a spec-sheet figure for flash size once you can read it from the die
   itself — treat the read value as the correct one and promote any
   prior guess from "indicated" to "confirmed" only once it's read, not
   before.
3. **Flash status register** — a read-only status/protection register
   read (e.g. `read-flash-status --bytes 3`). This is worth doing even
   though it doesn't authorize anything: on a device where every
   block-protect bit turns out clear, there is no hardware write-protect
   standing between the project and a bricked device, and knowing that
   plainly should raise your own bar for care, not lower it because "the
   hardware will refuse it anyway."
4. **A small timed probe read** (tens of KB) of a region you already
   expect to be able to decode (a bootloader header, a known-good
   region). Time it. This single read tells you the tool's *actual*
   measured throughput on *this* unit — use that number, not a
   datasheet's theoretical rate, to budget the full dump (§5).
5. **The partition/layout table read and decode**, once one exists at a
   known offset (which may itself only become known from step 4's probe,
   or from vendor documentation). Decode it into a table of
   label/type/offset/size and treat this decoded table, not any
   assumption, as ground truth for every later step.

**Every command gets echoed before it runs — always, dry-run or real.**
The habit of printing the exact command line before executing it is not
cosmetic: it is what lets someone (the owner, a reviewer, your future
self reading a log) catch a wrong offset or a wrong flag before it does
anything, and it is what makes the session's log file a complete,
self-contained record of what actually touched the device.

**Nothing executes without an explicit `--yes` (or equivalent).** Without
it, the script/session prints the full plan — every command it would
run, in order — and exits successfully having touched nothing. This is
the mechanism that lets you test and review a backup procedure with no
device attached at all, and it is the default, not an opt-in safety
mode.

## 4. Defence in depth

A read-only tool should refuse to become a write tool by more than one
independent mechanism, because any single check can have a bug:

- **Refuse at the argument level, before anything else runs.** Scan every
  argument the caller supplied for forbidden substrings — `write`,
  `erase`, `efuse` (case-insensitive) — and abort immediately if any
  argument contains one. This catches an operator mistake (a copy-pasted
  flag, a wrong subcommand name) before any port is even opened.
- **Refuse again on the fully assembled command line, immediately before
  every invocation.** This is not redundant with the argument check: it
  catches a *bug in the script itself* that might construct a dangerous
  command from otherwise-innocent inputs. A read-only tool should have no
  code path that can ever assemble a write/erase/efuse command — verify
  this is true by inspection, then add the runtime check as a second
  line of defence anyway.
- **Detect the installed tool's own syntax rather than hardcoding it.**
  Flashing tools change CLI spelling across major versions (underscored
  subcommands becoming dash-separated, a flag being renamed) — often
  silently, from a version bump alone. Detect which form is installed at
  runtime (e.g. grep the tool's own `--help` output for a known verb
  spelled both ways) and use whichever form is actually present, so the
  printed and executed commands always match what the installed tool
  understands. Do not read someone else's transcript and assume your
  installed version uses the same spelling.
- **Refuse to write backup files anywhere that isn't confirmed
  ignored by version control**, checked immediately before the first
  byte is written, not assumed from a `.gitignore` file's presence
  (rules can be edited, patterns can miss). A flash-derived binary — a
  bootloader, an NVS/preferences dump, anything read from the device —
  can carry credentials, tokens, or other device-identifying data and
  must never land somewhere that could later be committed by a routine
  `git add`.
- **Check whether the target port is already open by another process**
  before touching it (a plain `lsof`-style check costs nothing and does
  no device I/O). Two processes racing the same serial node is a way to
  corrupt an in-progress session for no benefit.
- **On failure, translate the tool's raw error into a plain-language
  hint** (timing miss vs. wrong mode vs. port disappeared) by matching
  known failure strings in the tool's own output. This is cheap to add
  and saves real time re-diagnosing the same three failure modes over
  and over during a session that has already found the window is narrow.

## 5. The dump — making "verified" a fact, not an adjective

1. **Auto-detect the size** from the flash-identification step; only
   fall back to a hardcoded default (documented as a placeholder,
   `<FLASH_SIZE>`) if detection is genuinely unavailable.
2. **Confirm the destination directory is version-control-ignored**
   before writing the first byte (§4) — not after.
3. **Read the full region twice, to two separate files.** Not "read it,
   then read a checksum of it" — read the whole thing twice,
   independently.
4. **Compare the two files' SHA-256.** Match: PASS, this is a verified
   backup. Mismatch: FAIL — do not trust either file as a backup, and do
   not treat "the tool reported success" for either individual read as
   sufficient; a transfer can complete without error and still be wrong
   at the protocol layer above the point the tool checks.
5. **Budget the time from the measured throughput (§3 step 4), not from
   a peripheral's on-paper rate.** Some transports carry known,
   unresolved upstream performance bugs specific to certain chip/transport
   combinations — e.g. a documented case on one SoC-over-USB-debug-bridge
   combination measured throughput roughly two orders of magnitude below
   a healthy transfer on the same physical interface, turning a
   sub-minute read into a 25–35-minute one, and a full two-pass dump into
   over an hour, unattended. Measure it on the actual unit with a small
   timed probe first (§3 step 4) rather than assuming either the
   datasheet figure or someone else's number for a superficially similar
   device — the whole point of the timed probe is to make a long-running
   dump distinguishable from a hang: if the tool prints progress
   periodically, slow-but-advancing output is the known bug, not a fault;
   output that stops advancing for much longer than one progress interval
   is a real hang.
6. **Record the SHA-256, the tool version, the exact command lines, and
   the PASS/FAIL verdict** in the backup directory itself, not only in a
   chat transcript or a session log that might not travel with the
   files.

## 6. What a dump does and does not make possible

Be explicit about the difference — write it down, don't just believe it:

- **A full verified dump enables:** a per-region/per-partition restore of
  anything covered by the dump, and (with more risk) a full restore of
  the whole flash from the same snapshot.
- **A full verified dump does NOT, by itself, make any restore "tested."**
  Nothing has been proven to work back onto the device until a restore
  has actually been performed and its result checked. A written
  procedure is not a tested one, no matter how carefully it was
  reasoned through — the "tested recovery path" half of §1's gate stays
  unmet until something has actually been written back and verified to
  boot correctly.
- **A dump can never recover:** anything the dump was taken *after* has
  already changed on the real device (a snapshot drifts the moment the
  device is used again) — and, for whatever region carries the device's
  own identity/credentials/calibration (see §8's third trap), the *only*
  way to get back a value not present in the dump is to regenerate it by
  device-side means (a re-pairing, a re-provisioning, a recalibration),
  never to invent or copy one from elsewhere.

## 7. The one sanctioned write — return to stock

If the project's return-to-stock action can be reduced to reverting a
single small selector region (a boot-slot pointer, an update flag) rather
than rewriting an entire application image, prefer that: smaller blast
radius, and a region small enough to read back and verify completely in
seconds. The pattern that makes this safe to carve out as the *one*
exception to an otherwise unconditional read-only tool:

1. **The target region is a compile-time constant in the script, never a
   CLI argument.** There is no flag that changes it. Any argument that
   even looks like an attempt to override the offset/size/region is
   rejected outright, before anything else runs.
2. **Before writing anything, independently re-derive the same region
   from the device's own on-chip layout table** (read fresh, this
   session — not from a cached copy) and locate the matching entry by
   its type/subtype/label. **If that entry's offset or size does not
   exactly match the hardcoded constant, abort without writing.** The
   hardcoded region is a belief the script must justify every time it
   runs, not a fact it is allowed to assume.
3. **The assembled command is scanned immediately before every
   invocation, and here the check is narrower than the read-only tool's
   "refuse always":** any write/efuse substring anywhere still refuses
   the whole run; an erase-class substring is permitted **only** as the
   exact, contiguous, hardcoded verb-plus-offset-plus-size sequence —
   anything else (wrong verb, right verb with different arguments)
   refuses. This is the one place in the whole toolkit where "erase" is
   ever allowed past the gate, and it is allowed only in the one shape
   that matches the sanctioned action byte-for-byte.
4. **Read back and verify after writing**, before allowing the device to
   reboot. For an erase, verify every byte reads back as the erased-state
   value; for any other write, re-read the exact written region and
   compare its hash to what was intended.
5. **Leave the device in download mode by default after the write**,
   with an explicit opt-in flag to issue the final reset — so the
   decision to let the device boot on the new state is a distinct,
   deliberate step, not a side effect of the write completing.
6. **State plainly, every time this runs, what the device does on its
   next boot** — including any downstream consequence the write doesn't
   fully control (§8's third trap) — rather than letting the operator
   assume the write alone finishes the job.
7. **This script's existence never substitutes for the owner's
   fresh go-ahead on the specific run.** Running it with the execute flag
   still requires the same explicit authorization as any other
   device-touching action (§1's last checkbox) — a script that is
   carefully gated is not the same thing as a script that is
   pre-authorized.

## 8. Traps

- **A region described by no entry in the decoded layout table is not
  necessarily damage.** Some devices ship with meaningful gaps
  (unallocated flash, a calibration region intentionally left at its
  erased value because the real calibration lives elsewhere). Confirm
  what "empty" actually means for that specific region — cross-reference
  a boot log's own reported free-space or calibration-source line if one
  exists — before "repairing" anything into it.
- **A selector/pointer region can point at a slot that is not the one
  actually running**, or can be blank in a way that makes the *device's
  default fallback* the running slot rather than any slot the selector
  names. Read and decode the selector before assuming which slot a
  restore should target — restoring an application image into the wrong
  slot, or restoring a selector that points at a slot whose contents no
  longer match what it did when the selector was written, is a way to
  make a working device stop booting.
- **An updater that watches removable media (an SD card, a USB drive) at
  boot will re-run against whatever is present on that media at the next
  cold boot — regardless of what the flash-side write did or didn't do.**
  If the return-to-stock action leaves that door open, state explicitly,
  every time, what the operator must check or remove from that media
  before powering the device back on. A perfectly executed flash-side
  revert can still be immediately overwritten by a stale updater payload
  the operator forgot was sitting on a card.
- **The device's actual on-chip layout can diverge from any "default"
  layout you find in vendor documentation or a tutorial**, sometimes at
  exactly the offset a naive procedure assumes. Always use the offsets
  read from *this device*, decoded fresh; never carry over offsets from
  a different unit, a default template, or an earlier version of the
  firmware without re-verifying them against a fresh read.

See `references/recovery-plan.md` in this skill directory for a
fill-in escalation-ladder template (smallest-sufficient-restore first)
to adapt per project, and
`${CLAUDE_PLUGIN_ROOT}/templates/decision-record.md` /
`templates/decision-record.md` for recording the owner go-ahead this
skill's preconditions require.
