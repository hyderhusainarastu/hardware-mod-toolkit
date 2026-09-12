# Recovery plan template — <PROJECT>

Fill this in once a verified backup exists (skill body §5), before any
write is attempted, and keep it under version control as documentation —
never let the actual dump files it references leave the gitignored
backup directory. Every code block below is DRAFT until the "Tested"
line under it is filled in with a real result; until then, nothing here
has been proven to work and none of it should be run.

Copy this file to somewhere like `docs/recovery.md` in your own project
and replace every `<PLACEHOLDER>`.

---

## Status of this document

> # ⚠⚠ DRAFT — NOT YET REHEARSED — DO NOT RUN ⚠⚠
>
> Nothing below has been tested on hardware. It is written now so the
> reasoning is on record and reviewable *before* an emergency, when
> nobody is thinking clearly. Every command here writes to the device.
> Each requires the owner's explicit, fresh go-ahead for that specific
> command — a decision recorded once does not cover a command run later
> — and every precondition in R1 cleared.

Flip the banner above to REHEARSED / VERIFIED, with a date and a link to
the evidence, only after R5 has actually passed on real hardware for
that specific restore path. Leave the DRAFT text below it for the
historical record rather than deleting it.

---

## R1 — Prerequisites (ALL must hold before ANY restore command is considered)

| # | Prerequisite | Status |
|---|---|---|
| R1.1 | A verified two-pass backup of the full <MCU> flash exists | |
| R1.2 | Backup checksums re-verified on the host immediately before use (`shasum -a 256 -c SHA256SUMS`, every line `OK`) | check at time of use |
| R1.3 | Device reachable in download mode, confirmed by a read-only identification command that reports the expected chip and flash size | check at time of use |
| R1.4 | Battery/power charged, and the cable is not going to be disturbed for the duration | owner |
| R1.5 | The owner has given a go-ahead for the **one specific command** about to run | |
| R1.6 | A tested recovery path exists for *this* restore (see skill body §6 — a dump alone does not satisfy this) | |
| R1.7 | For anything touching removable media (SD/USB): a block-level image of the stock media, taken and verified | |

**`<PORT>` is deliberately not written down anywhere in this file or in
any script.** The owner supplies the serial/USB node at the moment of
use. No procedure in this project may hard-code a real device path.

## R2 — Choose the smallest restore that fixes the fault

Diagnose before writing. The blast radius differs by an order of
magnitude between these rows — always pick the smallest one that
addresses the actual symptom.

| Symptom | Smallest sufficient restore |
|---|---|
| Application misbehaves; bootloader/ROM banner still appears correctly | **R4.1** — application slot only |
| A filesystem/asset region fails to mount | **R4.4** — that region only |
| Device boots a slot we wrote and we want stock back | **R4.3** — revert the boot-selector region; do **not** write an image |
| No boot at all, nothing past the bootloader | **R4.2** — bootloader + layout table, then re-check |
| Device identity/credentials/calibration region corrupted | **R4.5** — identity region, **last resort**, see its warning |
| Unknown fault, multiple regions affected, or a botched multi-region write | **R3** — full restore |

## R3 — DRAFT full-flash restore ⛔ DO NOT RUN

Restores the entire flash in one write from a single verified pass. The
only form that puts the device back exactly as it was at backup time,
including its identity/credential region. Also the highest-risk: it
rewrites the bootloader, so a failure part-way through leaves nothing
bootable, and it reverts any credentials/settings changed since the
backup was taken.

```
# ⛔ DO NOT RUN until R1 is fully met
D="<BACKUP_DIR>"
<FLASH_TOOL> --port <PORT> --chip <SOC_FAMILY> --before no-reset --after no-reset \
    write-flash --flash-mode <FLASH_MODE> --flash-freq <FLASH_FREQ> --flash-size <FLASH_SIZE> \
    0x0 "$D/<FULL_DUMP_PASS1>"
```

**Why the flash parameters are explicit:** without them, many tools
rewrite header bytes to match what they auto-detect, which silently
changes the image and would make R5's "restored == backup" comparison
fail for a reason that is not a real fault. Use the values read off the
device during backup (§3 of the skill body), not defaults.

**Why `--after no-reset`:** the device must stay in download mode so R5
can read back and compare *before* anything is allowed to boot.

## R4 — DRAFT per-region restore ⛔ DO NOT RUN — preferred over R3

Offsets are **device-read** (from your own decoded layout table), never
a vendor default or a value copied from another unit. Run **at most one**
of these per go-ahead.

```
D="<BACKUP_DIR>"
E="<FLASH_TOOL> --port <PORT> --chip <SOC_FAMILY> --before no-reset --after no-reset"
```

**R4.1 — the application (the common case, and the safest of these):**
```
# ⛔ DO NOT RUN
$E write-flash --flash-mode <FLASH_MODE> --flash-freq <FLASH_FREQ> --flash-size <FLASH_SIZE> \
    <APP_OFFSET> "$D/carved/<APP_REGION_NAME>.bin"
```
Leaves the boot chain, identity region and other filesystems untouched.

**R4.2 — the boot chain (only if the device does not boot at all):**
```
# ⛔ DO NOT RUN — two separate commands, two separate go-aheads
$E write-flash --flash-mode <FLASH_MODE> --flash-freq <FLASH_FREQ> --flash-size <FLASH_SIZE> \
    0x000000 "$D/carved/<BOOTLOADER_NAME>.bin"
$E write-flash <LAYOUT_TABLE_OFFSET> "$D/carved/<LAYOUT_TABLE_NAME>.bin"
```
Do the bootloader first, re-read and compare (R5), and only then the
table. If the table format carries its own checksum, verify that
independently of trusting the write.

