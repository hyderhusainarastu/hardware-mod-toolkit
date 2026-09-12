# PITFALLS — an honest ledger of what actually went wrong

Every entry below is a real failure paid for on the worked example (`<REPO>`, publicly
`byok-mod`, github.com/hyderhusainarastu/byok-mod), not a generic warning. Each is written the
way you'll actually arrive at it: **Symptom** first (because that's what you have when you open
this file), then **What it actually was**, then **Fix**, then **Check that catches it next
time**. Every entry cross-links the skill built to prevent it.

## Contents (by symptom)

1. [Panel ACKs every byte and stays blank](#1-panel-acks-every-byte-and-stays-blank)
2. [Image shifted a non-page-aligned number of rows](#2-image-shifted-a-non-page-aligned-number-of-rows)
3. [Boot loop the moment an update starts writing](#3-boot-loop-the-moment-an-update-starts-writing)
4. [Device restarts instead of powering off](#4-device-restarts-instead-of-powering-off)
5. [No serial port after a reset](#5-no-serial-port-after-a-reset)
6. [Host tool crashes with a sequence-gap error](#6-host-tool-crashes-with-a-sequence-gap-error)
7. [An editor or session hook fires a device command during a test run](#7-an-editor-or-session-hook-fires-a-device-command-during-a-test-run)
8. [A network name committed and then redacted — but still in history](#8-a-network-name-committed-and-then-redacted--but-still-in-history)
9. [An automated agent runs a command against the real device](#9-an-automated-agent-runs-a-command-against-the-real-device)
10. [A stale generated build config silently reverts a safety option](#10-a-stale-generated-build-config-silently-reverts-a-safety-option)
11. [A package member is not byte-identical to the build output](#11-a-package-member-is-not-byte-identical-to-the-build-output)

---

## 1. Panel ACKs every byte and stays blank

**Symptom.** Every draw command comes back ACKed. The transport reports success at every
layer — a success return code, zero I2C errors, zero NACKs. The panel shows nothing. The host
tool's `info`/`status`-equivalent commands work fine; only the actual pixels never appear.

**What it actually was.** The vendor's own init sequence was replayed byte-for-byte and still
missed one thing: a post-first-frame **display-enable** command the vendor sends once, after
its own boot self-test, that isn't part of the reusable init table itself. On the worked
example that command was `CMD 0xC9` / `DATA 0xAD` on a UC1611-class controller — a
controller-specific opcode, but the *shape* of the mistake generalizes: many display
controllers power up with the panel driver logically disabled even though the controller
itself is fully responsive to commands, so every write ACKs (the bus transaction succeeds)
while the glass stays dark because the enable bit was never set. A second, compounding factor
made this specific case worse: the driver had also enabled a bulk multi-byte write mode that
had never been exercised against the real controller, and because ACK-checking was disabled on
that bus (matching the vendor's own transport), a partially-latched bulk burst would *also*
report success with zero errors logged — so the first fix attempt (flip back to per-byte
writes) narrowed the search but didn't fix it on its own; the missing enable command did.

**Fix.** Exhaustively enumerate every command byte the vendor's firmware actually sends to the
panel/peripheral (not just the reusable init table — the *entire* call path from cold boot to
first frame), and confirm your own bring-up sends every one of them, in the same order, even
ones that look like they "shouldn't matter." Where you found a bulk/burst write mode that has
never been visually confirmed on real hardware, default it **off** until it has been.

**Check that catches it next time.** Add an instrumented counter of actual bus transactions
issued per refresh cycle, logged alongside the existing error counter — a driver that is
silently sending fewer transactions than a full frame requires will show it here even when
every individual transaction reports success. Before trusting any "it ACKs" observation, get a
photograph of the actual glass; a `refresh_result=ESP_OK` log line is not evidence that
anything changed on the physical panel.

**Prevented by.** `skills/custom-firmware-bringup/SKILL.md` (display bring-up checklist).

---

## 2. Image shifted a non-page-aligned number of rows

**Symptom.** The display is otherwise working — text and graphics render, look right,
horizontal position is correct — but the whole image is offset vertically by some number of
rows that is **not** a multiple of the display's page/byte granularity (e.g. 15 rows on an
8-row-per-page controller). The rows vacated at the far edge show random, never-written
controller memory, not wrapped content.

**What it actually was.** The display controller has its own row-granular vertical-origin
register (a "scroll line" or "start line" register, distinct from any page/window addressing
your driver already programs), and it powers on holding a non-zero value that neither the
vendor's firmware nor yours ever clears — because neither firmware ever sends a single byte in
that register's command range. The value can be genuinely arbitrary per unit (traced, on the
worked example, to a very specific mechanism: a parameter byte from an *adjacent*, unrelated
command landing in the scroll-line register because the controller wasn't in the state that
command's second byte expected). The signature that identifies this class of bug specifically:
the shift is **not** a multiple of the page/byte granularity (rules out a window/page-offset
bug, which can only ever move things by whole pages), the image is **not** mirrored within a
page or byte (rules out a bit-order bug), and the vacated rows show garbage rather than wrapped
content (rules out an address-wrap bug).

**Fix.** Identify the controller's row-granular origin register from its datasheet (search
specifically for a register described as controlling the display's start line, scroll
position, or vertical origin — not the same thing as page/window addressing) and explicitly
program it to zero as part of bring-up, gated behind its own config option, additive in front
of the vendor's own sequence rather than replacing any of it.

**Check that catches it next time.** Measure the exact shift in pixels/rows from an actual
photograph (calibrate scale from two known-distance reference marks, e.g. text lines drawn at
known coordinates) before proposing a fix — a shift's exact magnitude and whether it's
page-aligned rules candidate mechanisms in or out arithmetically, without needing to guess. If
the first attempted fix doesn't move the image, don't stack more guesses on top of it: do a
register sweep (write every plausible value in the suspect register's range, one at a time,
observing which one puts the image back) rather than reasoning further from documentation
alone.

**Prevented by.** `skills/custom-firmware-bringup/SKILL.md` (display bring-up checklist).

---

## 3. Boot loop the moment an update starts writing

**Symptom.** The device boots fine normally. The instant an update/install process actually
starts writing (not merely reading or validating — the crash lands right after the "installing"
log line), the device panics and reboots, then repeats the same crash on the next boot attempt
if the same update is still staged.

**What it actually was.** A multi-kilobyte scratch buffer (a streaming I/O buffer, in the
worked example 4096 bytes, plus a smaller header buffer alongside it) was declared as a plain
**stack-local variable inside a function called directly from the platform's own startup/main
task** — a task whose default stack size is sized for "launch other tasks," not for holding a
multi-KB buffer plus the full call chain underneath it (filesystem layer, the OTA/flash-write
API, a streaming hash update, block-device driver). The buffers alone already exceeded the
entire configured stack budget before counting a single frame of the code that actually uses
them. This is a classic embedded-RTOS trap: the crash only manifests the instant the code path
that owns the buffer actually runs, which for an update mechanism can be much later than
initial boot testing ever exercised, making it look like a new defect in the *update* logic
when the buffer placement was wrong from the first commit that added it.

**Fix.** Never put a scratch buffer larger than a few hundred bytes as a local in a task whose
stack budget you haven't explicitly sized for it — especially the platform's own default
startup task. Move the operation to its own dedicated task with a stack sized for its actual
measured needs (locals plus the deepest call chain underneath them, with margin, tightened
later from a real high-water-mark measurement), or move the buffer itself to the heap. Treat
raising the default task's stack size as defense-in-depth on top of the real fix, never as the
fix by itself — it just delays the same class of failure to a slightly larger buffer next time.

**Check that catches it next time.** A static regression guard: a script that reads every
task's configured stack size and every function it (transitively) calls's largest local
declarations, and fails the build if any function's locals alone approach a meaningful fraction
of its task's budget — see `skills/hardware-in-the-loop-testing/SKILL.md`'s static-guard
pattern. Enable the platform's stack-overflow canary check explicitly (don't rely on it being
the current default; pin it, so a future toolchain upgrade can't silently disable it) — it is
the exact mechanism that surfaces this class of bug as a clear, named panic instead of silent
memory corruption.

**Prevented by.** `skills/custom-firmware-bringup/SKILL.md` (task stack budgeting) and
`skills/hardware-in-the-loop-testing/SKILL.md` (static regression guards).

---

## 4. Device restarts instead of powering off

**Symptom.** A power-off gesture (e.g. holding a button) appears to work at first — the device
draws a "powering off" message and cuts power — but seconds later it comes back on by itself,
with a cold-boot reset reason, not a software restart.

**What it actually was.** Two related but distinct mechanisms, both worth checking:

- **Same button drives both power-on and power-off.** If the power-cut GPIO is asserted the
  instant a hold-timer threshold fires, and the triggering button is physically still being
  held down at that exact instant (very plausible — the user's thumb is still on the button
  they've been holding for the required duration), the external power-hold circuit reads that
  same still-held press as a fresh power-**on** request the moment the rail drops, and the
  device silently power-cycles instead of turning off. **Fix:** wait for the button to be
  **released** before asserting the power-cut GPIO — no timeout, since a timeout reintroduces
  the same race under different timing.
- **A brownout, not a restart, releases the "kill" pin — and something else re-powers the
  rail.** Even with the above fixed, if the firmware cuts power while a power source (e.g. a
  USB cable) is still supplying current, the resulting brownout resets the MCU and releases
  every GPIO pad, including the one that was asserting "stay off." With an external power
  source still present, the rail can re-establish itself and the chip cold-boots. The vendor's
  own firmware may have an explicit guard for exactly this ("refuse to power off while on
  external power") that a from-scratch power-off implementation can miss entirely if it isn't
  checked against the vendor's actual disassembly.

**Fix.** Debounce a full button-release before cutting power (item 1); and check what the
vendor's firmware does at the exact moment of power-off — specifically whether it refuses to
cut power under some condition (external power present) that your implementation doesn't yet
check.

**Check that catches it next time.** Test power-off with the external power source
**physically disconnected** as well as connected — if the behavior differs between the two
conditions, that difference is diagnostic, not noise. Read the vendor's power-off code path in
full (not just skim for the GPIO write) before assuming your reimplementation covers the same
cases it does.

**Prevented by.** `skills/custom-firmware-bringup/SKILL.md` (power-latch handling).

---

## 5. No serial port after a reset

**Symptom.** After resetting one MCU on a multi-MCU board (via its own reset line, or a
debug-bridge reset), the console/serial node doesn't come back — or comes back but the display
shows artifacts, wrong contrast, or the device is unresponsive to input — until the whole board
is fully power-cycled.

**What it actually was.** Resetting one MCU does not reset the others on the same board. A
companion MCU and a display controller (or any other peripheral with its own latched state)
keep whatever state they were in across the reset of just the main chip — and separately, on
some SoCs, certain internal peripheral state (a USB PHY mux selection tied to the always-on RTC
power domain, for instance) survives a CPU-level reset by design, which can make the *next*
boot's USB personality behave unexpectedly even though the reset "worked."

**Fix.** Treat "reset just the main MCU" and "power-cycle the whole board" as two genuinely
different operations with different guarantees, and always exit a debug/download-mode session
with the latter: unplug the cable (or otherwise fully remove power) and do a real power-on,
never a single MCU's reset line alone. If your own firmware needs to survive a self-initiated
restart (an OTA-triggered reboot, for example) without losing a recoverable USB console, hand
back any RTC-domain-latched peripheral state explicitly before calling the restart, rather than
relying on the reset to clear it.

**Check that catches it next time.** After adding any reset-adjacent firmware change,
explicitly test the reset path with the board in the state that most exposes the problem (cable
connected, other MCU running) — not just a cold power-on, which won't exercise this at all. If
a companion MCU exists, get in the habit of a full power-cycle as the default recovery step
before escalating to a more invasive diagnosis.

**Prevented by.** `skills/mcu-safe-backup/SKILL.md` (the multi-MCU reset trap, §2) and
`skills/hardware-recon/SKILL.md` (mapping which MCU owns what before you reset anything).

---

## 6. Host tool crashes with a sequence-gap error

**Symptom.** A host tool that was running fine crashes with a "sequence gap" or similar
desync error, seemingly out of nowhere — often right after some unrelated background process
also talked to the same device.

**What it actually was.** Two independent host processes opened the same physical serial port
at the same time. The port itself didn't refuse the second open (many serial libraries allow
non-exclusive access by default), so the second process's own handshake reset the device's
protocol session state out from under the first process, which then received a "your sequence
number doesn't match what I expected" response to its very next request. The protocol's own
specification may already correctly say this particular error is informational — the receiver
processed the frame normally and is just reporting the gap — but if the *host's* transport
layer treats every NACK-shaped reply as a fatal error rather than checking which specific error
it is, a spec being right on paper doesn't stop code that quietly disagrees with it from
crashing in production.

**Fix.** Open the port **exclusively** (an OS-level advisory lock, e.g. `exclusive=True` on a
pyserial-class port) so a second open fails loudly with a distinguishable error instead of
silently succeeding alongside the first. Route any one-shot command that might run while a
long-lived loop already owns the port through that loop's own IPC/queue mechanism instead of
opening a second connection at all. Make the specific informational error code survive intact
through every layer between the wire and the caller — the transport should keep waiting for the
real reply after seeing it, not return it as the answer.

**Check that catches it next time.** A test that scripts a fake transport replying with the
gap error and asserts the client keeps waiting for the real reply that follows it, rather than
raising. A test that asserts the exclusive-open flag is actually passed to the underlying
serial library. If a design doc already says a resource is "single-consumer," that's a signal
to go add the OS-level enforcement immediately, not a substitute for it — intent documented in
prose is not the same as intent enforced in code, and it stays a latent bug until a second call
site that could plausibly touch the resource exists, which tends to arrive sooner than
expected.

**Prevented by.** `skills/framed-serial-protocol/SKILL.md` (exclusive port ownership,
informational error handling).

---

## 7. An editor or session hook fires a device command during a test run

**Symptom.** A background automation (an editor plugin, a session lifecycle hook, a CI step)
unexpectedly sends a command to the real, physically connected device — during what was
supposed to be a pure host-side test or development session.

**What it actually was.** Two independently-correct pieces of automation interacted badly
because they ended up sharing one physical, single-consumer resource with no coordination
between them: a lifecycle hook that notifies a device on certain events, and a host loop
(dashboard, monitor, whatever) that also talks to the same device — installed and tested
separately, each fine in isolation, and only actually colliding once both were live at the same
time. This is exactly the kind of interaction that's easy to miss when each piece is reviewed
on its own, and it is also, in a broader sense, the same root cause as pitfall 6 above wearing
a different hat: an uncoordinated second writer to a single-consumer resource.

**Fix.** Whichever fix applies to the underlying resource contention (exclusive port ownership,
IPC-first routing — see pitfall 6) also fixes this. On top of that, add a cheap, independent,
belt-and-braces guard at the automation's own entry point — e.g. a hook script that checks
whether a device-owning process is already running before it does anything, and skips its own
action if so. Keep that guard even after the "real" fix lands; a second, independent layer is
worth the extra few lines specifically because this class of interaction is easy to miss when
each piece is reviewed in isolation, and it is cheap insurance against the next unforeseen
interaction of the same shape.

**Check that catches it next time.** Before installing any lifecycle hook or background
automation that can touch the device, explicitly ask "what else already talks to this device,
and what happens if both fire at once?" — and write the answer down as part of the automation's
own installation record, not just in the automation's code comments.

**Prevented by.** `skills/hardware-in-the-loop-testing/SKILL.md` and
`skills/framed-serial-protocol/SKILL.md` (exclusive port ownership).

---

## 8. A network name committed and then redacted — but still in history

**Symptom.** A publication-readiness scan of the current working tree finds nothing —
`git grep` on `HEAD` for known-sensitive strings comes back clean — yet a secret is still
publicly exposed the moment the repository is shared.

**What it actually was.** A Wi-Fi SSID (or any other sensitive value) was committed early in
the project's history, then redacted in a later commit. Redacting the working tree does not
remove the value from git history: `git log -p` on the *earlier* commit still shows it in plain
text, and will keep showing it in every future clone, forever, because git history is
append-only by default and a later commit doesn't erase what an earlier one recorded.

**Fix.** Do not attempt to fix this by rewriting the private repository's history in place
(`git filter-repo`, an orphan-branch rebuild) and then publishing that — it's disruptive to
anyone who already has a clone, and it's easy to miss a second occurrence while fixated on the
one you found. The fix that avoids the problem entirely: **never publish the private repo's
history at all.** Build a fresh export from a single point-in-time snapshot (e.g. `git archive
HEAD | tar -x` into a clean directory, never `cp`/`rsync` a `.git` directory), make one clean
commit in the new tree, and let the private repo — imperfect history and all — stay private
forever.

**Check that catches it next time.** Any publication audit must scan `git log -p --all` (the
full history) for sensitive patterns, not only `git grep` on the working tree — a working-tree
grep is structurally blind to anything that was ever removed. And run redaction on every
capture **before** it is ever staged for commit, not as a pre-publication cleanup step,
because "the one place we forgot to redact" only has to happen once to end up permanently in
history under the never-publish-history-directly approach's absence.

**Prevented by.** `skills/publish-hygiene/SKILL.md` (fresh-history export, full-history audit)
and `skills/serial-and-usb-recon/SKILL.md` (redaction from the first capture).

---

## 9. An automated agent runs a command against the real device

**Symptom.** During what was meant to be host-only, mock-only testing or smoke-testing, an
automated session (an AI agent, a script, a CI job) ends up opening the real, physically
connected device's serial port and sending it live commands — with no device operation actually
intended.

**What it actually was.** A command's default behavior auto-discovers and connects to whatever
matches its expected device signature — which, if the real device happens to be plugged in and
running compatible firmware, is the real device, silently, with no explicit `--port` or mock
flag required to reach it. A "never open a real port" rule stated only in an operating-rules
document has no way to stop a tool whose *default* argparsing path connects to hardware the
instant it's given no arguments at all.

**Fix.** Make "never touch the real device" a property the *tooling* enforces, not a rule the
operator has to remember on every invocation: a required environment variable (a force-mock
gate) that every automated/test invocation must set, with connection code that checks it before
ever attempting device discovery — so an automated run without that variable fails closed
rather than silently finding real hardware. Any command with an auto-discovery fallback should
require an explicit opt-in to touch a real device, never treat "found a matching device" as
implicit permission.

**Check that catches it next time.** Grep the automated-run entry points (test suite,
CI config, any hook script) for the presence of the force-mock gate on every invocation that
could reach device-connection code — an omission here is exactly how a real device got touched
in the first place, and it's a mechanical thing to check for once you know to look. Log, from
the connection code itself, every real (non-mock) device open with enough context to reconstruct
what triggered it — this is what actually let the worked example determine, after the fact,
that no destructive command had been sent, only benign draw/clear calls; without that log, the
same incident would have been much harder to bound.

**Prevented by.** `skills/hardware-in-the-loop-testing/SKILL.md` (the force-mock environment
gate and fake transports).

---

## 10. A stale generated build config silently reverts a safety option

**Symptom.** A safety-relevant build option was deliberately changed in the project's tracked
defaults file — and a later build somehow still has the *old* value, with no error, no warning,
and no obvious sign anything is wrong until the behavior the option controlled shows up
unexpectedly.

**What it actually was.** Many embedded build systems separate a tracked **defaults** file
(what a fresh checkout should build with) from a **generated** config file (what an existing
build directory is actually configured with right now). The generated file is created once from
the defaults and then persists independently — an incremental build reads the generated file,
not the defaults file, so changing the tracked defaults does nothing to a build directory that
already has a generated config from before the change. A safety-relevant flip (disabling a
rollback mechanism that doesn't match this device's actual bootloader, tightening a write gate)
can look like it landed — the diff to the defaults file is real, reviewed, and merged — while
every subsequent build in an existing checkout keeps building with the old, unsafe value,
completely silently.

**Fix.** After changing any safety-relevant build default, force a full reconfiguration — not
merely a build — of any build directory that will produce the artifact that ships (a full
clean/fresh-configure step in whatever your toolchain calls it), and then **grep the generated
config file itself**, not the defaults file, to confirm the value actually took effect. Treat
"I changed the defaults file" and "the generated config has the new value" as two separate
claims that both need checking, because they can and do diverge.

**Check that catches it next time.** Make this an explicit, named step in the release process:
after every clean rebuild, grep the freshly generated config for every protected/safety-relevant
key and confirm each one's exact value, printing the result into the release record rather than
asserting "unchanged" from memory. `workflows/firmware-release.js` performs this check as a
named phase for exactly this reason — protected configuration is re-grepped from the freshly
regenerated config, never merely assumed unchanged because the defaults file wasn't touched
this time.

**Prevented by.** `workflows/firmware-release.js` (protected-config re-verification phase);
`skills/custom-firmware-bringup/SKILL.md`.

---

## 11. A package member is not byte-identical to the build output

**Symptom.** A release was built successfully, packaged, and installed — but the behavior on
the device doesn't match what the build's own tests/logs suggested it should, and there's no
obvious code defect to explain the gap.

**What it actually was.** The packaging step that assembles the install archive picked up a
stale or wrong copy of one of its members instead of the artifact the build step actually just
produced — a leftover file from a previous build, a case-sensitivity mismatch on a
case-sensitive filesystem silently failing to find the intended file and falling back to
something else, or a packaging script pointed at the wrong output path. "The build succeeded"
and "the package contains what the build produced" are two different claims, and a packaging
pipeline that has never explicitly checked the second one can drift silently for a long time
before anyone notices the discrepancy — especially for a member that changes rarely, where a
stale copy can look plausible for release after release.

**Fix.** After packaging, hash every member of the assembled archive and compare each hash
against a hash taken directly from the corresponding fresh build output — not against a
previous release's recorded hash, and not merely against "the packaging script didn't error."
A member that's supposed to be unchanged from a known-good baseline (e.g. a vendor asset you're
deliberately not touching) should be checked against *that* baseline's hash explicitly, stated
as such, rather than left unchecked on the assumption that "we didn't touch it."

**Check that catches it next time.** Make byte-identical verification a named, automatic step
of the packaging pipeline itself, not a manual sanity check performed occasionally — record
every member's hash in the release record every time, so a silent regression shows up as a
hash mismatch against the previous release's own recorded value even before anyone manually
inspects anything. `workflows/firmware-release.js` treats "the packaged artifact's member is
proven byte-identical to the build output" as a required check, not an assumption that a
successful build implies a correct package.

**Prevented by.** `workflows/firmware-release.js` (byte-identical member verification);
`agents/release-packager.md`.
