# PLAYBOOK — the phase-by-phase map for a hardware mod

This is the order a real device-mod project actually ran in, worked back into a repeatable
shape: 22 tracked phases on one worked example (`<REPO>`, publicly `byok-mod`,
github.com/hyderhusainarastu/byok-mod — an ESP32-class main MCU plus a companion MCU, a 1bpp
panel, a stock SD-card updater, and a custom protocol/host app built on top) collapsed here
into 14 phases (0–13) that group cleanly by skill and by gate. Follow it in order the first
time; once you've run it once, you'll know which phases your device lets you skip or reorder
(see "When to stop" at the end).

Every phase names: the **goal**, the **skill** (and, where one exists, the **agents** and the
named **workflow**) that does the work, the **gate** you must satisfy before moving on, and the
**artifacts** the phase leaves behind. The moderator (the top-level session) never does the
substantive work itself — it reads this playbook, dispatches the named skill/agents/workflow
for the phase you're in, reads the result, checks the gate, and only then moves the human and
the next dispatch to the following phase. See `skills/moderator-operating-model/SKILL.md` for
the operating rules this playbook assumes are already in force.

---

## If you only read one thing

1. **Set the rules before you touch the device** (Phase 0) — an evidence standard, a hard
   safety-constraint list, and the human's agreement on what "physical action" means for this
   project. Skipping this is how a rushed session ends up guessing a part number into a
   CONFIRMED fact or driving a GPIO nobody has reasoned about.
2. **The backup-and-recovery gate (Phase 6) is the one gate that is genuinely an AND, not an
   OR.** A backup you haven't test-restored is not a safety net, and a decision to write
   anything to the device before both halves exist is the single mistake this whole toolkit
   exists to prevent. Every other gate in this playbook is important; this one is load-bearing.
3. **Static firmware analysis (Phase 5) is usually the highest yield per unit of physical
   risk** you will spend in the whole project — most of what you need to know about a device
   (its protocol, its acceptance rules, its command set) is sitting in a binary you can read
   with zero risk to the hardware, and it is the phase people skip because it looks like it
   needs a disassembler and weeks of free time. It doesn't; see
   `skills/firmware-image-analysis/SKILL.md`.
4. **Document as you go, not at the end.** Every phase below produces a durable artifact
   (a doc, a decision record, a log entry) *during* the phase, not as a wrap-up step —
   a session that ends abruptly should not cost findings that already happened.
5. **Publication (Phase 13) is not "make the repo public."** It is an audit, then a fresh
   export built from a plan, then an *independent* verification pass by an agent that did not
   build the export, and only then a push. Never skip the independent-verification step because
   the export "looks obviously fine" — see `docs/PITFALLS.md`'s SSID-in-history entry for what
   "looks fine" missed on the worked example.

---

## Phase 0 — Set the rules

**Goal.** Before any device contact, fix the operating rules this entire project runs on: who
does what (moderator delegates, subagents execute), which model tier does which kind of work,
the four-label evidence standard, and the hard safety constraints — before the first photo is
taken or the first cable is plugged in.

**Skill.** `skills/moderator-operating-model/SKILL.md`

**Agents / workflow.** None — this is a template fill-in, not delegated analysis. Copy
`templates/CLAUDE.md` into `<REPO>/CLAUDE.md` and fill in every placeholder you already know
(leave the rest as the placeholder, marked UNKNOWN in your own notes, rather than guessing a
plausible-looking value).

**Gate to leave this phase.**
- [ ] `<REPO>/CLAUDE.md` exists, filled in as far as currently known.
- [ ] The human has explicitly agreed to the physical-action policy: physical actions
  (cables, buttons, probes, solder) are performed by the human, one small experiment at a
  time, with a stop-and-ask before anything irreversible or ambiguous. Get this agreement in
  words before Phase 1, not implicitly.

**Artifacts.** `<REPO>/CLAUDE.md`.

---

## Phase 1 — Preserve evidence

**Goal.** Before analyzing anything, make the analysis process incapable of corrupting the
one thing you can never regenerate: the as-found state of the device, captured in the first
photographs and captures taken of it.

