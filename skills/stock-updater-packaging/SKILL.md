---
name: stock-updater-packaging
description: Install custom firmware through a device vendor updater path (SD card, USB mass storage, or OTA archive) instead of a hardware programmer -- derive the updater acceptance rules, build a conforming package, rehearse the pipeline against the stock release, and stage a first install safely. Use when a device has a stock update mechanism and you want to run your own build on it, or to reinstall stock as a recovery path.
---

# Stock updater packaging

Most consumer devices ship an updater that will install *any* image satisfying its acceptance
rules -- it does not know or care whether the bytes came from the vendor. If you can derive those
rules, you can run custom firmware with no programmer, no soldering, and no chip-erase write, and
the same path reinstalls stock, which makes it a recovery mechanism too. This is usually the
single highest-leverage move available on a device with a stock update mechanism -- try it before
reaching for a hardware programmer.

The catch: the rules that make it work are never documented and are rarely intuitive. They come
from reading the updater's own code (disassembly, decompiled firmware, or a leaked/OSS SDK) --
not from guessing at a plausible container format. This skill is the checklist for deriving those
rules safely, the staging discipline for a first install, and the rehearsal that proves your
packaging pipeline before it is ever trusted with a non-stock image.

**Prerequisite mindset:** everything in this skill is a *host-side, read-only* activity until an
explicit, separately-gated "stage this on the device" step. Follow whatever hardware safety
process this project uses (see the `hardware-recon` and `moderator-operating-model` skills) for
gating the actual on-device step -- this skill only covers getting a correct package built and
verified.

## 1. Derive the acceptance rules before building anything

Do not start writing a packaging script until you can answer every question below **from the
updater's own code**, not from an error-message's wording, a forum post, or what seems reasonable.
Vendor error strings routinely describe a check inconsistently with what the code actually does --
the worked example below found a "file size mismatch" error whose two operands were both
`stat()` of the *same file*, taken microseconds apart, i.e. a tautology that can never fire on a
legitimately-written file. Trusting the string instead of the disassembly would have produced a
totally unnecessary manifest field.

The fill-in questionnaire is `references/updater-acceptance-worksheet.md` (linked at the end of
this file) -- use it to record your answers and their evidence grade as you go. The categories:

