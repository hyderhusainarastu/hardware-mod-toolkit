---
name: firmware-image-analysis
description: "Analyse a firmware image or vendor update archive statically: decode the partition table and image headers, determine whether it is signed or encrypted, mine strings and log formats, map subsystems, and read the few functions that matter. Use when reverse engineering device behaviour from a firmware binary instead of from hardware, and when deciding what a custom build must reproduce."
---

# Firmware image analysis

Most of what a hardware mod needs to know — the display controller's real command set, the
inter-MCU protocol's exact framing, the I2C addresses, the updater's acceptance rules, the boot-mode
gestures — comes out of a vendor image, not out of probing the board. It is the cheap, zero-risk
path, and it is the one people skip because it looks like it needs a disassembler and weeks of
free time. It doesn't. Most of the value in this skill came from 20-instruction reads anchored on a
log string, not from decompiling anything.

This skill assumes a `<SOC_FAMILY>` app-image format (ESP-IDF's is used as the worked example
throughout — image magic `0xE9`, segment table, appended SHA-256, `esp_app_desc_t`), but the method
generalizes to any MCU with a documented image header and an OTA/bootloader split. Adjust the byte
offsets, keep the discipline.

Use `templates/recon-findings.md` for the write-up shell and `templates/verification-matrix.md` to
track which claims are image-level vs device-confirmed. Reference command lines live in
`references/tool-invocations.md`; the document skeleton this skill produces is in
`references/analysis-record.md`. Load
`${CLAUDE_PLUGIN_ROOT}/templates/recon-findings.md` from a plugin install, or `templates/recon-findings.md`
from a repo checkout.

## 0. The one rule everything else follows

**A string (or a call site) in an image proves that code exists in that image. It does not prove
the code runs, that the peripheral is fitted, or how it is wired.** Every claim that comes from
`strings` or from a linked-symbol table is a claim about *the binary*. A claim about the physical
`<DEVICE>` needs an extra, independent leg of evidence (a boot-log line, a photograph, a probe) —
and when you promote a claim from image-level to device-level, name that extra leg explicitly in
the write-up. When there is no extra leg, the claim stays at image level and says so.

Grade every claim CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN (see your project's evidence
standard — usually in the top-level `CLAUDE.md`). A finding that later turns out wrong should be
marked **superseded**, not silently edited away — the correction and what caused it are worth as
much as the finding itself, because the next person doing this on a different device will hit the
same trap.

## 1. Provenance first

Before reading a single byte of an image, record:

- Where it came from (vendor site, OTA capture, extracted from a device you already dumped),
  retrieved date, and — if it's an update package — the vendor's own version string.
- Its SHA-256, and the SHA-256 of every member if it's a container (tar/zip).
- Whether an independent copy exists (a second download, a public mirror, the vendor's release
  API) that lets you confirm the file you're analysing is really what the vendor ships, not
  something that was modified in transit or by a previous tool run.
- **Where it lives on disk, and that it is gitignored.** Vendor binaries, and every listing derived
  from them (strings dumps, disassembly notes, extracted assets), go in a backups/vendor-firmware
  style directory that is excluded from version control and never redistributed. This applies even
  when the device is yours and the firmware update is public — a vendor's binary is not yours to
  republish, and a public toolkit repo must never carry one (see the `publish-hygiene` skill).

Write this as a table: file, size, origin, SHA-256, vendor version, retrieved date, stored path,
"committed to git? NO — and it must stay that way."

## 2. The cheap passes, in order

Run these before anything that needs a disassembler. Each one is minutes of work and each one
answers a specific question. Full command lines are in `references/tool-invocations.md`; the
shape:

1. **`file` / size.** Confirms you have what you think you have before spending time on it.
2. **Image header and segment map.** For an ESP-IDF-style image: magic byte, chip ID, segment
   count, entry point, flash size/freq/mode as declared in the header (see the caveat below), each
   segment's load address / length / file offset. Cross-check the vendor tool's output
   (`esptool image_info` or equivalent) against an independent byte-level parse in a 20-line
   script — when both agree exactly, you can trust the numbers; when they disagree, that
   disagreement is itself a finding.
3. **Signed? Encrypted?** — see §2.1 below; this is usually the first question anyone asks and
   the one most likely to be answered wrong by assumption instead of by counting bytes.
4. **Strings with a length filter.** `strings -n 4` (or `-n 8` for a cleaner ESP_LOG-format
   sweep) on the whole image. Skim once for orientation; every serious use after that is a
   targeted `grep`, not a read-through.
