<!--
HOW TO USE THIS TEMPLATE
1. docs/research-log.md is APPEND-ONLY. Never edit or delete a past entry — if a past
   conclusion turns out wrong, add a new entry that says so and points back at the old one
   by date/phase. The log is the audit trail; rewriting it destroys that.
2. One entry per distinct research action (a command run, an analysis pass, an owner-observed
   test). Append it to the end of docs/research-log.md immediately after the action, not at
   the end of a session — an entry written from memory an hour later loses precision.
3. Copy the block below, fill in every field, and paste it under a "## <DATE> <TIME>, PHASE
   <N> — <short title>" heading. Keep COMMAND verbatim (copy-pasteable), not paraphrased.
4. INTERPRETATION and CONFIDENCE are not the same field: INTERPRETATION is what you think it
   means; CONFIDENCE is how sure you are, using the evidence-standard labels (see
   recon-findings.md) or your own PASS/FAIL/PARTIAL vocabulary for a test action.
-->

## <DATE> <TIME>, PHASE <N> — <short title>

DATE/TIME: <DATE> <TIME> <TZ>
PHASE: <N> — <short title>

**ACTION:** <What you did, in one to three sentences — read-only recon, a specific command,
an owner-performed physical test, an analysis pass over existing captures. Say explicitly
whether the device was touched, and if so, how (read-only vs. state-changing).>

**COMMAND:**
```
<the exact command(s) run, verbatim, one per line — this block should be copy-pasteable by
someone re-running the same check later>
```

**RESULT:**
- <objective, verifiable observation #1 — quote actual output/values, not summaries>
- <objective, verifiable observation #2>
- <what did NOT happen, if that absence is itself informative — e.g. "no new USB device
  enumerated", "0 I2C errors logged">

**INTERPRETATION:** <What this result means for the hypothesis in play. Separate observation
from inference explicitly — e.g. "X is CONFIRMED (directly read); Y is STRONGLY INDICATED (a
decode of X, not independently observed)". If two readings conflict, say so here rather than
silently picking one.>

**CONFIDENCE:** <CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN — or PASS/FAIL/PARTIAL
for a test action. Justify briefly if not obvious from RESULT.>

**NEXT STEP:** <The next concrete action this result points to. If none, say "none — closed"
or name what would need to change to reopen this line of investigation.>

---

<!-- Filled example, for reference — delete once you've made your first real entry. -->

## 2026-01-14 03:19–03:21, PHASE 2 — after-normal-connect USB capture

DATE/TIME: 2026-01-14 03:19–03:21 EST
PHASE: 2 — after-normal-connect USB capture

**ACTION:** Read-only host-side USB re-check after connecting <DEVICE> by USB-C in its
normal running mode. Captured the same command set as the Phase 1 "before" baseline, then
diffed against the prior capture. No serial port opened, no flashing tool run.

**COMMAND:**
```
ioreg -r -c IOUSBHostDevice -l -w 0    > after-connect-ioreg-usbhostdevice.txt
ls -la /dev/cu.* /dev/tty.*            > after-connect-dev-nodes.txt
ioreg -p IOUSB -l -w 0 | grep -iE 'idVendor|idProduct' > after-connect-vid-pid.txt
```

**RESULT:**
- `IOUSBHostDevice`: exactly the same devices as the before capture; diff against the prior
  dump is empty.
- `/dev/cu.*` / `/dev/tty.*`: no new CDC-ACM-style serial node appeared.
- No enumeration attempt, no error, in the capture window.

**INTERPRETATION:** The device did not present a new USB interface in its normal running
mode over this window. CONFIRMED that no CDC endpoint appeared; UNKNOWN whether one appears
under a different trigger (e.g. a specific button combo) not yet tried.

**CONFIDENCE:** CONFIRMED (direct capture diff, reproducible).

**NEXT STEP:** Try the same capture immediately after a cold boot, in case the interface is
only exposed for a fixed window after power-on.