| # | Question | Why it matters |
|---|---|---|
| Q1 | **Trigger** — what makes the updater run at all? File existence at a fixed path, a button held at boot, a menu selection, a magic value in NVS/EEPROM? | Determines the minimum condition for an *accidental* install, and thus a safety rule ("never leave the trigger artifact staged"). |
| Q2 | **Path and filename** — exact, case-sensitive location and name(s) the updater looks for. | Get this byte-exact. A vendor image that ships a member under one case (`Foo.bin`) while every *lookup* in the code uses another (`FOO.BIN`) works only because the filesystem matches case-insensitively — match the vendor's on-disk casing in a hand-built package, don't "fix" it. |
| Q3 | **Container format** — tar, zip, a custom framed blob, a directory of loose files? Which exact library/parser reads it (stock `tar`? a minimal third-party parser embedded in firmware, e.g. microtar-class code)? | The *specific* parser's quirks (see Q7) are what actually constrains you, not the nominal format's spec. |
| Q4 | **Member set** — which files/segments are required, which are optional, and does the parser look them up **by name** or **by position**? | If lookup is by name, member *order* in your archive is free even if it differs from the vendor's own layout — confirm this with the parser code, don't assume. |
| Q5 | **Per-member validation** — checksum, magic bytes, signature, size field? At what layer (container header vs. payload image header)? | A tar-level header checksum and an application-image's own magic+checksum are usually two independent checks; get both right. |
| Q6 | **Size / version checks — read the actual operands.** What are the two things being compared, concretely (a stated length vs. bytes actually present; a `stat()` result vs. a stored value; two `stat()` calls on the same path)? | This is the check most likely to be a red herring. Never write a manifest field or declare a size just because an error message implies one is checked — verify what is actually compared before adding anything to satisfy it. |
| Q7 | **Container-parser quirks** — regular-files-only? No subdirectories (does it call `mkdir`, or open output paths with a flat-file API that fails on `/`)? Extended/long-name headers (PAX, GNU longname) supported or silently skipped? Nested archives expanded, and to what depth? | These come only from reading the specific parser. A minimal embedded tar/zip reader is usually a small, faithful compile of a well-known minimal library — once you identify which one, its source (if available) tells you the exact constraints. |
| Q8 | **Write destination and commit point** — where does each member land (which partition/slot), and in what order are members installed? **Specifically: at what point is the new boot selection committed, relative to any other steps that could still fail?** | The most dangerous shape is "commit before the last step" — an installer that switches the active boot partition for member A, then processes member B, and reports overall failure if B fails **while A is already live and bootable.** A failure log after this point does not mean nothing was written. |
| Q9 | **Malformed-input behavior** — does a corrupt/truncated member fail the whole install loudly, or does the parser silently exit via its own "success" path on truncation? | The single most load-bearing failure mode to characterize. A parser whose main loop treats "no more valid headers" and "hit corruption" identically will report a clean install after a partial one — see §6 and §7. |
| Q10 | **Which write, if any, is unrecoverable from software** — a companion MCU flashed over a simple serial protocol with no readback/verify, an EEPROM with no backup partition, anything with no re-flash path if it goes wrong mid-write? | Defines the Stage A / Stage B split in §3. Everything else on the device may have *some* recovery route (a debug/download interface, a second boot slot); design around the one thing that provably does not. |
| Q11 | **Rollback / fallback behavior** — does the bootloader auto-revert a bad image? Under what exact condition (only while a boot-selection record is blank/invalid, or something broader)? | If rollback exists only for the *pre-any-install* state, then "the bootloader will save us" **stops being true** the moment your first install completes, even if that first install was of pristine stock content. Write this down explicitly. |
| Q12 | **Version/downgrade gate** — does one exist, and where? | Don't assume either way; a missing gate means arbitrary re-installs (including of your own build, repeatedly) are accepted, which is useful for iteration but also means nothing stops an accidental downgrade. |
| Q13 | **State written after a successful install** — any flag, counter, or key in persistent settings storage that your own image should account for (or avoid depending on) on its next boot? | Determines whether your firmware has any implicit "I was just installed" contract to honor. |

Grade every answer CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN (or this project's
equivalent evidence standard) and cite the exact evidence — a disassembly address, a decompiled
function name, a byte-level scan result. **A linear disassembly listing can mis-tile itself around
variable-length instructions and silently render a wrong answer that still looks plausible** — for
any answer that changes what you build, re-derive it by realigning at the actual branch target, or
by an independent byte-level scan for the exact encoding you expect, not by trusting one linear
read-through.

## 2. Hard requirements vs. explicit non-requirements

Once Q1–Q13 are answered, write down two lists, not one. The second list is just as important as
the first:

**Hard requirements** — the literal set of things your package must satisfy, each traced to the
question above that established it (exact path, exact member names, exact typeflags/headers,
checksum validity, size ceiling, chip/architecture match for any binary image).

**Explicit non-requirements** — things a cautious builder is tempted to add that the updater
provably does not check: a manifest/index file it never parses, a size or version *declaration*
when the real check is a same-file tautology (Q6), a signature beyond whatever the payload
image's own bootloader-level validation already does, a specific member order when lookup is
by-name, a companion-image write when your first goal is only the main SoC. **Every item on this
list should cite the specific evidence that it is unneeded** — "no code path reads this file" or
"the only consumer of this format is a code path this install method never reaches" are the kind
of claims that belong here. Skipping this list is how a project ends up shipping a synthetic
manifest that accomplishes nothing and, worse, invites a code path (e.g. a network-based updater
variant) that was never meant to be reachable this way.

## 3. Staged install — omit the unrecoverable member first

However Q10 answered "which write has no software recovery path," **Stage A ships everything
except that member.** Concretely:

- Stage A package = every required member **except** the one identified in Q10, if the format and
  parser allow a member to be omitted cleanly (confirm this too — some parsers require a
  placeholder even for an "optional" step; know the difference between "member absent" and
  "member present but empty" before relying on either).
- Only after Stage A is built, rehearsed (§4), and verified on the actual device does anything
  involving the unrecoverable member get considered at all — as an explicit Stage B, with its own
  separate go-ahead.
