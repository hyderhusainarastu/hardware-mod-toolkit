# Workflows as manual steps

The six scripts in `workflows/` are Claude Code dynamic workflows: they fan work out to
subagents. Nothing in them is magic. Each one is a fixed sequence of prompts with a gate
between steps, so you can run the same sequence by hand in any assistant (Codex, Cursor,
Gemini CLI, Copilot chat, ChatGPT, a local model) by opening a fresh session per step and
pasting the previous step's output into the next. The arg names below are the ones the script
header documents; read the header of each file for the exact prompt wording.

Rules that hold for every sequence:

- Use a separate session for any step marked "independent". The point of the step is that it
  has not seen the other session's reasoning.
- A "verifier" session must default to "refuted" when it cannot confirm the mechanism itself.
- Never let an assistant open a real USB or serial port during these steps. Use the mock-mode
  switch your project defines, or have the assistant read scripts instead of running them.
- Read the output of every step yourself before starting the next one.

## diagnose-verify-synthesize

Use when a bug only makes sense after reading both sides of a boundary (host and firmware,
sender and receiver).

1. Session A: read only side A's paths. Answer a fixed list of questions about how it behaves
   at the boundary. Cite file and line for every claim. Save as `map-A.md`.
2. Session B (new, independent): the same for side B. Save as `map-B.md`.
3. Session C: give it both maps, the incident description (exact symptom and numbers) and
   every cause you already suspect. Tell it the maps are notes, not ground truth, and to read
   the code. Ask for ranked hypotheses; each must say whether it explains the exact observed
   numbers. Every suspected cause you supplied must be addressed, even if only to dismiss it.
4. For each top hypothesis, run two verifier sessions with different lenses (one: "does the
   code actually do this"; two: "do the numbers and timing work out"). Each answers
   refuted yes or no, and must answer yes if it cannot confirm the mechanism itself.
5. Keep a hypothesis only if at least one verdict is not refuted.
6. Session D: given the survivors, write one diagnosis: most likely root cause with a
   confidence label, the single cheapest check a human can do by hand to tell survivors apart,
   a fix split into host side and device side, a regression test idea, and a "do not do this"
   list.

## implement-review-docs

Use for any code change in a project that talks to hardware.

1. Fix the list of paths this change may touch (`ownedPaths`) and the exact test commands.
2. Implementer session: do the task, touch only those paths, run the tests, report what was
   changed.
3. Reviewer session (new, did not write the code): review the diff. Return findings graded
   critical, major or minor, and a GO or NO-GO verdict.
4. Fixer session: apply only critical and major findings, re-run the tests.
5. In parallel with steps 3 and 4, a docs session writes the documentation for each doc
   target from the implementer's report, so docs describe what was built.
6. Commit with your own message only if the verdict is GO and tests pass.

## firmware-release

Use for each firmware release after the first.

1. Analyse: hash any new evidence file (photo, capture) into your manifest. Measure the
   observed defect from the evidence, grade the cause (CONFIRMED / STRONGLY INDICATED /
   POSSIBLE / UNKNOWN) and state the exact fix.
2. Implement: apply exactly that fix behind a build option, build clean, bump the version, run
   the tests, run the packaging command.
3. Check (independent session), answer GO or NO-GO: does the fix match the defect; are the
   protected config options still at their required values (re-grep the freshly regenerated
   config, do not assume); is the packaged member byte-identical to the build output; does the
   manifest still verify.
4. Record: write the release row, saying "not yet installed" until you have installed it, and
   one research-log entry. Commit only on GO.

## publish-audit

Use before taking a private hardware project public. Read-only: nothing is edited, no git
state changes.

1. Run six scans, each in its own session: secrets and personal data (working tree and full
   history), vendor intellectual property, forbidden process and tooling terms, oversized or
   EXIF-bearing media, portability from a fresh clone, and anything else your goal lists.
   Each returns findings as file, kind, detail, action, severity.
2. Verify (independent sessions): check the scans for completeness and check the legal
   questions (vendor firmware, trademarks, anti-circumvention rules in your jurisdiction).
3. Synthesize: merge findings into a publication plan with a drop list, redaction rules, a
   grep checklist and a document table of contents. Save it as `publication-plan.md`.

## publish-export

Use after `publish-audit`. It writes only to the export directory and makes one local commit.
It never adds a remote and never pushes.

1. Base: create the export directory from `git archive HEAD | tar -x` so history, backups and
   ignored files cannot come along.
2. Docs: split the public documents into groups that own disjoint files. One session per
   group rewrites its files following the plan's drop list and redaction rules, with evidence
   grades kept on every hardware claim and nothing invented.
3. Integrate: one session reconciles links, names and the README across groups.
4. Verify (independent session): run the plan's grep checklist and a fresh-clone build or test
   in mock mode. Fix findings, re-verify, and stop after a fixed number of rounds.
5. Commit once, with a plain message and no trailers.

## diagrams-from-docs

Use when photos of your unit cannot be published and diagrams must replace them.

1. Plan: one session reads your docs and proposes 8 to 12 diagrams, including any you require.
   Mark each as Mermaid (flowcharts, sequences, state machines) or hand-written SVG
   (board-level block diagrams, pinouts).
2. Draw: for each diagram, a session re-reads the source lines and draws it, keeping each
   fact's confidence label.
3. Check: a second session fact-checks the diagram against the same source lines and checks
   the Mermaid or SVG syntax. Redraw until it passes. Diagrams are independent, so work them
   one at a time or in parallel.