**Skill.** `skills/hardware-recon/SKILL.md` §"immutable original evidence" (also stated in
`skills/moderator-operating-model/SKILL.md`).

**Agents / workflow.** None — this is mechanical: create the directory layout
(`photos/original/`, `photos/analysis/`, `backups/`, `captures/usb|serial|logic/`, per the
layout in `templates/CLAUDE.md`), copy the first photos into `photos/original/` untouched, and
hash them.

```
mkdir -p photos/original photos/analysis backups/original captures/usb captures/serial captures/logic
shasum -a 256 photos/original/*.jpg > photos/analysis/ORIGINALS.sha256
shasum -a 256 -c photos/analysis/ORIGINALS.sha256    # re-run this before ANY session that touches photos/analysis/
```

**Gate to leave this phase.**
- [ ] `photos/analysis/ORIGINALS.sha256` exists and verifies (`shasum -a 256 -c` — every line
  `OK`).
- [ ] The full directory layout from `templates/CLAUDE.md` exists, so a later agent's output
  path can be checked against it mechanically ("does this write land under `original/`?" is a
  bug, not a judgement call, only if the layout already exists to check against).

**Artifacts.** `photos/original/*`, `photos/analysis/ORIGINALS.sha256`, the empty
`backups/`/`captures/` skeleton.

---

## Phase 2 — Photo reconnaissance

**Goal.** Read every component, marking, connector, and pad group off the photographs, with an
evidence grade on every claim, before forming any hypothesis about what the board does.

**Skill.** `skills/hardware-recon/SKILL.md`

