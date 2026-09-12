# Updater acceptance worksheet

Fill this in from the updater's own code (disassembly, decompiled firmware, or an available SDK
source) before writing a single line of packaging tooling. Cite evidence for every row — an
address, a function name, a byte-level scan result — and grade it CONFIRMED / STRONGLY INDICATED /
POSSIBLE / UNKNOWN, or this project's equivalent evidence standard. Leave a row UNKNOWN rather than
guess; an unanswered row is safer than a wrong answer treated as settled.

A worked-example column is included throughout, drawn from a real device's stock SD-card updater
(an ESP32-class SoC reading a `.tar` from a microSD card at a fixed path), to show the level of
specificity and the evidence style each answer should reach. Replace it with your own device's
findings — do not copy these values, they are illustrative only.

---

## Q1 — Trigger

What makes the updater run at all?

- [ ] File existence at a fixed path
- [ ] A button/pin held at boot (which one? active-high or active-low? sampled once, or polled?)
- [ ] A menu selection in a UI
- [ ] A magic value in NVS/EEPROM/a config sector
- [ ] Other: ______

**Your answer:** _______________________________________________

**Worked example:** `stat("/<MOUNT>/Updates/<PACKAGE>.tar") == 0` at boot, and nothing else — not
combined with any other condition. A DOWN-button hold is checked, but only *after* this trigger
already decided update-mode is entered, as an escape hatch (see Q1a) — it is not part of the
trigger itself. **CONFIRMED** by disassembly of the boot-mode-selection function: return value is
`(stat succeeded)`, doubled into a mode constant, with no other input.

**Q1a — is there an escape hatch, and exactly when is it sampled?**

**Worked example:** yes — a specific GPIO checked **exactly once**, immediately before the install
routine is called, never polled again once installation begins. Must be held from power-on, not
applied reactively after the screen shows activity. **CONFIRMED** by disassembly (single read site
identified, no other reference to that GPIO in the update path).

---

## Q2 — Path and filename

Exact, case-sensitive location and name(s).

**Your answer:** _______________________________________________

**Worked example:** `/<MOUNT>/Updates/<PACKAGE>.tar` for the trigger file itself. Internally, one
extracted member (a companion-MCU image) is looked up in **all caps** in every read site, while
the vendor's own release archive ships that same member in **mixed case** — works only because
the filesystem in use matches names case-insensitively. **Lesson: match the vendor's on-disk
casing exactly in a hand-built package; do not "fix" an inconsistency you notice in their own
naming.**

---

## Q3 — Container format

**Your answer:** _______________________________________________

**Worked example:** a `.tar`, read by a specific, identifiable embedded minimal-tar library
(confirmed by matching the disassembled header-parsing routine's exact field offsets — `mode`,
`owner`, `size`, `mtime`, `checksum`, `type`, `linkname` — against that library's known struct
layout, byte-for-byte). Identifying the *specific* library mattered: its source (being small and
often open) then answered several other rows directly instead of requiring more disassembly.

---

## Q4 — Member set and lookup method

**Your answer (required members):** _______________________________________________
**Your answer (optional members):** _______________________________________________
**By name or by position?** _______________________________________________

**Worked example:** three possible members (a main-SoC app image, an assets archive, and a
companion-MCU image), each handled by an independent, named lookup after full extraction — **by
name, order-irrelevant**,
CONFIRMED by reading the post-extraction dispatch code (each step calls its own `stat()` on its own
fixed path). This meant a hand-built package could reorder members from the vendor's own layout
with no effect — verified, not assumed.

---

## Q5 — Per-member validation

**Your answer:** _______________________________________________

**Worked example:** container-level — every tar header's checksum field is verified (bad checksum
= parse error). Payload-level — the main app image separately carries its own magic byte, header
sanity, and an appended hash, checked by the platform's own OTA-image-finalize routine, entirely
independent of the tar layer.

---

## Q6 — Size / version checks — name the actual operands

Do not write down what an error message *implies* is checked. Trace the actual two values compared.

**Your answer (what is compared):** _______________________________________________
**Is it a manifest field, a stored constant, a partition size, or a same-file tautology?**
_______________________________________________

**Worked example:** a "file size mismatch" error existed and *sounded* like it checked an
extracted file against a declared size in some manifest. Disassembly showed both operands were
`stat().st_size` of the identical file, read via two separate `stat()` calls microseconds apart —
a tautology that can only fail if the filesystem returns inconsistent results between two calls on
the same path (a failing card, not a real content check). **CONFIRMED** by reading both call sites
and their calling convention. Consequence: no manifest, no declared size, and no version field of
any kind was needed anywhere in the package — writing one would have been pure waste, and (per
Q9/Q13-style side effects on other devices) writing an *unrelated* manifest file the updater does
still delete-on-sight could plausibly matter for some other install mode's cleanup pass. Read the
full disassembly reasoning before assuming "a manifest can't hurt."

---

## Q7 — Container-parser quirks

- [ ] Regular files only? (are directory/symlink/typed entries silently skipped?)
- [ ] Extended/long-name headers supported, or silently skipped (and what happens to a member that
      follows a skipped one)?
- [ ] Flat names required (does the extractor ever call an equivalent of `mkdir`, or does it open
      output paths with an API that simply fails on a `/` in the name)?
- [ ] Nested archives expanded automatically? To what depth, and gated by what condition?

**Your answer:** _______________________________________________