5. **Log-format strings.** `ESP_LOG`-family binaries print `"(%lu) %s: <fmt>"` — grepping that
   shape (or your target's equivalent log macro output) surfaces every subsystem's tag and every
   message the firmware can print, which is the fastest way to build the subsystem map in §4.
   These are worth diffing release-to-release: a short, explainable diff (§2.2) is often the
   entire behavioural changelog you need, without opening a disassembler.
6. **Symbol-ish anchors.** Source-path strings (`./components/<name>/<file>.c`), function-looking
   names left in vtables or assert strings, and — for C++ builds — mangled or lightly-demangled
   class::method strings. These give you free function names for the disassembly-lite pass in §5.

### 2.1 Deciding signed / encrypted / anti-rollback from headers alone

- **Signed?** A signature block has its own magic byte and lives *after* the image's own appended
  checksum/hash. Compute where the image's own content actually ends (segments + footer checksum +
  appended hash, exactly) and check whether the file is exactly that long. Zero trailing bytes =
  unsigned at image level. This says nothing about whether the bootloader *requires* a signature —
  that lives in eFuses / OTP, which you do not read as part of static analysis (that's a
  hardware-touching action; see `hardware-in-the-loop-testing`).
- **Encrypted?** A plaintext image parses: the app-descriptor struct decodes into sane version
  strings and dates, and `strings` returns thousands of readable log lines. An encrypted image is
  high-entropy noise from just past the header on. There is no ambiguous middle case here — you
  will know within one command.
- **Anti-rollback?** Most IDF-style images carry a `secure_version` field in the header or app
  descriptor. `secure_version = 0` in every release you have is itself the finding: no rollback
  protection, so an attacker (or your own recovery procedure) can install an older image freely.
- State plainly, every time: **"unsigned" is a claim about the payload. "The device boots unsigned
  payloads" is a claim about the eFuse-configured boot chain. Never let the first stand in for the
  second.**

### 2.2 Diffing releases is a first-class analysis technique

If you can get more than one version of the vendor firmware (an official release archive, a
release API, old OTA captures), diff their string tables:

```
strings -n 8 old.bin | sort -u > old.strings
strings -n 8 new.bin | sort -u > new.strings
comm -13 old.strings new.strings   # added in new
comm -23 old.strings new.strings   # removed in new
```

A short, explainable diff (a dozen added lines, a handful removed) across a version bump that a
release-notes entry describes is strong corroboration that you're looking at the right build, and
it tells you exactly which subsystem the vendor touched without reading a single instruction. It
also protects you from the single most expensive mistake in this whole discipline:

> **Verify you are analysing the version the device actually runs, before writing 1000 lines
> of analysis about a different one.** A device's own boot log (build hash, compile timestamp, IDF
> version, a distinguishing log line only present in some releases) is the cheapest possible check
> and it is worth doing *before* the deep-dive, not after. Getting this wrong doesn't just waste
> the analysis — every offset in it becomes a trap for whoever replays it against the real device.

## 3. Partition table

For any SoC that boots through a partition table (ESP-IDF's is the running example: a 32-byte
entry per partition — magic, type, subtype, offset, size, 16-byte label, flags — terminated by an
MD5 entry), decode it two ways and expect them to agree:

1. **With the vendor/toolchain's own tool** if one ships (`esptool.py <table>.bin --info` or
   equivalent partition-table dump).
2. **With your own ~20-line decoder** reading the raw bytes. When both agree, trust the table. When
   they disagree, that's the finding — write it up before doing anything else with the table.

Two traps specific to vendor *update archives* (as opposed to a full flash dump):

- **An application-slot payload (an OTA `.bin` plus assets) usually contains NO partition table,
  bootloader, `otadata`, or filesystem image at all.** Scan for the partition-magic bytes anyway —
  false positives inside compiled code are common and none of them will decode as a valid,
  MD5-terminated table. State this as a confirmed *absence*, and then state the consequence
  plainly: **the update package is not a recovery image.** It cannot restore a device whose
  bootloader or partition table is damaged, no matter how complete it looks.
- **The regions described by NO partition-table entry are exactly where the traps live.** A
  partition table only ever describes what a normal boot needs; the space it leaves silent (an
  unlabelled gap, a factory-reserved region, whatever sits before the first entry) is worth a
  one-line note even when you have nothing to say about it yet — silence there is not "nothing to
  find," it's "not yet looked at."

Produce a **carve table** — offset, size, type/subtype, label, and (for app slots) which image
currently occupies it if you know — as the artifact this section exists to produce. Everything in
§6 ("implications for the mod") cites offsets from this table.

