<!--
HOW TO USE THIS TEMPLATE
1. One record per decision, appended to docs/decisions.md (or one file per record under
   docs/decisions/D-<NNN>.md if you prefer — pick one convention and state it at the top of
   that file). Number sequentially: D-001, D-002, ...
2. Records are IMMUTABLE once Accepted. A decision that changes gets a NEW record
   (D-0NN+1) with status "Supersedes D-0NN" — never go back and edit an old one, except to
   append a dated "Status update" section under the ORIGINAL decision when new evidence
   changes facts without changing the decision itself (see the worked example below for the
   shape of that kind of update).
3. Write the "Options considered" section honestly — including the option you didn't pick,
   with the real argument for it. A decision record that only argues for the chosen option
   is not a decision record, it's a justification, and it won't survive being re-litigated
   months later when someone asks "did we consider X?".
4. "Gates" is for decisions that unlock a later, more dangerous action (e.g. a decision to
   attempt a device write is gated on a verified backup existing). If a decision has no such
   gate, delete that section.
-->

## D-<NNN> — <short title>

**Status:** <Proposed / Accepted / Provisional (accepted, expected to be revisited) /
Superseded by D-<NNN>> · <DATE>

**Context.** <What situation forced this decision — the constraint, the risk, the competing
requirements. Be concrete: what would go wrong if no decision were made here at all?>

**Options considered.**

1. **<option A>** — <the real argument for it, including who would have favored it and why>
2. **<option B>** — <the real argument for it>
3. **<option C, the one chosen>** — <the real argument for it>

**Decision.** <State the decision plainly, in a form that can be checked later — a concrete
rule, a concrete layout, a concrete gate condition. If it implies a directory layout, config
value, or code convention, spell it out here so it's copy-pasteable.>

**Rationale.** <Why this option over the others — refer back to the specific arguments in
"Options considered" rather than restating generic pros.>

**Consequences.** <What this costs — slower iteration, more verbose docs, an extra manual
step, a capability given up. State the cost honestly; a decision record that only lists
benefits is not trustworthy the second time someone reads it.>

<!-- Delete this section if the decision does not gate anything later. -->
**Gates.** This decision must be satisfied before <the gated action> may proceed:
- [ ] <condition 1, checkable/verifiable, not aspirational>
- [ ] <condition 2>

---

<!-- Worked example of a later status update to an ACCEPTED, un-superseded record — this
     shape (new facts appended under the original record, decision left untouched) is how
     you record new evidence without pretending the original decision never happened. -->

### Status update — <DATE>: <what changed factually>

| Condition | Status |
|---|---|
| **(a) <gate condition 1>** | <MET/UNMET and why, with a pointer to the evidence file> |
| **(b) <gate condition 2>** | <MET/UNMET and why> |

**Decision unchanged: <restate the still-binding constraint>.** <What the new evidence
changes and what it doesn't — be explicit that partial progress on a gate does not relax the
original decision unless and until every gate condition is met.>
