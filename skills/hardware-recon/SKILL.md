---
name: hardware-recon
description: Identify a PCB from photographs -- preserve originals with a hash manifest, read module and silkscreen markings without guessing, inventory components and connectors, and grade every claim CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN. Use when starting hardware reverse engineering from photos of a board, or when a hardware claim needs its evidence checked.
---

# Hardware recon

Photo recon is where hallucinated part numbers enter a project and never leave. Everything
downstream -- the pinout guess, the firmware you write against it, the cable you buy -- inherits
whatever confidence level a photo-reading session assigned on day one. A real run against one
device used two independent analysts per image, three adversarial skeptics with distinct lenses
re-checking the result, and a standing list of "the exact photograph that would resolve this."
That discipline is what kept a 14-contact FPC connector honestly UNKNOWN for a full round instead
of calcifying into a false CONFIRMED fact that a display driver would later have been built
against -- and it is what let a later round correctly *reverse* four separate findings (a missing
switch that turned out to exist, an inductor value, a component's IC-vs-RTC identity, a connector's
true hole count) without anyone having to pretend the earlier reads were never made.

## 1. Preserve first

Before any analysis touches the photographs, establish a tamper baseline.

```bash
# Hash every original (use absolute paths so -c works from any working directory)
shasum -a 256 <PROJECT>/photos/original/*.{jpg,jpeg,png,dng} \
  > <PROJECT>/photos/analysis/ORIGINALS.sha256

# Confirm each file is a readable image and note its native pixel dimensions
file <PROJECT>/photos/original/<file>
sips -g pixelWidth -g pixelHeight <PROJECT>/photos/original/<file>
```

Hard rules, no exceptions:

- **`photos/original/` is never edited, moved, renamed, recompressed, or deleted**, and it is
  never passed as the output target of any command. Every crop, resize, or contrast tweak is a
  *new* file written to `photos/analysis/`.
- **Re-verify before relying on the originals in any later session:**
  `shasum -a 256 -c <PROJECT>/photos/analysis/ORIGINALS.sha256` -- all lines must read `OK`. If
  anything differs, stop and say so; do not analyze a file that failed verification.
- Derived crops are named `<source-stem>-a<analyst#>-<region>.png` so the source photo and the
  analyst who made the crop are recoverable from the filename alone.

Exact crop command (macOS `sips`; check `sips --help` for exact flag names on other versions
before assuming this is portable):

```bash
sips -s format png \
     --cropToHeightWidth <H> <W> --cropOffset <Y> <X> \
     <PROJECT>/photos/original/<file> \
     --out <PROJECT>/photos/analysis/<source-stem>-a<N>-<region>.png
```

**Never omit `--out`.** `sips` without an explicit output file rewrites the input in place --
against a file under `photos/original/` that is exactly the mistake this whole section exists to
prevent. If `sips`'s crop flags misbehave, fall back to `python3` with `PIL`/`Pillow` *only if it
is already installed* -- do not install anything to get a crop; that is not worth risking on an
irreplaceable device's recon session.

## 2. The reading rules

- **Transcribe markings verbatim**, including line breaks, exactly as printed. Render an
  unreadable character as `?` rather than the character it "probably" is.
- **Never complete a partial part number from memory or from a family convention.** If a can
  reads a variant-code suffix that the module family's naming convention would decode into a
  specific flash/RAM size, write down *both*, separately, with separate confidence: the read
  string is one claim (`CONFIRMED`, you can see it), the decoded meaning is a different, weaker
  claim (`STRONGLY INDICATED` at best -- it's an inference from a naming convention, not a line
  printed on the part). Never merge the two into a single higher grade.
- **A regulatory ID or date code is evidence, not decoration.** An FCC ID, an IC id, a CMIIT ID,
  or a TELEC/giteki string that is legible is one of the strongest things a photo can give you --
  cross-checking it independently confirms a module's identity far better than the marketing part
  number alone. A guess at one is worse than useless: it is a fabricated regulatory record.
- **If it is not legible, it is UNKNOWN.** Full stop. Distinguish explicitly between "I can see a
  marking is present" and "I can read what it says" -- these are different findings and only the
  second one licenses a designator, a part number, or a pin count.

## 3. The pass structure

Per photo, work outward to inward: **overview → quadrant crops → per-component crops.** Note the
view (which side of the board, which region, camera angle, lighting quality) before reading
anything, because an oblique or defocused frame changes how much weight its readings should carry
later.

**Run at least two independent analysts per photo**, and give them different emphases so they
are not just duplicating each other:

- Analyst A: **component identification** -- modules, ICs, reference designators, legible
  silkscreen labels, test-point labels.
- Analyst B: **connectivity and topology** -- visible traces, which pads/labels sit adjacent to
  which module, connector pin counts, pad-group physical layout and orientation exactly as
  photographed, FPC/flex routing, power/battery/USB/storage routing.

Do not let one analyst see the other's output before reporting, and do not average their
readings. **Record disagreements as disagreements** -- a table of positions, which one won, and
by what method -- not as a single silently-merged answer. Disagreement is signal: on a real
project, an early smoothing-over of two very different contact counts for the same connector (14
vs. ~25) sat unresolved for a full round specifically *because* nobody was allowed to just pick
one, and that discipline is what let it get re-examined correctly instead of shipping a coin-flip
guess as fact.