## 4. Subsystem mapping

Build a responsibility matrix before reading any single function in detail. Columns: subsystem
(display, inter-MCU link, USB, radio/BT, storage/filesystem, updater, power, boot-mode handling);
rows: which image/binary (if the device has more than one MCU) owns it, and the evidence.

The technique that makes this cheap and reliable is a **mutually exclusive presence/absence
argument**, which is much stronger than a one-sided "I found a string, so it must be here":

```
grep -icE '<radio-stack-keyword-set>' primary.bin      # expect 0
grep -icE '<display-driver-keyword-set>' secondary.bin # expect 0
```

If subsystem A's every keyword lands in image 1 and never in image 2, and subsystem B is the exact
mirror image, that's a CONFIRMED architectural split — not just "feature X exists somewhere." Two
things make this reliable rather than a false negative:

- **Match case-sensitively unless you have a specific reason not to**, and re-run once
  case-insensitively as a sanity check. A case-insensitive sweep can pull in an unrelated hit from
  a different stack (e.g. a Bluetooth *host* symbol matching a keyword you meant for USB *host*) —
  when that happens, the conclusion usually survives, but the reproduction command you write down
  needs to match what you actually ran, not what you intended to run.
- **Log tags are a free index.** Every `ESP_LOG`-style tag (`TAG_APP`, `SOMETHING_MGR`, …) found in
  §2's log-format sweep names a subsystem and can be grep-anchored to enumerate every message that
  subsystem can produce — which is often a complete state-machine map with zero disassembly.

## 5. Disassembly-lite

You rarely need full decompilation. The pattern that answers most questions:

1. **Locate a function by its log string, not by scanning code.** A log call's format string
   sits in a literal pool; find the pool slot, find what loads that slot address (an `l32r` on
   Xtensa, an `adrp`/`ldr` pair on ARM, a `lea` on x86 — the mechanism is architecture-specific,
   the technique is not), and you have the call site inside the enclosing function.
2. **Chain string → literal slot → load instruction → enclosing function**, exactly like you would
   chase a cross-reference in a real disassembler, by hand if you don't have one.
3. **Read 20-60 instructions around that point.** You are looking for: which registers hold which
   argument, which API calls are made in what order, and what small integer constants (GPIO
   numbers, addresses, register values) get loaded as immediates. You almost never need more than
   this to answer "what does this do."
4. **Name the constants as you find them**, and write the *evidence* next to each — the exact file
   offset or virtual address of the instruction that proves it, not just the conclusion. The offset
   is what lets someone else (or you, next week) re-derive the claim instead of trusting it blind.

### 5.1 An exhaustive cross-reference is a result in its own right

The single most underused move in this whole discipline: **count every call site of a given API
across the whole image, not just the first one you find.** "A bulk-transfer API exists" and "a
bulk-transfer API is linked but called from exactly three call sites, all size-bounded" are
completely different findings, and only the second one tells a mod project anything actionable.
An absent call is evidence — "no code path ever does X" is a real, citable, CONFIRMED-negative
finding when you've actually enumerated every call site of the relevant API and found none of them
do X, and it is worth stating explicitly as its own row in the findings table, not left implicit.

### 5.2 Two disassembly-specific traps that will burn you

These come from a real pass on a variable-length instruction set and generalize to any ISA with
mixed-width encodings (Xtensa, Thumb-2, RISC-V with compressed instructions):

- **Always realign at the actual branch target, never trust a linear listing across a jump.** A
  variable-width ISA lets one 2-byte instruction shift every following instruction's tiling by one
  byte, turning real code into plausible-looking nonsense a few instructions later. If a
  conclusion matters, re-derive it starting exactly at the address a branch actually lands on —
  don't just keep reading forward from wherever the previous instruction happened to end.
- **Confirm a negative claim ("register X is never written", "this flag is never checked") with a
  byte-level opcode scan, not by reading a linear listing.** A linear listing is exactly the thing
  that hides the one write or read that reverses your conclusion — search for the instruction's
  raw byte encoding directly. Two real findings in the same project were wrong on first pass for
  this exact reason and were only caught by the opcode-scan check; both corrections were recorded
  alongside the fix, not silently folded in, so the next reader could see the method actually being
  applied, not just its result.

## 6. Updater / package formats

Firmware update mechanisms are usually simpler and less validated than people assume, and the way
to find out is to trace the acceptance path from the trigger to the point of no return — not to
assume the vendor validates as much as a security-conscious design would.

