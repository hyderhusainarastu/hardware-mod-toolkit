---
name: hardware-in-the-loop-testing
description: "Make hardware-safety rules machine-enforced rather than advisory: a force-mock environment gate so no automated run can open a real device, fake transports in tests, static regression guards that fail on the source pattern behind a past crash, shared host/firmware test vectors, and a human-run hardware checklist. Use when agents or CI run against a project that also talks to real hardware."
---

# hardware-in-the-loop-testing

Two things actually went wrong in the worked example this skill is drawn from
(github.com/hyderhusainarastu/byok-mod), and a prose rule ("never touch hardware")
prevented neither of them:

1. **An agent-run host command opened the real, physically-connected device's serial
   port** — twice — from a plain CLI invocation outside the test suite, with no device
   operation actually intended.
2. **An editor/session hook fired a device command in the background during an
   unrelated run.** A `Stop`-style hook ran a "harmless" status/notify command while a
   long-running dashboard loop already held the port open. The hook's command opened a
   second, non-exclusive handle to the same port, which reset the device's protocol
   session counter out from under the loop — the loop then saw a sequence-gap NACK
   (`E_SEQ_GAP`) it treated as fatal and crashed, and the actual root cause took a full
   diagnosis pass to find because nothing had logged that a second process had touched
   the port at all.

Neither incident involved malice or a missed warning — both commands did exactly what
they were told to do. What was missing was a *mechanism* that made "don't open a real
port from an automated context" true regardless of what any individual command line,
hook, or agent decided to run. That's what this skill builds: four layers of
enforcement, weakest to strongest, plus the specific hazard (hooks) that defeated the
weaker layers in practice, plus the parts of a safety net that genuinely cannot be
automated and have to become a human checklist instead.

This generalizes past serial ports: "real hardware" here also covers a physical
display, a Bluetooth/BLE link, an SD card the device reads at boot, or any other
side channel an automated test run could accidentally exercise against a real unit.

## 1. The four enforcement layers

Layer them — do not treat any single one as sufficient, because each has a distinct
failure mode:

### Layer 1 — the prose rule

"Automated agents and CI never open a real device." Necessary, cited in
`templates/CLAUDE.md`, and — on its own — exactly what both incidents above show is
insufficient. Keep it, but never stop here.

### Layer 2 — an environment gate the transport itself honours

Pick one environment variable name, e.g. `<MOCK_ENV_VAR>` (the worked example used
`BYOK_FORCE_MOCK`), and check it in exactly one place: the low-level transport's own
connect/open call, before it ever resolves or opens a port.

```python
# host/<pkg>/transport.py — connect()
import os

class MockRequired(TransportError):
    """Raised instead of opening a real port when <MOCK_ENV_VAR> is set and the
    caller did not supply an explicit mock/fake factory override."""

def connect(self, ...):
    if os.environ.get("<MOCK_ENV_VAR>") and self._serial_factory is _default_real_factory:
        raise MockRequired(
            "<MOCK_ENV_VAR> is set; refusing to open a real port. "
            "Pass a fake serial_factory or unset <MOCK_ENV_VAR>."
        )
    # ... normal connect path (real port resolution/open) ...
```

Design choices that matter here, each one taken from a real gap the incidents exposed:

- **Make the raised error a subclass of whatever error class every call site already
  catches for "no device found."** The worked example's gate raises a `TransportError`
  subclass because every existing `except TransportError` (and every narrower
  `except (WrongDevice, NoDeviceFound, HandshakeFailed, TransportError)`) call site,
  including a fallback path that queues work for later instead of crashing, already
  degrades gracefully for that family. A gate that raises a *new*, uncaught exception
  type instead turns "safely refused" into "the whole process crashes" — worse than
  the thing it's protecting against.
- **The gate changes nothing for a real end user.** The variable is unset by default in
  every shipped/installed context; only a dev/agent/CI shell exports it. Document that
  export as a step the *shell* performs (`export <MOCK_ENV_VAR>=1` before running any
  device CLI directly), not as something the tool sets automatically — an
  automatically-set gate is one more thing that can silently stop being set.
- **State explicitly that the test suite itself never needs the variable**, because it
  never reaches this code path at all (Layer 3 replaces the transport before the gate
  check would run). The gate exists for the shells and hooks that run the *real* CLI
  directly, outside the test harness.
- **Set the gate in every automated prompt template and CI job**, not just in test
  setup — an agent invoked to "check device status" from a shell that never sourced
  the gate is exactly the failure mode incident 1 was.

### Layer 3 — a fake transport injected in every test, so nothing enumerates ports at all

Layer 2 still resolves a real port list before refusing to open it, on some code paths
— fine for a gate, not fine for a full test suite, which should never call into a
real port-enumeration API at all. Give tests a fake that:

- satisfies the same interface the real transport needs (`.read` / `.write` /
  `.close` / `.is_open` at minimum),
- **decodes every outbound byte with the project's own real wire-protocol parser**,
  not a hand-rolled stub — so a test failure here means the code under test actually
  produced a malformed frame, not that the fake diverged from the real format,
- answers every ACK-requiring request generically (a HELLO gets a real
  HELLO_ACK-shaped payload; everything else gets a minimal ACK) rather than scripting
  one exchange at a time, with an override path (`type_replies={...}`) for the
  handful of tests that need a specific typed reply,
- can be told to go silent for specific message types (`silent_types={...}`) to model
  "the write succeeded, nothing ever answered it" — what a real disconnect looks like
  from the requesting side,
- drives a **fake/manual clock** for every timeout and backoff delay in the transport
  under test, so a reconnect-backoff test costs milliseconds of real wall-clock time
  instead of the seconds the real backoff schedule specifies:

```python
class ManualClock:
    def __init__(self):
        self.t = 0.0
    def time(self):
        return self.t
    def sleep(self, seconds):
        self.t += seconds  # advances the fake clock; never blocks
```

- exposes a way to **inject unsolicited device events** into the read buffer directly
  (a button press, a status-changed notification) for event-polling tests, without
  those events needing a real request/response round trip.

For a helper process the real device side spawns (a capture helper, a companion
binary invoked as a subprocess) rather than a library call, write the fake as a
**standalone script run as a real subprocess**, understanding only the handful of
CLI flags the real one uses, and add test-only flags the real binary doesn't have
(a fixed frame count, a synthetic failure mode, a forced non-zero exit code) so
failure paths are reachable without a device:

```python
#!/usr/bin/env python3
# fake_capture_helper.py — drop-in stand-in for the real capture binary.
# --frames N            emit N synthetic frames then exit 0 (default 3)
# --permission-fail      print a message and exit 3 (models a denied OS permission)
# --exit-code N          exit N after emitting frames (models a helper crash)
```

Build one fake per external dependency that a test would otherwise have to talk to
for real (the transport, a capture helper, a cloud call) — each is small, and each
removes one more way a test run could accidentally touch something real.

### Layer 4 — scripts that refuse dangerous arguments outright

For any standalone script that *can* touch real hardware when run directly (a backup
tool, a device-info probe, a flashing wrapper), refuse dangerous input at two points
independently — see `skills/mcu-safe-backup/SKILL.md` §4 for the full pattern
(argument-level refusal before anything runs, a second refusal on the fully assembled
command line immediately before every invocation, dry-run by default with an explicit
`--yes` required to execute anything). That skill's gate is this layer's concrete
implementation for the "one script that is allowed to write" case; this skill's layers
1–3 are what keep every *other* automated path from ever reaching that script's own
gate in the first place.

## 2. Hooks are a hazard

An editor or session hook that runs a device-touching command on some event (a file
save, a session `Stop`, a periodic tick) will eventually fire **during** a test run or
underneath a running long-lived loop — that is what happened in the incident this
skill opens with, and it is not a one-off: hooks fire on events the hook author does
not fully control the timing of, and "this command is harmless, it only reads status"
is not the same claim as "this command never opens a competing handle to a port
something else already owns."

If a hook must exist that can touch the device:

- **Gate it on whether the long-running consumer of that device is currently running**
  — a `pgrep`-style check for the loop's process name/PID file before the hook does
  anything device-touching, skipping (not queuing, not retrying) if the loop is live.
  This is a stopgap, not a fix: prefer routing the hook through the loop's own IPC path
  instead (below), because a process-existence check has an unavoidable race between
  "checked" and "acted."
- **Route the command through the running loop's own queue/IPC mechanism** instead of
  opening the device directly — e.g. a small JSON file or socket the loop already polls
  for out-of-band requests, so "notify the device" becomes "write a request the loop
  will pick up and serialize onto the one connection it already owns," never a second
  competing `open()`.
- **Disable the hook for the duration of any test run or long-lived session**,
  explicitly, rather than trusting a race-prone runtime check alone.
- **Make the transport itself detect and log a second open** (or refuse it outright,
  where the OS/driver allows exclusive opens) so a future incident like this one is a
  one-line log message instead of a multi-hour diagnosis session reconstructing what
  touched the port and when.

Treat every hook, cron job, or background watcher in the project inventory as a
candidate for this hazard — audit for "does anything fire on a timer or an editor
event that could open this device" whenever a new hook is added, not just when a
crash prompts the question.

## 3. Static regression guards

After any incident that had a specific, nameable root cause in source (not just "a
bug"), add a **host-only, dependency-free script** that fails on the exact source
condition that made the incident possible — not a general linter, a narrow check
tied to one incident's actual root cause. Worked example (a firmware task-stack
overflow that crashed on boot): the incident's source condition was four separate
facts about the code, and the guard checks exactly those four:

1. **The dangerous function is not called directly from the wrong caller's own body.**
   The overflow happened because a large-stack-footprint routine (an update-installer
   entry point) was called straight from the main task's own function body, so its
   locals shared the main task's small stack instead of a task sized for them. The
   guard isolates the caller's body by brace-depth counting from its signature (robust
   to helper functions moving around the file) and fails if the dangerous call
   appears inside it, naming the required fix (route through the dedicated-task
   wrapper) and citing the incident doc.
2. **The dedicated task's own stack-size constant is present and above a floor.** A
   regex for `#define <STACK_CONST> <n>`, failing if the constant is missing or below
   the floor, with the floor and the constant name both named in the failure message.
3. **No oversized stack-local array remains in the named source files.** A regex for
   `(uint8_t|char) name[N]` (resolving `N` through any same-file `#define`), skipping
   anything that doesn't parse as a fixed-size array (a `heap_caps_malloc`'d pointer
   does not match this pattern at all — that's deliberate: moving a buffer off the
   stack onto the heap is exactly the fix being protected). Fails if the largest match
   in either named file exceeds the cap, naming the file, the array, its size, and the
   required fix (heap-allocate with a `free()` on every return path).
4. **The build's own defaults still pin the raised safety margins.** A regex over the
   build's default-config file for the bumped main-task stack size (failing if it's
   missing or has regressed below the post-incident value) and for the runtime
   overflow-canary feature flag staying enabled, plus (if the file exists on this
   checkout) the same canary flag in the *generated* config, which is the actual build
   input — the defaults file only needs to reproduce it on a fresh checkout.

The reusable pattern, independent of what the four checks happen to be for a given
project:

```python
#!/usr/bin/env python3
"""tests/static/check_<name>.py -- static regression guard for <INCIDENT_ID>
(docs/incident-<INCIDENT_ID>.md).

Host-only, no device/serial/toolchain involved -- runs as a plain script with
no test-framework dependency, so it runs in any Python 3 without a venv:

    python3 tests/static/check_<name>.py

Exits 0 (printing one PASS line per check) on success. Exits 1 with a specific,
actionable message naming the failing file/line on the FIRST failure --
deliberately fails loudly rather than guessing a fix.
"""
FAILURES = []

def fail(msg): FAILURES.append(msg)
def ok(msg): print("PASS: " + msg)

def check_one(...):
    # inspect committed source; fail() with a message naming the file, the
    # exact offending construct, and the incident doc; ok() on success.
    ...

def main():
    check_one(...)
    check_two(...)
    if FAILURES:
        for f in FAILURES:
            print("FAIL: " + f)
        return 1
    print("ALL CHECKS PASSED")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

Notes that keep this pattern honest:

- **A false negative here just means a human has to notice in review; a false
  positive (failing on unrelated code) is the safe direction to fail in.** Write the
  regexes conservatively with that asymmetry in mind — better to occasionally flag
  something that turns out fine than to silently pass the exact pattern that already
  caused one crash.
- **This is a static check, not a substitute for real measurement.** A hardware stack
  canary (or equivalent runtime protection) only fires on the real device and can't be
  reproduced by a host-side script — say so in the script's own docstring, and keep
  logging the real runtime measurement (e.g. a high-water-mark read) on-device
  separately. The static guard's job is narrower: stop a *known* dangerous pattern
  from being silently reintroduced by a later edit, not prove the system is safe.
- **Cite the incident doc in every failure message.** A guard that fails with a bare
  assertion teaches nothing; a guard that fails with "this is the exact condition that
  caused <INCIDENT_ID> — see docs/incident-<INCIDENT_ID>.md" turns a CI failure into a
  five-second fix.
- Run every static guard alongside the rest of the host test suite (in the same CI
  step or a pre-commit hook) — it costs milliseconds and needs no device, no
  toolchain, and no network.

## 4. Shared host/firmware test vectors

If the project has two independent implementations of the same wire format (a host
language and firmware C, say), the only way to keep them byte-identical is to
**generate vectors from one implementation and assert the other reproduces them
exactly** — not to eyeball both against the spec separately, which only proves each
side agrees with the spec's prose, never that they agree with *each other*.

Pattern:

1. The firmware/reference-language test binary encodes a fixed, named set of
   messages with its real encoder and dumps each as `{name, type, flags, seq,
   payload_hex, crc32, frame_hex}` to a checked-in JSON file (e.g.
   `tests/proto/vectors.json`), generated by `make -C tests/proto test` (or
   equivalent) — not hand-typed, and not committed as a static fixture that can
   silently drift from what the encoder actually emits.
2. The other side's test suite loads that JSON and asserts, per vector:
   - its own encoder produces byte-identical output for the same inputs,
   - its own decoder recovers the exact same fields (type/flags/seq/payload) from the
     vector's raw bytes,
   - the CRC/checksum recomputes to the recorded value.
3. Skip (don't fail) that suite cleanly with an actionable message if the vectors file
   hasn't been generated yet ("run `make -C tests/proto test` first") — a missing
   generated artifact is a build-order problem, not a protocol regression.
4. Separately, hand-type a handful of vectors straight from the spec document itself
   (not from either implementation) as their own test class, and reproduce the spec's
   own reference encoder snippet (if the spec includes one) as a real test — this
   catches an implementation drifting from the *documented* format even if both
   implementations happen to still agree with each other.
5. Round-trip every message type the format defines, not just the ones with
   hand-written vectors — generate a payload deterministically per type (a simple
   formula keyed on the type/index is enough), encode, decode, and assert every field
   survives. Add malformed-input tests (corrupted length, corrupted CRC, wrong version,
   truncation, garbage before a sync marker, one-byte-at-a-time feeds) and a fuzz test
   that feeds a large volume of random bytes and asserts the parser never raises,
   whatever the byte-count budget of the language reasonably allows in CI.

This is the only technique in this skill that isn't primarily about *keeping tests off
real hardware* — it's about making sure that when the host and firmware sides finally
do talk to a real device, they've already been proven to agree with each other on the
wire format, which turns a whole category of "why doesn't this decode" hardware
debugging into something caught on the host, offline, in milliseconds.

## 5. The human checklist — what genuinely cannot be automated

Some verification only makes sense as a human, one physical experiment at a time,
performed by the device's owner. Structure it as a numbered checklist, never as prose:

- **One experiment per row, with an explicit expected observation**, not just a task
  name. "Power off on battery, wait 30s, confirm backlight fades and stays off" is
  checkable; "test power-off" is not.
- **Group rows into named categories with a stable ID prefix** (e.g. `FP-###` for
  protocol tests that *can* run automated, `FH-###` for hardware-only tests that
  can't, `HI-###` for integration/enumeration tests, `RS-###` for recovery/safety
  tests) so later documents (a research log, a decision record, this skill's
  verification matrix) can cite a specific test by ID instead of restating it.
