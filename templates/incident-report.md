<!--
HOW TO USE THIS TEMPLATE
1. One file per incident: docs/incident-<DATE>-<short-slug>.md. Title line names the
   symptom in one line, not the eventual root cause (you don't know it yet when you open
   the file).
2. Write §0 (The report) FIRST, verbatim from what was observed, before you've read a line
   of code. This anchors the investigation to what actually happened, not to what you expect
   to find. Everything after §0 is your investigation.
3. §1 must name every file/function you actually read and what candidates you ruled out and
   why — "I looked and it's fine" is not a finding; "function X cannot run before Y because
   Z is the last call before the task starts" is.
4. Grade the root cause (§2) with the same CONFIRMED/STRONGLY INDICATED/POSSIBLE/UNKNOWN
   standard as everywhere else in this toolkit — see recon-findings.md. Say explicitly what
   would upgrade a STRONGLY INDICATED cause to CONFIRMED (usually: a specific device test).
5. §4 (fix) should be a diff sketch, not applied code, unless your process allows the
   assistant to edit firmware/host code directly — many hardware-mod projects require the
   owner to apply and test physical-adjacent changes personally.
6. §6 states the boundary of what this document does NOT establish — resist the pull to
   overclaim once you have a plausible story that "feels" complete.
-->

# Incident <DATE>: <one-line symptom, not the cause>

<One or two sentences of scope: what was investigated (host-only? on-device?), what commit/
firmware version this is against, and whether anything concurrent (another workflow's
in-flight changes) is relevant and how it was handled — credited, not duplicated.>

## 0. The report

<Owner-observed sequence, as close to verbatim as possible. Bullet the discrete observations
in the order they were reported, including timing/duration where it matters. Include any
log/serial output already captured at report time, quoted exactly.>

- <observation 1>
- <observation 2>
- <observation 3>

## 1. What the code actually does (files read, candidates ruled in/out)

**Read:** <list every file/function actually opened for this investigation — this list is
itself evidence that the ruling-out below is not guesswork.>

<Narrate the relevant code path/sequence as it actually is (boot order, call sequence, state
machine), citing file:line or function names, not paraphrased from memory.>

**Candidate: <hypothesis 1> — RULED OUT/RULED IN.** <The specific code evidence that settles
it — a call order, an absence of a code path, a byte-level check. State the ruling mechanism,
not just the verdict.>

**Candidate: <hypothesis 2> — RULED OUT/RULED IN.** <...>

<Repeat for every candidate seriously considered before landing on §2.>

## 2. Root cause: <name it> (<GRADE>)

<The mechanism, explained precisely enough that someone unfamiliar with the code could
verify it by reading the same lines. Quote the actual code (or the actual diff, if a fix is
already in flight elsewhere and being credited rather than duplicated).>

**Grade: <CONFIRMED / STRONGLY INDICATED / POSSIBLE>.** <Justify: what makes this not fully
CONFIRMED, if it isn't — usually "not reproduced on real hardware this pass" or "explains
most but not all of the reported symptoms, see residual below".>

## 3. Contributing factors

<Anything that made the root cause worse, harder to see, or harder to diagnose, but isn't
itself the cause — e.g. a logging gap that hid the failure, a default config flag that was
never verified on real hardware, a shared resource/button that serves two purposes.>

**Grade: <GRADE>.**

## 4. The fix (diff sketch, not applied)

```diff
<minimal, targeted diff — comment the diff with the incident file's own name and date so a
future reader knows why this line exists>
```

<Note any file that needs regenerating rather than hand-editing (e.g. a build-generated
config file), and what command regenerates it.>

## 5. Regression guard

<The specific test, static check, or CI assertion that would have caught this before it
reached the owner — a unit test, a boot-time assertion, a lint rule. If none is practical,
say so and say what manual check should be added to the pre-release checklist instead.>

## 6. What this does not establish

<Be explicit about the boundary. What remains UNKNOWN? What would the next real-hardware
test need to check to close the gap between STRONGLY INDICATED and CONFIRMED? Name the exact
next step, not "further investigation needed".>

**NEXT STEP:** <one concrete, ordered action>