Work out, and cite the exact function/offset for each:

1. **What triggers an install check?** File existence at a fixed path is common and is weaker than
   people expect — "the file exists" is not "the file's manifest was parsed."
2. **What container format is it?** Don't assume a purpose-built format — check for an
   off-the-shelf micro-library first (a minimal tar reader, a trivial custom TLV, a stock zip
   library). If it's a known micro-library, its exact constraints become yours for free: which
   `typeflag`s it accepts, whether it supports long names / prefixes / directories, what its
   checksum covers, and — critically — **whether a malformed or truncated header is treated as
   end-of-archive (silent, "successful" truncation) rather than as an error.** That failure mode,
   where a corrupt container reports success instead of failing loudly, is the single most
   dangerous thing to find in an updater, because it means a partially-written update looks
   identical to a complete one from the log output alone.
3. **Exact member names and order it accepts**, and whether name matching is case-sensitive (FAT
   filesystems usually are not, even when the code compares strings that look case-sensitive).
4. **What checksum does it enforce, and on what?** Distinguish a per-file checksum from a
   `stat()`-based size comparison that never leaves the single file it's checking (a comparison
   against *itself*, taken microseconds apart, is not a size gate against any external
   expectation — trace both operands back to their source before writing down what the check
   "validates").
5. **Where does the commit point sit relative to the remaining steps?** If the bootable-partition
   switch happens before a later stage (asset replacement, a companion-chip flash) that can still
   fail, a partial update can leave the device already committed to new firmware with old or
   missing assets. State the exact function and line where the point of no return is crossed, and
   what happens on every branch after it.
6. **Version comparison / anti-downgrade — present or absent, and where?** Absence of a comparison
   *string* is not evidence of absence of comparison *code* — a bare integer or string compare can
   leave no distinctive literal for `strings` to find. Grade this POSSIBLE, not CONFIRMED, unless
   you've actually traced the comparison's absence at the instruction level across every call site
   that could plausibly perform it.
7. **What happens to a companion chip / co-processor**, if there is one? Cheapest-possible finding:
   if the updater's acceptance of a companion-chip image is gated on that image simply being
   *present* in the package, omitting it from your own package is usually the lowest-risk option —
   it skips the whole transfer path rather than risking an interrupted write to hardware you have
   no independent recovery tool for.

Write the accepted-package recipe as a decision-ready table: hard requirements (with the exact
function/offset that enforces each), explicit non-requirements (things people assume are needed but
aren't, each with the evidence that it isn't), and a recommended composition with the exact command
to build it.

## 7. Grade every finding, and cite the address

Every row in every table in the output document ends in one of CONFIRMED / STRONGLY INDICATED /
POSSIBLE / UNKNOWN, and every claim above POSSIBLE cites the exact file offset, virtual address, or
command output that backs it. A claim with no citation is not reproducible, and reproducibility is
the entire point of doing this statically instead of by feel. When a later pass corrects an earlier
one, keep the correction visible in the document (a "superseded" note in place, or a dated
addendum) rather than quietly rewriting history — the method only stays trustworthy if its own
mistakes are traceable.

## 8. What static analysis does NOT establish

State this section explicitly in every write-up; it is not filler.

- **Whether a peripheral referenced in code is actually fitted on this board.** A driver being
  linked in proves the vendor's source tree includes it, nothing about your specific unit.
- **eFuse / OTP / secure-boot / flash-encryption state.** These live outside any image you can
  download and can only be read from the device itself — a hardware-touching, owner-performed,
  read-only action (see `hardware-recon` / `mcu-safe-backup`), never inferred from the image.
- **Exact wire timing, electrical levels, or pin assignments.** GPIO numbers and baud rates are
  compiled-in integer immediates with no distinctive string; recovering them needs either
  disassembly of the specific init call site or a hardware probe — static analysis alone gets you
  candidates, not confirmation.
- **Whether the device you're holding runs the exact image you analysed.** See §2.2 — always check
  this first, not last.
- **On-screen timing, UI behaviour, or anything about user experience.** Only what the code does,
  not how it feels to use.
- **That an absence of a string proves an absence of the behaviour.** Only that an absence of a
  *linked symbol* or an *exhaustively enumerated call site* does — a plain integer/string compare,
  a manually inlined check, or dead-but-present code can all leave zero distinctive strings behind.

Static analysis tells you what a custom build must reproduce to be accepted by the stock chain, and
what a stock chain will and won't protect you from. It does not, by itself, clear you to write
anything to a device — that gate is a separate, hardware-touching, owner-performed step.