**Worked example:** regular-file entries only (typeflag must be the ustar REGTYPE value); no
`mkdir` anywhere in the extractor, output opened via a flat-file API that fails outright on a `/`
in the name — so member names must be flat, ≤ the parser's fixed name-buffer length, no `./`
prefix, no ustar `prefix`-field splitting (unsupported, silently dropped). One level of *nested*
archive expansion exists, gated by an argument that a first disassembly pass misread as unused
(corrected on a byte-level re-scan) — a second archive member (extension `.tar`, checked by an
exact 4-byte case-sensitive suffix compare) is expanded once, into the same output directory, not
recursively beyond that.

---

## Q8 — Write destination and commit point

For each member: **where does it land**, and **in what order are members processed**? Specifically:
**at what point is any boot-selection state committed, relative to remaining steps?**

**Your answer:** _______________________________________________

**Worked example:** the main app image is written to whichever OTA-style slot is not currently
selected, and boot selection is switched to it **immediately upon successful write** — before the
second member (an assets/resource partition) is even looked at. If that second step's file is
missing or its own copy fails, the overall install reports failure — **but the boot-partition
switch already happened**, and the device boots the new firmware regardless. **CONFIRMED** by
reading the orchestrating function's control flow directly. This is the single most consequential
finding in the whole worksheet: it means "install reported failure" and "old firmware is still
running" are not the same fact, and any hand-built package that ships only the main image without
also shipping a valid resource-partition member is not a shortcut, it's a trap that half-installs
in the most confusing possible way.

---

## Q9 — Malformed-input behavior (the load-bearing one)

Does a corrupt/truncated member fail the whole install loudly, or does the parser's main loop treat
"ran out of valid headers because the file is corrupt here" the same as "ran out of headers because
this is the legitimate end of the archive"?

**Your answer:** _______________________________________________

**Worked example:** **CONFIRMED dangerous** — the extractor's main loop exits through its normal
"successfully extracted" path on *any* non-zero header-parse result, including the specific error
code for a bad header checksum. A tar truncated or corrupted exactly at a header boundary extracts
every member before the damage, logs a success line, and the install proceeds with a partial
member set. Combined with the Q8 finding (commit before the last step), a package that gets
corrupted between its first and second member can result in new firmware live and running with a
missing or stale second member, self-reported as a success. **Mitigation used:** verify the
package's hash on the host, and independently re-read the archive's own member list and count
before it ever reaches the device — never rely on the on-device success log alone.

---

## Q10 — The unrecoverable write

Which member, if its write goes wrong mid-transfer, has **no software recovery path** — no
readback, no verify, no re-flash route via anything already on the device?

**Your answer:** _______________________________________________

**Worked example:** a companion microcontroller, updated over a simple UART push protocol with no
readback and (per the analysis) surprisingly lax failure handling on the sending side — several
distinct failure/timeout conditions all logged and then treated as "proceeding anyway" /
"assuming success" rather than retried or aborted. No tooling exists on the project to recover this
component if a transfer is interrupted (e.g. power loss mid-write). **Decision:** omit this member
from the package entirely for a first install — its absence causes the corresponding check-for-update
function to simply return false and skip the entire branch (no GPIO handshake asserted, no UART
transfer attempted at all) — the zero-risk option, confirmed by reading the gating condition
directly rather than assuming "absent" behaves gracefully.

---

## Q11 — Rollback / fallback behavior

Does the bootloader auto-revert a bad image? Under exactly what condition?

**Your answer:** _______________________________________________

**Worked example:** **CONFIRMED absent** — the rollback-confirmation call an app is expected to
make, and the corresponding "is rollback possible" check, are both **absent from the shipped
image** (a negative finding, confirmed by an exhaustive scan for both symbols/strings). Corollary
tested independently: if automatic rollback *were* active, an app that never confirms itself would
be reverted on every single update, which contradicts the observed fact that the vendor's own
updates demonstrably stick. The bootloader *does* fall back to a known-good slot, but **only while
its boot-selection record is blank or otherwise invalid** — i.e., only in the device's untouched,
pre-any-install state. The moment a first successful install writes a valid boot-selection record,
that fallback stops applying to future failures. Any recovery route after that point must be
manual (see Q10 in the main skill's §8, "Return to stock").

---

## Q12 — Version / downgrade gate

**Your answer:** _______________________________________________

**Worked example:** **CONFIRMED absent** on this update path — no string-compare against any
version field anywhere between the trigger and the commit point. Downgrades, sidegrades, and
repeated installs of the identical image are all accepted with no special handling. (A *separate*,
unrelated update path on the same device, reachable only over Wi-Fi, does parse a version field
from a manifest — but that manifest format and that code path are never reached by the local/SD
route at all, which is itself worth confirming explicitly rather than assuming "the device has a
version check" applies uniformly across every update mechanism it supports.)

---

## Q13 — Post-install state writes

**Your answer:** _______________________________________________

**Worked example:** **CONFIRMED none** — an exhaustive scan of every call target inside the
updater's own function span found no writes to the device's persistent settings store at all.
Loop-prevention (not retrying the same install forever) is accomplished purely by the trigger file
being deleted immediately after a successful extraction — not by any flag. Consequence: a hand-built
image has no implicit "I was just installed, go clear a flag" contract to honor on next boot.

---

## Using this worksheet

1. Copy this file (or the blank rows) into your own project's docs, one per device/updater you are
   reverse-engineering.
2. Answer every row from code, not from vendor documentation or forum folklore — vendor docs are
   useful for corroboration, not as the primary source.
3. Feed the answers into the main skill's §2 (hard requirements vs. non-requirements) and §3
   (staging around Q10's answer) directly — this worksheet is the evidence base those two lists
   are built from.
4. Track each row's evidence grade in
   `${CLAUDE_PLUGIN_ROOT}/templates/verification-matrix.md` (plugin install) or
   `templates/verification-matrix.md` (repo checkout) if this project uses that template.