- If the format has no way to omit that member and get a clean partial install, Stage A instead
  means shipping that member **byte-identical to the current stock content** — a write that is a
  functional no-op even though bytes do cross the wire, which is the next-safest thing to omitting
  it outright.

This staging discipline is the single biggest lever for keeping a first attempt low-stakes: it
turns "does this whole pipeline work at all, on this exact device" into a question you can answer
without ever touching the one component you cannot get back if it goes wrong.

## 4. The rehearsal — prove the pipeline before it packages anything new

Before a hand-built package ever contains non-stock content, run your packaging tool in a
**stock-only** mode: feed it a genuine vendor release archive, have it re-extract that archive's
own members, restage them, and re-container them through the *exact same code path* your tool uses
for a real build — then assert the result is **member-identical** (same bytes, per member, not
per-archive) to the original.

```
<packaging-tool> --stock-only --stock-from <vendor-release-archive> --out <scratch-dir>
# tool re-extracts <vendor-release-archive>'s own members, restages them, rebuilds the
# container, and must report all members MATCH (byte-identical) against the source archive.
```

**If this does not come out byte-identical, the pipeline is not trustworthy for anything else** —
stop and fix the packaging code, don't proceed to build a non-stock package with it. Two gotchas
found the hard way that are worth checking for specifically:

- **Whole-archive hashes will legitimately differ between two runs even when every member's
  content is identical** — most archive formats record a timestamp, owner, or similar metadata
  per entry, so re-running the same build twice (or comparing a freshly-rebuilt archive against an
  older archived one) can produce different container-level bytes for identical payload content.
  Compare **per member**, by extracting each one and hashing it independently — never compare
  whole-archive hashes as the pass/fail signal.
- **Member order may differ from the vendor's own archive and still be correct**, if Q4 established
  the parser looks members up by name. Verify order-independence explicitly rather than fighting
  to match the vendor's byte layout.

## 5. The tool takes the stock source as an argument — it ships no vendor bytes

The packaging tool itself must accept the vendor's stock release archive as a required flag or a
documented local path, and must **fail with a clear error** (not a silent fallback, not a bundled
copy) when that input is missing. A toolkit built from this process ships zero vendor binaries and
zero vendor text — every command example uses a placeholder path the user fills in with their own,
separately-obtained release. If your project keeps a local copy of the vendor archive for its own
use, that copy stays out of anything published.

## 6. Verification before the package ever reaches the device

Before a package is staged on the device (SD card, USB drive, wherever the updater reads it from):

1. **Hash the built package and each of its members** (`sha256sum`/`shasum -a 256`), and keep the
   member-level hashes as the durable record — see §4 on why whole-archive hashes drift.
2. **Verify the copy on the removable media against that hash before ejecting it.** A file that
   copies short or gets corrupted in transit is a real failure mode, and it's nearly free to catch
   here versus discovering it mid-install.
3. **Confirm the packaged image member is byte-identical to your own build output** — an extra
   safety net against packaging the wrong file (an old build, a build for the wrong target chip).
4. If the underlying payload format has its own local validator (many embedded image formats do —
   check for one that runs entirely offline against the file, no device contact required), run it
   and require it to report the correct target chip/architecture, a valid checksum, and a size
   under whatever partition/slot ceiling Q8 established.

Only once all of the above pass does the package get copied to the media the device actually
reads from.

## 7. Watch the install — know the log signature and the failure shapes

Before staging anything for real, write down the **expected log line sequence** for a successful
install, in order, derived from the same code reading that answered Q1–Q13. Watching for a
deviation from that sequence — not just "did it seem to work" — is the actual verification.

Three failure shapes to watch for specifically, because each looks different from a clean success
and each means something different:

- **Boot loop** — the new image never gets past some early stage and the device keeps resetting.
  If Q11 established rollback exists only pre-commit, a boot loop *after* the point of commit will
  not self-heal; this is the scenario that Stage A/Stage B staging (§3) and a rehearsed recovery
  route (§8) exist for.
- **Silent no-op** — the trigger condition (Q1) wasn't actually satisfied, or a pre-clean step
  removed your staged file before the updater got to it; the device just boots normally on the old
  image with no error at all. Confirm the trigger fired (a "checking for update" — or equivalent —
  log line) before concluding an install even attempted to run.