- **Gate anything destructive or hard-to-reverse behind an explicit go/no-go line**
  that a moderator or the owner has to actively check off before the first row runs —
  e.g. "NOT YET APPROVED — go-ahead required before powering the device with any
  update media present" as the checklist's own first line, when the very next row
  would trigger an automatic, unattended install.
- **Pre-flight rows come before risk rows, always**: a verified backup exists, a
  rehearsal on spare/scrap media succeeded, the escape-hatch path is in place (even if
  never yet tested on this exact device), required constants have been confirmed by
  reverse-engineering rather than assumed, and the build is clean and within any size
  budget the target imposes — see `skills/mcu-safe-backup/SKILL.md` §1 for the general
  form of this gate.
- **Record results into the verification matrix, not just into the checklist file
  itself**, with a grade (§6) and a citation to the actual evidence (a log timestamp, a
  capture file, an owner's own words) — a checked box with no evidence attached is not
  a passed test.

`templates/verification-matrix.md` is the canonical home for the resulting evidence
table; a project's own `test-plan.md` (if it keeps one) is where the checklist rows
and ID scheme live.

## 6. Verification vocabulary

Use a small, fixed vocabulary for how confident a piece of verification actually makes
you, and never let a stronger word stand in for a weaker fact:

- **TESTED** — automated or repeatable test coverage exists and passes (a unit/
  integration test, a static guard, a cross-checked vector suite). Can be re-run on
  demand and will catch a regression.
- **DEMONSTRATED** — it worked live, on real hardware, at least once, but coverage is
  still narrow (one input, one session, one configuration) — a real observation, not
  a claim to generalize from yet.
- **BY-PATH** (a.k.a. PASS-by-path) — a route exists and is correct by construction,
  or was rehearsed once end-to-end, but has not been stress-tested and is not backed by
  repeatable coverage. This is the grade for "the code path is written correctly and a
  human watched it work one time" — real signal, but not the same claim as TESTED.
- **PENDING** — specified or implemented, but not yet exercised at all in this way.

**Never let BY-PATH be reported as TESTED**, and never let DEMONSTRATED be rounded up
to TESTED either — the difference between "this has a regression-catching test" and
"this worked once while someone was watching" is exactly the difference a future
change needs to know before it touches that code. When a single requirement has
multiple sub-routes at different grades (one route TESTED, a fallback route still
BY-PATH), say so explicitly in the grade cell rather than reporting the stronger
route's grade for the whole requirement — see `templates/verification-matrix.md`'s
own legend and worked note on exactly this case.