**Agents.** Two independent `hardware-recon-analyst` instances per photograph that matters
(run them in `parallel()` so neither sees the other's read), then one or more
`adversarial-verifier` passes over any claim that will gate a later physical action or a
firmware assumption. This is the two-analyst-plus-skeptic pattern the worked example used to
keep a 14-contact connector honestly UNKNOWN for a full round instead of it calcifying into a
false CONFIRMED fact a display driver got built against.

**Gate to leave this phase.**
- [ ] A findings document exists with every claim graded CONFIRMED / STRONGLY INDICATED /
  POSSIBLE / UNKNOWN — see `templates/recon-findings.md`.
- [ ] An explicit **open-questions list**: every UNKNOWN, and for each one, the exact
  photograph or measurement that would resolve it. A photo-recon pass that ends without this
  list is incomplete even if every visible marking got read.

**Artifacts.** `docs/hardware.md` (from `templates/recon-findings.md`), the open-questions
list inside it.

---

## Phase 3 — Passive USB and serial reconnaissance

**Goal.** Observe the device enumerating and capture its boot/console log — without writing a
single byte to it — and settle which USB personalities exist (does it present a mass-storage
mode, a CDC console, a vendor HID interface, more than one depending on how it was powered
on?). Redaction runs from the very first capture, not retrofitted later.

**Skill.** `skills/serial-and-usb-recon/SKILL.md`

**Scripts.** `scripts/usb-watch.sh` (host-only enumeration watcher, never opens the port) and
`scripts/serial-listen.sh` (opens the port strictly read-only, auto-redacts SSIDs/MACs/serial
numbers in its own output pass).

**Agents.** `hardware-recon-analyst` to read the captured boot log/USB descriptors and turn
them into a verdict; escalate anything load-bearing to `adversarial-verifier`.

**Gate to leave this phase.**
- [ ] At least one boot log has been captured **and** the redaction pass has run on it before
  it's referenced anywhere else, let alone committed.
- [ ] A stated verdict on which USB personalities the device presents, and under what
  conditions each one appears (cold boot vs. warm reset vs. a specific button held) — not just
  "it enumerates," but which mode, because the mode is usually the difference between "no
  recovery route exists" and "there's an `esptool`-class window right here."

**Artifacts.** `captures/usb/*` (redacted), `captures/serial/*-boot-log-clean.txt` (redacted),
a verdict written into `docs/hardware.md` or a dedicated `docs/usb-recon.md`.

---

## Phase 4 — Identify the processors and their responsibilities

**Goal.** If the board has more than one MCU, work out which one does what — which owns the
display, which owns USB, which owns any wireless radio, whether they talk to each other and
how — before writing a line of firmware against either.

**Skill.** `skills/hardware-recon/SKILL.md` (silkscreen/pad-group identification) combined
with `skills/firmware-image-analysis/SKILL.md` (confirming responsibilities from the binary
rather than guessing from the silkscreen alone).

**Agents.** `hardware-recon-analyst` for the physical identification, `firmware-analyst` to
cross-check each MCU's role against what its own firmware image actually does (a chip's
silkscreen tells you what it *is*; its firmware tells you what it's *for*).

**Gate to leave this phase.**
- [ ] Each MCU's primary responsibility is stated with a grade, not assumed from a reference
  design that looks similar.
- [ ] If two MCUs communicate, the physical link (UART, I2C, SPI) and, if determinable this
  early, its rough framing are noted — even a POSSIBLE note here saves the Phase 5 static
  analysis from having to rediscover it from scratch.

**Artifacts.** `docs/architecture.md` (MCU responsibility table).

---

## Phase 5 — Static firmware analysis

**Goal.** Extract everything you can from the vendor's own firmware image before risking a
single physical experiment: the display/peripheral command set, the inter-MCU protocol's exact
framing, the updater's acceptance rules, boot-mode gestures, config gates, partition layout.
**This is usually the highest-yield phase per unit of physical risk in the entire project** —
say this out loud to whoever is planning the schedule, because it is the phase most likely to
get rushed past in favor of "just try it on the hardware."

**Skill.** `skills/firmware-image-analysis/SKILL.md`

**Agents.** `firmware-analyst` (dispatch several in `parallel()` across independent
subsystems — display driver, updater, inter-MCU protocol, boot/partition logic — since none of
these needs to see the others' output to do its own job), then `adversarial-verifier` on any
finding that will gate Phase 6 or Phase 8 (a claim about the updater's acceptance rules or the
partition layout is exactly the kind of finding worth refuting before trusting).

**Gate to leave this phase.**
- [ ] The display/peripheral command sequence (or equivalent core interface) is understood well
  enough to replay it — not necessarily every opcode, but every opcode the vendor's own boot
  path actually sends, in order, with the values it sends.
- [ ] The updater's (or equivalent install path's) acceptance rules are derived, not assumed —
  see `skills/stock-updater-packaging/SKILL.md` for what "derived" means here.
- [ ] The partition/flash layout (or equivalent memory map) is decoded from a real image, not
  copied from a vendor default that might not match this device's actual build.

**Artifacts.** `docs/firmware-analysis.md`, an early draft of `docs/protocol-spec.md` (from
`templates/protocol-spec.md`) for any inter-MCU or host-facing framing discovered.

---

## Phase 6 — Backup and recovery

**Goal, and the hardest gate in this playbook.** Get a hash-verified, two-pass-confirmed full
dump of every MCU flash you can reach, a decoded partition map from the device's own memory
(not a vendor default), an identified — and ideally rehearsed — path back to stock, and a
recorded owner decision authorizing what happens next. **This gate is an AND across all four,
not an OR across any of them**, and it does not soften because three of the four are done —
see `docs/PITFALLS.md`'s "treating a backup as a recovery path" entry for exactly how that
mistake happens.

**Skill.** `skills/mcu-safe-backup/SKILL.md`

**Scripts.** `scripts/mcu-backup-window.sh` (`identify` / `partition-table` / `dump`
subcommands, dry-run by default, refuses write/erase/efuse arguments at two independent
layers).

**Agents.** `adversarial-verifier` to check the two-pass hash comparison was actually run
(not merely claimed) and that the decoded partition map was cross-checked against the device's
own read, not a vendor tutorial's numbers.

**Gate to leave this phase.**
- [ ] **A verified backup**: two independent full reads of each reachable MCU's flash, SHA-256
  compared, PASS recorded with the actual hashes in the doc — not "a dump was taken."
- [ ] **A decoded partition/flash map**, read from this device, not assumed.
- [ ] **An identified return-to-stock path**, and if the return path is a single small write
  (e.g. a boot-selector region), **rehearsed** at least once against a spare/scratch target if
  at all possible before it is ever the thing standing between you and a bricked device.
- [ ] **A recorded owner decision** (`templates/decision-record.md`) authorizing the specific
  next write-class action, at this specific moment — a standing policy from weeks ago does not
  authorize today's action; the backup verifies the device, the decision authorizes the act.

**Artifacts.** `backups/original/<mcu>-flash-<date>/` (gitignored — never committed),
`docs/firmware-backup.md`, `docs/recovery.md`, one or more decision records in `docs/decisions.md`.

---

## Phase 7 — Choose the least invasive architecture

**Goal.** Decide, on paper, the smallest change that gets you what you want — usually "run
custom firmware on the most capable/least-irreplaceable MCU, leave everything else at stock" —
and record it as a decision before writing code against it.

**Skill.** `skills/moderator-operating-model/SKILL.md` (decision discipline);
`skills/custom-firmware-bringup/SKILL.md` §1 for the architecture checklist.

**Agents.** One strong design agent to lay out the real options with their real costs, one
`adversarial-verifier` pass to try to find the reason the chosen option is wrong before it's
accepted.

**Gate to leave this phase.**
- [ ] A decision record exists (`templates/decision-record.md`) naming the chosen architecture,
  the options considered (including the ones not picked, with the real argument for them), and
  the concrete consequences — including what capability, if any, is deliberately given up.

**Artifacts.** A decision record in `docs/decisions.md`; `docs/architecture.md` updated to
match.

---

## Phase 8 — First custom build and bring-up

**Goal.** Get a first custom build to boot, drive the display (or equivalent core peripheral)
correctly, and survive a full power-off/power-on cycle — using the bring-up checklist so the
same five well-known first-boot failures don't each cost their own multi-hour debugging
session.

**Skill.** `skills/custom-firmware-bringup/SKILL.md` — read this in full before the first
build, not after the first failure.

**Agents / workflow.** `workflows/implement-review-docs.js` for each build pass (an
implementer, an independent reviewer who did not write the code, a fix stage that applies only
the graded-serious findings, and docs written in parallel with the review, not appended after).
When a symptom doesn't have an obvious cause — garbled output, a shift by some number of rows,
a boot loop that only reproduces under one specific condition —  reach for
`workflows/diagnose-verify-synthesize.js` instead of guessing: independent maps of each side of
the relevant boundary (e.g. firmware vs. protocol), ranked hypotheses, adversarial verification
of the top candidates, then a synthesized fix. This combination is what actually found the root
causes on the worked example — see `docs/PITFALLS.md` for the specific defects it found.

**Gate to leave this phase.**
- [ ] The bring-up checklist in `skills/custom-firmware-bringup/SKILL.md` is satisfied: every
  new config gate defaults off, task stack budgets are checked against actual locals + call
  chain (not eyeballed), the display/peripheral bring-up checklist has been run in order, and
  power-latch/USB-PHY handling has been reasoned through, not just copied.
- [ ] First light is achieved and **confirmed from an actual photograph or capture of the
  device**, not from "the build succeeded and the logs show `ESP_OK`" — a driver that ACKs
  every byte and never actually updates the glass will report success at every layer this side
  of the panel; see `docs/PITFALLS.md`'s first entry.

**Artifacts.** `firmware/<mcu>/` source, the first row of `docs/releases.md`, at least one
incident report (`templates/incident-report.md`) if — realistically, when — something didn't
work the first time.

---

## Phase 9 — Install via the vendor updater, staged

**Goal.** Get your custom build onto the device through the vendor's own update mechanism
(the highest-leverage install path when one exists — no programmer, no chip-erase write, and
it doubles as your recovery mechanism), staged so an unrecoverable member is never included
until it has its own backup and recovery path.

**Skill.** `skills/stock-updater-packaging/SKILL.md`

**Scripts.** `scripts/make-update-tar.sh` (or your device's equivalent packaging step).

**Agents / workflow.** `agents/release-packager.md` for the build-package-hash-record cycle;
`workflows/firmware-release.js` end to end (analyze the observed defect if this is a fix
release, implement, build, package, then the protected-config and byte-identical-member checks
below, then record).

**Gate to leave this phase.**
- [ ] The pre-flight checklist for this install has been run (spare/scratch install medium
  formatted correctly, package staged, SHA-256 of the staged file verified against the
  packaging script's own manifest **before** ejecting/powering on).
- [ ] Any component you do not yet have a verified backup and recovery path for (per Phase 6)
  is **omitted** from the package, not included on the assumption it'll be fine.
- [ ] The install has been staged and the owner has performed the physical install and
  power-cycle personally (Phase 0's policy).

**Artifacts.** The packaged update archive (gitignored if it embeds any vendor-derived bytes),
`docs/install-procedure.md`, an updated row in `docs/releases.md`.

---

## Phase 10 — Host protocol and tools

**Goal.** Build the host-side client for whatever framed protocol your custom firmware now
speaks: frame layout, sequencing, ACK/NACK with informational error codes, resync behavior,
timeouts, and a mock transport so the whole client can be tested without a real port ever
opening.

**Skill.** `skills/framed-serial-protocol/SKILL.md` — read §4/§5 first if you read nothing
else in it: what the receiver does with a byte it can't interpret, and what "informational"
actually has to mean at every layer between the wire and the caller, are the two things a
paper spec gets right and code quietly disagrees with if you don't build them in from the
start.

**Agents / workflow.** `workflows/implement-review-docs.js`, with `ownedPaths` scoped to the
host protocol client and its tests, and `testCommands` including a fuzz/resync test against
the mock transport, not only the happy path.

**Gate to leave this phase.**
- [ ] The frame spec is written (`templates/protocol-spec.md`) and matches the code, checked
  by an independent reviewer, not just by the author re-reading their own diff.
- [ ] A mock/fake transport exists and the test suite runs entirely against it — no test in
  this suite opens a real serial port.
- [ ] Exclusive port ownership is enforced at the OS/library level (not just documented as
  "single-consumer" in prose) if more than one host-side entry point can plausibly open the
  same port.

**Artifacts.** `docs/protocol-spec.md`, the host protocol client and its test suite.

---

## Phase 11 — Companion application

**Goal.** Build whatever host-side application actually uses the protocol — a dashboard, a
mirror, a control panel — with dirty-rectangle-style partial updates if the panel is slow
enough that a full refresh every cycle is visibly laggy, and a config format that doesn't
require a rebuild to change layout.

**Skill.** `skills/device-companion-dashboard/SKILL.md`

**Agents / workflow.** `workflows/implement-review-docs.js`, same shape as Phase 10.

**Gate to leave this phase.**
- [ ] The application runs and is tested against the mock transport (Phase 10) before it is
  ever pointed at the real device.
- [ ] If more than one host-side entry point can talk to the device (a running loop and a
  one-shot command), they share one lock/IPC mechanism rather than racing the port — see
  `docs/PITFALLS.md`'s sequence-gap entry for exactly what happens when they don't.

**Artifacts.** The companion application under `host/`, its config format, its tests.

---

## Phase 12 — Verification against a requirement matrix

**Goal.** Check every top-level requirement against real evidence, using the
TESTED / DEMONSTRATED / PASS-by-path vocabulary honestly — a route that worked once by hand is
not the same claim as a route with automated test coverage, and a verification pass that rounds
both up to the same word is lying to whoever reads it next.

**Skill.** `skills/hardware-in-the-loop-testing/SKILL.md` (the force-mock gate and static
regression guards that make "no automated run touches real hardware" a machine-enforced fact,
not a prose promise) plus the evidence standard in `skills/moderator-operating-model/SKILL.md`.

**Agents.** `adversarial-verifier` to populate or check the matrix — someone who did not build
the feature is the right person to decide whether its evidence actually supports its claimed
grade.

**Gate to leave this phase.**
- [ ] Every row in `templates/verification-matrix.md` has a status, an evidence citation, and
  a grade — no row left blank, and no row rounded up past what its evidence actually shows
  (a PASS-by-path row that still has an untested sub-route says so in the grade column, not
  just in a footnote no one reads).
- [ ] Every PARTIAL row has its specific open item named in the matrix's "Known-risk summary,"
  not left implicit in a wall of table cells.

**Artifacts.** `docs/verification.md` (from `templates/verification-matrix.md`), fully populated.

---

## Phase 13 — Publication

**Goal.** Take the private project to a public, generic-audience repository without leaking a
secret, a personal identifier, a vendor binary, or a narrative of exactly how the project was
run — via a curated export built from a plan, checked by an agent that did not build it, before
anything is pushed.

**Skill.** `skills/publish-hygiene/SKILL.md`

**Agents / workflow.** `agents/hygiene-auditor.md` for the six-category scan;
`workflows/publish-audit.js` to turn the scan into a nine-part publication plan;
`workflows/publish-export.js` to build the actual export tree from that plan (fresh history,
one clean commit, never a rewrite of the private repo's own history); run
`workflows/diagrams-from-docs.js` first, if photographs cannot be published, so the export has
diagrams to cite instead of photos that would otherwise get dropped with nothing replacing
them; a second, independent `hygiene-auditor` pass over the finished export tree before
anything is pushed.

**Gate to leave this phase — and to leave this playbook.**
- [ ] The audit (`workflows/publish-audit.js`) ran over **the full history, not just the
  working tree** — a secret redacted from HEAD is not a secret removed from `git log -p`.
- [ ] The export was built via a fresh, single-point-in-time snapshot with one clean commit —
  never by rewriting or filtering the private repo's own history in place, and never by pushing
  the private repo itself with sensitive commits "cleaned up."
- [ ] Every item in `templates/publication-checklist.md` is checked, including the license
  file and the statement that vendor firmware is not redistributed.
- [ ] An **independent** verification pass — an agent that did not build the export — has run
  the audit categories again against the finished export tree, and found nothing.
- [ ] Only after all of the above: push. Force-push (if a history correction is ever needed
  after the fact) only after every clone-holder has been told.

**Artifacts.** The public export tree, `docs/publication-checklist.md` fully checked, the
publication plan file the export was built from.

---

## When to stop — scoping what ships vs. what stays as reference

Not everything you build has to ship in the final install, and deciding that up front (or as
soon as it becomes clear) is itself a decision worth recording, not an afterthought:

- **A feature that is demonstrated working but not part of the deliverable** (the worked
  example's screen-mirror mode is the concrete case: proven working on real hardware across two
  separate sessions, but the owner decided the shipped product is the dashboard and the
  standalone clock, not a live mirror) should be **parked, not deleted** — the code, its tests,
  and its docs stay in the tree as a working reference implementation, explicitly marked as out
  of the shipped scope in a decision record, rather than either force-fitting it into the
  release or throwing away working, hard-won code.
- **A capability that would require relaxing a safety gate** (e.g. a "restore to a different
  partition over the wire" command that needs a normally-off write gate) is worth building
  behind that gate, off by default, and documenting as deliberately not enabled — not worth
  either shipping enabled or deleting the code path entirely, if the gate itself is sound and
  might be opened deliberately later.
- **A known, cosmetic issue** (a message that doesn't clear on release of some gesture, a field
  that's code-verified but not yet bench-measured against real instruments) belongs in a
  "Known issues" section of the shipped documentation, stated plainly with its actual evidence
  grade — not silently left for someone to discover, and not blocking a release over an issue
  that doesn't affect the core deliverable.
- **The decision of what ships is the human's, recorded, not inferred** — see
  `templates/decision-record.md`. A moderator session should surface the tradeoff clearly
  (what's demonstrated, what's tested, what's still rough) and let the human decide scope,
  rather than deciding on the project's behalf that "since it works, it should ship."