**R4.3 — force a boot back to the default slot (no data written):**
```
# ⛔ DO NOT RUN
$E erase-region <SELECTOR_OFFSET> <SELECTOR_SIZE>
```
If the stock/erased state of the selector region is what makes the
bootloader fall through to the desired default slot, erasing reproduces
that state exactly. Prefer this over writing a captured selector image
back — same result, no image to get wrong. This is the lever that undoes
any custom slot the project ever wrote into.

**R4.4 — a filesystem/asset region:**
```
# ⛔ DO NOT RUN
$E write-flash <FS_OFFSET> "$D/carved/<FS_REGION_NAME>.bin"
```
⚠ If the region is a wear-levelled or otherwise wrapped container rather
than a bare filesystem image, write the **whole captured container**,
never a derived/unwrapped copy meant only for inspection — writing an
unwrapped image to the raw offset produces something the device cannot
mount.

**R4.5 — the identity/credential/calibration region ⚠⚠ LAST RESORT:**
```
# ⛔ DO NOT RUN — reverts device identity, credentials and calibration to backup-time state
$E write-flash <IDENTITY_OFFSET> "$D/carved/<IDENTITY_REGION_NAME>.bin"
```
Never part of a routine restore. If the device has been re-provisioned
since the backup was taken, this silently undoes that. Consider a
factory reset + re-pair/re-provision first: it costs recalibration
(recalibrated, not restored) but touches nothing else.

**R4.6 — a calibration region that is legitimately blank:**
```
# ⛔ DO NOT RUN
$E erase-region <CAL_REGION_OFFSET> <CAL_REGION_SIZE>
```
Only if the stock state for this region really is its erased value (see
skill body §8's first trap) — confirm this from a boot log or equivalent
before treating "blank" as the correct target state.

**Never restore a wholly-erased region by writing an image of it back** —
writing pages of the erased-state byte is a slow no-op; use
`erase-region` for that region instead.

## R5 — DRAFT verification after any restore ⛔ mandatory, and it comes BEFORE the reboot

**Read back and compare while the device is still in download mode.** A
write that reported success is not a write that landed.

**R5.1 — whole-flash comparison (after R3):**
```
# ⛔ DO NOT RUN
$E read-flash 0x0 <FLASH_SIZE_HEX> "$D/verify-readback.bin"
cmp "$D/verify-readback.bin" "$D/<FULL_DUMP_PASS1>"     # must be silent
shasum -a 256 "$D/verify-readback.bin"                  # must match the recorded backup hash
```

**R5.2 — region comparison (after any R4 step)** — read back exactly the
region written:
```
# ⛔ DO NOT RUN — example for R4.1
$E read-flash <APP_OFFSET> <APP_SIZE> "$D/verify-app.bin"
shasum -a 256 "$D/verify-app.bin" "$D/carved/<APP_REGION_NAME>.bin"   # must match
```

**R5.3 — structural re-checks that do not depend on trusting the write:**
- Re-parse the written image's own header/checksum, if it has one — a
  valid application image checksum and hash are evidence the write
  landed correctly, independent of the byte-compare above.
- Recompute the layout table's own checksum, if the format carries one.
- Re-parse any restored filesystem and confirm its expected file
  count/free-space figure matches a known-good baseline (a boot log's
  own reported free-space line, if one exists, is a strong independent
  check).

**If any comparison fails: do not reboot.** Stay in download mode and
re-write. A device sitting in download mode with a bad image is
recoverable; a device that has been reset into a bad image may not
re-enumerate.

## R6 — DRAFT reboot procedure ⛔ only after every R5 check passes

1. **All R5 comparisons pass. No exceptions, no "close enough."**
2. **Leave download mode without writing anything else.** Either do the
   device's normal physical exit (unplug + full power cycle — see the
   skill body's multi-MCU reset trap), or issue one final,
   deliberate reset-class command. This should be the **first**
   `--after hard-reset`-equivalent step in the whole procedure —
   everything before it stays in no-reset mode precisely so this moment
   is separate and intentional.
3. **Watch the boot log** (if a console is available) and compare it
   against a known-good baseline captured before any of this started.
   Expect the same sequence of init lines, in the same order, with the
   same key figures (free-space counts, version strings) as the baseline.
4. **Functional check on the device itself:** whatever "the device works
   normally" means for this project — UI responds, peripherals detected,
   removable media still mounts with its expected contents.
5. **Only then** consider the recovery path exercised — and record that a
   successful restore of a known-good image is what finally satisfies
   R1.6 / the skill body's "tested recovery path" gate. Amend the
   decision record with the date and the exact commands run.

## R7 — What this restore path still cannot recover

State this list honestly for your own project — do not leave it
templated:

- <ANYTHING WITH NO KNOWN DOWNLOAD-MODE ROUTE — e.g. a companion MCU with
  no strap line from the main chip>
- <ANY REMOVABLE MEDIA NOT YET IMAGED AT THE BLOCK LEVEL>
- <ANY PROTECTION STATE NEVER READ — e.g. secure-boot/read-protection
  fuses, if reading them requires a route not yet established>
- **Anything changed on the device after the backup was taken** — a
  backup is a snapshot, and any identity/credential/calibration region in
  particular drifts every time the device is used normally.
