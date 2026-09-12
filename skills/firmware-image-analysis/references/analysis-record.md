# Structure of a firmware-analysis document

This is the skeleton a firmware/updater static-analysis write-up should follow. It comes from a
real multi-pass analysis that went through several rounds of correction, and the section order is
chosen so that a reader gets the headline first and the reproduction detail last — not the reverse.

Use `templates/recon-findings.md` for the lighter-weight per-session recon note; use this skeleton
when the deliverable is a standing reference document that later work (design, implementation,
review) will cite by section number, the way a project's own firmware-analysis and
updater-analysis documents get cited throughout its other docs.

```
# Firmware Analysis -- <PROJECT> vendor archive <ARCHIVE_NAME> (<VERSION>)

**Status:** complete for static, host-only analysis. **No hardware was touched.**
**Evidence labels:** CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN.

> ### The single most important caveat in this document
> A string in an image proves that code exists in that image. It does not prove the code runs,
> that the peripheral is fitted, or how it is wired. [... state the promotion-needs-an-extra-leg
> rule from SKILL.md #0 here, every time, even though it feels repetitive -- it is the rule most
> often silently violated under deadline pressure.]

---

## 0. Headline corrections (only present once there's something to correct)

If a later pass finds the device runs a different version than assumed, or reverses an earlier
conclusion, put that here, at the top, in bold, before anything else -- not buried at the point in
the document where the original wrong claim lived. State plainly what was wrong, what corrected it,
and which downstream sections are now stale because of it. A reader who stops after section 0
should still leave with the current truth.

## 1. Provenance

Table: file / origin / size / SHA-256 / vendor version / retrieved date / stored path /
"committed to git? NO". Corroboration of provenance (an independent second download, a public
release API, a byte-for-byte comparison) if you have it. Packaging-environment metadata from
container headers (build-tool fingerprints, timestamps, timezone) is informational only -- it can
be a nice corroborating detail but is never load-bearing on its own.

## 2. Contents and headers

- Archive member table: file / size / type / target chip / toolchain version / app version+date /
  signed? / encrypted?.
- Per-image header table: entry point, segment count, flash size/freq/mode as declared (with the
  caveat that these are build configuration, not a measurement of the fitted part, when the image
  in hand isn't a full-flash dump including the bootloader that actually owns those SPI settings).
- Segment map: load address / length / file offset / memory region, for each image.
- The signed/encrypted/anti-rollback determination (SKILL.md #2.1), stated plainly with the byte
  arithmetic that backs each "zero trailing bytes" or "secure_version = 0" claim.
- Container-specific contents (e.g. an assets/resource tar): member list, sizes, and -- if the
  container's declared size doesn't match content length -- the padding explanation (a fixed
  blocking factor is common and is not a hidden-size hint).

## 3. Partition layout

The carve table (SKILL.md #3): partition / evidence it exists (or that the image merely *expects*
it to exist elsewhere) / offset / size. State explicitly, in a callout, whether this archive is a
full-flash bundle or an application-slot payload -- and if the latter, that it is not a recovery
image for a damaged boot chain. List the recovery-map items that remain UNKNOWN and exactly what
device-touching read would resolve each (framed as a recommendation for the owner, not performed
here).

## 4. Per-subsystem findings

Open with the subsystem responsibility matrix (SKILL.md #4) as the headline table if there is more
than one image/chip. Then one subsection per subsystem, each as a claim/grade/evidence table:
column 1 the claim, column 2 the grade, column 3 the exact string, offset, or call-site evidence.
Put the boot-mode / special-gesture inventory in its own subsection -- it tends to be the part a mod
project references most often, and it deserves a single consolidated table rather than being spread
across the individual button/mode write-ups that led to it.

## 5. Security posture

One table: property (hardcoded credentials, embedded keys, API tokens, cloud endpoint, TLS/pinning,
secure boot, flash encryption, anti-rollback, OTA image validation, remote debug surfaces) / finding
/ grade. State up front, in bold: **names only -- no credential value, key, token, SSID, or password
is reproduced anywhere in this document.** This is a hard rule, not a style choice; a security
write-up that quotes the secret it found is itself a leak.

## 6. Implications for the mod

This is where the document earns its keep -- translate #2-5 into decisions:

- Which chip/subsystem must actually change for the planned mod, and which can be left untouched
  (a mutually-exclusive subsystem split, per SKILL.md #4, is the strongest evidence for this).
- Whether the stock update path can serve as a recovery path, and for what (application layer only,
  usually -- never bootloader/partition-table/otadata unless you've confirmed otherwise).
- Whether the stock updater's acceptance checks are weak enough to load a custom image, split
  explicitly into "mechanically plausible" vs. "the eFuse-level gate is still unread and unknown" --
  never conflate the two.
- The still-open hardware measurements that gate action, as a table: # / measurement / why it
  gates everything / cost -- and mark plainly that none of them may be performed by an assistant.

## 7. Open questions

Numbered list, oldest-first, struck through and annotated "RESOLVED" as they close rather than
deleted -- the resolution history is part of the record. Each item states what specifically would
resolve it (a disassembly pass, a device read, a photograph) so a reader can pick up any single
item without re-deriving context.

## Appendix -- provenance of every tool invocation

A flat list of every command class that was actually run to produce this document (see
`references/tool-invocations.md`), with an explicit statement that every command was run on host
files only -- no `--port`, no serial device opened, no flash write. This appendix is what makes the
whole document falsifiable: anyone with the same archive should be able to reproduce every table in
it.
```

## Notes on tone and discipline, carried over from a real multi-round analysis

- **Write corrections in place, not as silent edits.** A superseded claim stays visible, marked
  superseded, with the date and what corrected it. The document's own history of being wrong and
  then fixed is evidence that the method is being applied honestly, not just asserted.
- **Split a single overstated grade into two claims when a correction demands it.** "X is
  CONFIRMED" sometimes turns out to bundle "the image requires X" (which is CONFIRMED) with "X
  exists on this specific board" (which is UNKNOWN pending a device read). When you catch this,
  don't just downgrade the one line -- retitle the section if its own heading asserted the stronger
  claim.
- **A retitled section heading is itself worth a footnote** explaining what the old heading claimed
  and why it no longer holds; a reader skimming headings should not be misled by one that used to
  be true.