## 4. What to inventory

For every photo, walk this checklist rather than free-associating:

- **Actives** -- ICs, transistors, diodes: designator, marking (verbatim or `UNKNOWN`), package,
  likely function, confidence, evidence (which photo/crop).
- **Passives worth noting** -- not every 0402, but anything load-bearing: inductor value markings
  near a power stage, a resistor network sitting on a bus, a matched pair beside a connector.
- **Switches**, and their silkscreen label if any -- do not assume a switch's function from its
  position; record only what is printed.
- **Connectors and pad groups** -- pitch, contact count, physical layout **exactly as
  photographed** (do not normalize orientation; a future pinout diagram needs to reproduce the
  photographed layout, not a tidied-up version of it), and what the silkscreen label implies about
  function versus what it actually states.
- **Test points** -- every one, with its exact position and nearest landmarks.
- **Antennas and RF** -- integrated module antennas, any external antenna structure, keep-out
  regions, connectors (u.FL/IPEX/SMA) or the confirmed absence of one.
- **Power, battery, and charging block** -- battery label and connector, charge/power path
  components, any test points that ring the same net.
- **Mounting/tooling holes.**
- **"Not a connector" false positives** -- explicitly record anything that *looks* like a
  connector or edge-finger array at low magnification but isn't. A real board carried a row of
  silkscreen bars along one edge that read as a possible gold-finger edge connector until a
  magnified crop showed no mask openings and no exposed metal at all -- it was decorative
  artwork. Write the negative finding down so a later, less careful pass doesn't reintroduce it.

## 5. Adjudication

When two analysts disagree on the same feature:

1. **Re-crop at higher native magnification -- and check that it actually is higher native
   magnification before trusting it.** "Closer-looking" and "higher resolution" are not the same
   thing. Compute native scale (pixels per millimetre) from two independent internal references
   visible in the same frame (a known connector body dimension, a known module's castellation
   pitch) rather than eyeballing which crop looks more zoomed in. A whole-device shot where the
   board fills only part of the frame can have *lower* native resolution on a given connector than
   a well-framed macro of just that region, even though the whole-device shot "feels" like the
   close-up because it was the photo used to justify a claim. Getting this backwards is exactly
   how a wrong contact count nearly became the operative fact on a real board: the photo everyone
   called "the closest, highest-magnification view" was later measured to be the *lowest*-native-
   resolution view of that connector in the whole set.
2. **Look for a corroborating mark elsewhere on the board** -- a second module printing the same
   family's naming convention, a second photo of the same region at a different angle, a landmark
   that only makes sense under one of the two readings.
3. **If still contested, record both readings with their grades and move the question to the open
   list** rather than resolving it by vote or by seniority. A dispute you cannot honestly settle
   from the photos in hand is itself a finding.

## 6. Open questions discipline

Every `UNKNOWN` gets a line stating **exactly** which photograph, measurement, or firmware/boot
string would resolve it -- not "more photos," but the region, angle, lighting, and magnification
needed, or the specific electrical read that would settle it if photography has been exhausted.

Lighting rules that make the difference between a resolvable and an unresolvable shot:

- **Laser-etched marks on black packages are invisible under flat/overhead light.** They only
  appear under **raking light** -- a light source held nearly parallel to the surface. Take two
  exposures per part, lit from opposite directions, so a genuine glyph (visible from both sides)
  can be told apart from a lighting artifact (visible from only one).
- **Glossy module labels and white plastic need the opposite** -- diffuse light (bounce it off a
  white card) and slight under-exposure, or the label blows out to unreadable white.
- **Camera perpendicular, not oblique, for anything being counted or measured.** An oblique
  macro can look more detailed while actually foreshortening the exact dimension you need.
- **Rotate the board so the silkscreen reads upright in the viewfinder**, rather than rotating the
  image afterward -- this keeps "as photographed" orientation trustworthy for later pad-layout
  and pinout work.
- **Put a steel rule or calipers in the same focal plane** in at least one shot per side. Every
  measurement derived from an internal reference (a module's castellation pitch, a connector's
  known body size) instead of a ruler carries a real error band -- state it (a real project
  carried a consistent ±10% until a ruler shot was finally taken) and close it when you can.

## 7. Output

Write findings into `${CLAUDE_PLUGIN_ROOT}/templates/recon-findings.md` (plugin install) or
`templates/recon-findings.md` (repo checkout) -- do not duplicate that template's structure here;
this skill only tells you how to fill it in.

## References

- `references/photo-shot-list.md` -- the shots a board actually needs, with the lighting and angle
  that makes each one legible.
- `references/grading-examples.md` -- six worked examples of a claim moving between confidence
  grades, including one outright refutation, distilled from a real recon session.
- `agents/hardware-recon-analyst.md` -- the subagent role this skill's two-analysts-per-photo pass
  dispatches.
- `workflows/diagnose-verify-synthesize.js` -- the Preserve → Scout → Synthesize → Verify pipeline
  that runs this skill's process end to end with parallel analysts and adversarial skeptics.
