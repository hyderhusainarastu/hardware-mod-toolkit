# Rule rationale

One short paragraph per hard rule, naming the concrete failure it exists to prevent. Written
from a real project's experience, generalized so it applies to any single-unit hardware mod.

**Moderator delegates, never executes directly.** A session that both proposes an action and
is the only check on that action has no separation between idea and review. On a project with
an irreplaceable device, the review step — "is this actually safe, does the evidence really
support this" — is what catches a bad idea before it reaches hardware. Delegating work to
subagents and having the moderator read their output back forces that seam to exist.

**Model per task tier, never the top-tier model for everything.** Running every task on the
most expensive/most capable model either burns budget on mechanical work that doesn't need it,
or — the more dangerous failure — normalizes skipping a dedicated adversarial-verification
pass because "the same smart model already did it," which quietly removes the review seam
described above.

**Parallelize independent work.** Serializing everything means later phases wait on earlier
ones that don't actually gate them, which in practice pressures a session to skip steps to
catch up — and a rushed session is exactly the one that batches actions together instead of
taking them one at a time.

**No erase/write against the device.** A write-class flash operation is the single most
direct way to lose the device's current, working state. Every write rule downstream (efuse,
secure boot, NVS/partition/bootloader) is a specific case of this same failure mode.

**No efuse changes.** Efuses are one-time-programmable. A wrong efuse write cannot be undone
by any software recovery path, unlike a flash write which can at least in principle be
re-flashed.

**No secure-boot changes.** Secure boot is the device's own defense against exactly the kind
of unsigned/modified firmware a mod project produces. Changing it (rather than working within
or around it non-destructively) risks a state where the device refuses to boot anything you
can produce, with no vendor recovery path since the vendor didn't design for third-party keys.

**No blind entry into download/bootloader mode.** Entering a low-level mode without knowing
why can itself be a device-state-changing action (e.g. an unidentified button held at boot
might trigger a vendor factory-reset or erase routine, not just a bootloader handshake) — the
same risk a write-class command carries, reached through a side door.

**No shorting pads/pins.** Physically bridging two nets whose function isn't yet confirmed can
route power into a data line, short a supply rail, or trigger an undocumented factory/test
mode — with no way to know which nets are safe to bridge until the wiring is already
confirmed by lower-risk means (photographs, continuity checks recorded as observations, not
performed as an experiment on the live board).

**No overvoltage on a rated signal.** Applying 5V to a 3.3V-rated pin can immediately and
permanently damage that pin's driver — the failure is instant and typically silent until the
device stops responding on that line.

**No NVS/partition/bootloader overwrite until backup AND tested recovery both exist.** A
backup that has never been restored is unverified — it might be truncated, corrupted, or
simply the wrong region, and you find out only after the live copy is already gone. The
recovery path itself needs to have been exercised (even in a dry run) before it's trusted as
the safety net for an otherwise-irreversible write.

**Document protections rather than defeat them.** Bypassing a protection the vendor built in
(secure boot, flash encryption, read-out protection) converts "we don't yet understand this
mechanism" into "we've disabled a mechanism designed to prevent tampering," which is a much
larger and often irreversible change in the device's trust and safety posture than the
understanding step actually required.

**Full power-cycle to exit a download-mode session, not one MCU's reset line.** On a board
with more than one MCU (or an MCU plus a separate display/peripheral controller), resetting
only the MCU you were talking to can leave a companion chip mid-transaction or a display
controller in a stale configuration state. Observed concretely on a real project: resetting
only the primary MCU after an esptool session left the companion MCU and display controller
un-reset, producing display artifacts, wrong contrast, and unresponsive input that looked like
a firmware bug but was actually just stale peripheral state — resolved only by a full unplug
and power-cycle via the device's own power button.

**Evidence standard (CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN).** Reverse-engineering
from photographs and captures constantly tempts a session to "read" a marking or infer a
pinout from a reference design that merely looks similar. Without a forced label on every
claim, a POSSIBLE guess silently hardens into a fact three docs later, and an irreversible
action eventually gets taken on the strength of that hardened-but-never-verified fact.

**One physical experiment at a time, human-performed.** Batching several physical actions
together (or letting an assistant perform them) removes the ability to attribute a surprising
result to a single cause, and removes the human's chance to notice something wrong (smoke,
smell, an unexpected LED) before the next action compounds it.

**Never commit sensitive data; redact captures before staging.** Serial and USB captures
routinely contain a device's Wi-Fi SSID, MAC address, or other identifiers as a side effect of
capturing boot/enumeration traffic — nobody is deliberately logging a credential, it just rides
along. A blanket `git add -A` on a captures directory stages whatever the last capture happened
to contain; and once committed, even a redacted follow-up commit does not remove the original
value from git history, which needs an explicit history rewrite to actually purge.

**Document as you go; one entry per research action.** A finding that lives only in a session's
context is lost the moment that session ends unexpectedly, and a later session (or a parallel
subagent) then re-spends time re-deriving an already-known answer instead of building on it.

**Original evidence is immutable.** Photographs and raw captures of the device's as-found
state are the only record of what the hardware actually looked like before any modification.
Editing, recompressing, or overwriting them destroys the one thing that lets a later claim be
checked against the original observation instead of against someone's memory of it.
