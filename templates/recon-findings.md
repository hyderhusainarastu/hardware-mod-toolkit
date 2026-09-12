<!--
HOW TO USE THIS TEMPLATE
1. This is the per-subsystem findings document (one file, or one section per subsystem in a
   larger docs/hardware.md — either works; the source project used sections). It exists to
   force every claim to name its evidence, not to be prose.
2. Run recon with MULTIPLE independent analyst passes over the same evidence (e.g. two
   subagents independently reading the same photo/capture) whenever a claim is going to gate
   a physical action later (pinout, voltage rail, connector pin count). Disagreement between
   passes is signal, not noise — record it in §"Analyst disagreements", don't silently pick
   one and discard the other.
3. Every row in the findings table must cite a specific evidence file (a photo filename, a
   capture path, a log excerpt) — "visual inspection" is not evidence, "IMG_1234.jpg crop at
   ~40px/mm" is.
4. Use the CONFIRMED/STRONGLY INDICATED/POSSIBLE/UNKNOWN standard throughout (see CLAUDE.md
   template §3). An UNKNOWN row is a successful outcome of this document, not a gap to feel
   bad about — a wrong guess costs a board, an honest UNKNOWN costs a photo.
5. Close with "Open questions" naming the EXACT next photo/measurement/capture that would
   resolve each remaining UNKNOWN — not "more investigation needed".
-->

# <SUBSYSTEM> findings — <DEVICE>

## Findings table

| Claim | Evidence | Grade | Source |
|---|---|---|---|
| <e.g. "U3 is a <PART>"> | <what was read/measured/observed> | CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN | <photo/capture/log filename or path, with a crop region or offset if relevant> |
| | | | |
| | | | |

<!-- Add one row per distinct, checkable claim. Split a compound claim ("X is a <PART> with
     <VALUE> rating") into two rows if the two halves have different evidence grades — this
     is exactly the CLAUDE.md §3 "interpretation is separated from observation" rule: a part
     marking being legible does not make a datasheet-derived rating CONFIRMED. -->

## Analyst disagreements and how they were resolved

<!-- Delete this section only if recon genuinely used a single pass with no re-check. For
     anything gating a physical action, prefer at least one independent re-check pass. -->

| # | Dispute | Positions | Resolution | Method |
|---|---|---|---|---|
| 1 | <what was disputed, in one phrase> | <position A> vs <position B> | <RESOLVED: <verdict> / UNRESOLVED, recorded as UNKNOWN — state which> | <the specific measurement/crop/reference that settled it, or why it couldn't be settled> |

<!-- Worked pattern for writing a resolution, based on a real adjudication: measure the
     disputed feature against TWO independent scale references already visible in the same
     frame (e.g. a known component's body dimension, a known pitch elsewhere on the board);
     if both references agree, that's a strong resolution. If a re-examined "highest
     magnification" source turns out not to be the highest-magnification view after all
     (measure image pixel spans, don't trust captions), say so explicitly and withdraw the
     prior reading rather than let it keep being cited. -->

### <#>.1 <name the disputed claim> — re-adjudicated <DATE> (was <prior grade>, now <grade>)

<Full reasoning for a specific, consequential dispute that deserves more than one table row —
what the competing readings were, what measurement or reference resolved it, and what
downstream claim depends on the answer (e.g. "connector pin count constrains which display
interface family is possible").>

**Conclusion:** <the final grade and claim, plus what would be needed to move it to
CONFIRMED if it isn't already>.

## Open questions / what resolves each

| Question | What would resolve it |
|---|---|
| <UNKNOWN claim> | <the exact photo angle / measurement / capture / test that would settle it — specific enough that someone else could go take it> |
| | |
