<!--
HOW TO USE THIS TEMPLATE
1. One row per top-level requirement, lettered or numbered (A, B, C... or REQ-01, REQ-02...)
   so other docs (research log, decision records, incident reports) can cite a requirement
   by ID without restating it.
2. Update a row's status the moment evidence changes — this document is a live index into
   the evidence, not a report written once at the end. Cite the actual file/log/entry that
   supports the new status, every time.
3. Use the legend below verbatim; do not invent new status words per-row. The distinction in
   the legend between "by-path", "demonstrated" and "tested" is real and matters: it is the
   difference between "a route exists and was rehearsed once" (by-path), "it worked live but
   coverage is narrow" (demonstrated), and "it has automated or repeatable test coverage"
   (tested) — a requirement can be CONFIRMED by one route and still be worth flagging with
   which route, because a reader deciding whether to trust it needs to know which.
4. If a phase in your project reuses the same requirement letters/numbers for a DIFFERENT set
   of requirements (e.g. an early-phase "A-J" and a later on-device "A-J" that don't line up),
   give the second set its own sub-table with a note explaining the collision — do not let a
   later document silently overwrite an earlier, unrelated row under the same letter.
-->

# Verification matrix — <PROJECT>

Status: <PHASE/MILESTONE NAME> · <DATE>

This document tracks requirements <A–?> through development phases. Full test procedures and
acceptance criteria live in `test-plan.md` (if you maintain one) or in the referenced evidence
files directly.

**Legend:**
- **Status:** PENDING VERIFICATION / SPECIFIED / IN PROGRESS / PARTIAL / PASS / CONFIRMED
- **Grade:** CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN / DRAFT (untested procedure)
  / PASS-by-path (a route was rehearsed once, end-to-end, but not stress-tested) /
  DEMONSTRATED (worked live at least once, coverage still narrow) / TESTED (automated or
  repeatable test coverage exists, not just a one-off demonstration)

## Requirement table

| ID | Requirement | Status | Evidence location | Grade |
|---|---|---|---|---|
| **A** | <e.g. "Original device function fully preserved after modification"> | <status> | <file/log/entry citation — be specific: a filename, a research-log timestamp, a test-plan ID> | <grade> |
| **B** | <e.g. "Verified backup exists before any write"> | | | |
| **C** | <e.g. "Tested recovery/rollback path restores device to stock"> | | | |
| **D** | <e.g. "No secure-boot or efuse changes made"> | | | |
| **E** | <e.g. "USB enumeration matches stock behavior post-modification"> | | | |
| **F** | <e.g. "Companion protocol implemented and functional"> | | | |
| **G** | <e.g. "Host application connects and renders correctly"> | | | |
| **H** | <...> | | | |
| **I** | <e.g. "No secrets/credentials/dumps present in git history"> | | | |
| **J** | <e.g. "Documentation complete and matches actual implementation"> | | | |

<!-- If a requirement is PASS "by path" but one sub-route remains untested, say so in the
     Grade column rather than rounding up to a clean CONFIRMED — e.g. "PASS-by-path (route 1
     CONFIRMED; route 2 still DRAFT/untested)". A later reader deciding whether to rely on
     this needs the qualifier, not just the headline word. -->

## Known-risk summary

<!-- For any row graded PARTIAL, list the specific open items here so they don't get lost in
     a wall of table cells. -->

- **<risk/gate name>**: <its current state, e.g. "gate OFF by default; cannot be armed
  without an explicit rebuild">.
- **<open question>**: <what's still unresolved and what would resolve it>.

## Next steps

- [ ] <the next concrete test/milestone that would move a specific row forward, naming the
      row ID it affects>
- [ ] <...>

## Document revision history

<!-- Append-only, like the research log. Each entry names which row(s) changed, the new
     grade, and the evidence that justified the change. Never edit a past entry — if a past
     entry mislabeled which requirement ID it was updating, add a new entry correcting the
     record rather than silently fixing the old one. -->

| Date | What changed | Details |
|---|---|---|
| <DATE> | <e.g. "Row F upgraded PARTIAL -> PASS"> | <what evidence justified it, with citations> |