- **Reported success on a bad package** — the dangerous one. If Q9 found that the parser's main
  loop exits through its own success path on a truncated or corrupted member, a package damaged
  after step N but before step N+1 can extract the first N members, report a clean success line,
  and still be a partial install — see the commit-point interaction in Q8. This is the strongest
  argument for the hash verification in §6 happening *before* the card ever goes near the device,
  since the on-device log alone cannot always distinguish this from a real success.

## 8. Return to stock

The same packaging pipeline is the recovery path: build a Stage A-shaped (or full, once trusted)
package from a **genuine vendor release archive** and install it through the identical procedure.
Two return routes are typical:

- **Reapply a stock package via the same updater path.** This writes stock content back into
  whichever slot the device's boot-selection state currently is *not* pointing at (Q8) — verify
  this is what you want (it restores current stock functionality; it does not, on most designs,
  restore a factory-original build that predates the update mechanism itself).
- **Clear the boot-selection state directly**, if the device stores it in a distinct,
  known-offset partition/record (an OTA-selector, boot-config sector, or similar) separate from
  either app slot — reproducing that record's known-blank/invalid state typically makes the
  bootloader fall back to whatever slot it treats as default (often an original factory slot the
  update mechanism never touches at all). This is usually a smaller, more surgical write than a
  full reinstall, but it is still a direct low-level write to the device and should be gated with
  the same care as any other write in this project's hardware safety process — see
  `hardware-recon` and `mcu-safe-backup`.

Record the exact command and the exact offset/length for whichever route applies to `<DEVICE>` in
your own project's recovery documentation — this skill's job is to establish that a return path
exists and how to verify it, not to hand you a specific address, which is device-specific and must
come from your own Q8/Q11 findings.

## A pitfall from outside the packaging step itself

If you also write firmware that runs the update-installation logic yourself (rather than only
using this technique against the vendor's own stock updater), remember that install-time code
tends to need real stack: a header-parsing buffer plus a streaming I/O buffer plus everything the
underlying filesystem/flash-write/crypto call chain needs underneath them can easily exceed a
default RTOS main-task stack sized for "launch other tasks and return." Give install logic its own
appropriately-sized task rather than growing the whole system's default stack budget — cheaper at
runtime, and it keeps the relationship between "how big are my buffers" and "how big is my stack"
visible in one place instead of implicit. This is a startlingly easy way to turn a correctly
packaged, correctly accepted update into a clean, deterministic boot-loop that has nothing to do
with the packaging rules in this skill at all.

## Templates and further reading

- `references/updater-acceptance-worksheet.md` (next to this file) — the fill-in questionnaire
  from §1, with a worked example's answers included as an illustration of the evidence-grading
  style.
- `${CLAUDE_PLUGIN_ROOT}/templates/verification-matrix.md` (plugin install) or
  `templates/verification-matrix.md` (repo checkout) — track Q1–Q13's answers with an evidence
  grade per row.
- `${CLAUDE_PLUGIN_ROOT}/templates/decision-record.md` or `templates/decision-record.md` — record
  the Stage A composition decision (§3) and any point where you deliberately diverge from "match
  the vendor's own package shape as closely as possible" (as with omitting the unrecoverable
  member) — that reasoning is exactly the kind of thing a future reader needs spelled out, not
  inferred.
- `${CLAUDE_PLUGIN_ROOT}/templates/incident-report.md` or `templates/incident-report.md` — if a
  rehearsal or install does go wrong, write it up in this shape rather than only in chat/log
  scrollback; see the `hardware-recon` and `moderator-operating-model` skills for the project's
  broader documentation and safety practices this skill assumes.
- `scripts/make-update-tar.sh` (in this toolkit) — a worked, generic implementation of the
  packaging tool described throughout this skill: takes a stock release archive as an explicit
  flag, validates a payload image locally (no device contact), builds a container with the exact
  member set requested, supports omitting an unrecoverable member, and includes a `--stock-only`
  rehearsal mode per §4. Read its own `--help` output and header comment for the full option
  reference — it is written for a tar-based, stat-triggered updater specifically, and its
  structure (not its literal flags) is the pattern to adapt to a different container format or
  trigger mechanism.
