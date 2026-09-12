---
name: moderator-operating-model
description: Set up the operating rules for a hardware reverse-engineering or modding project before any work starts -- a delegating moderator session, hard safety constraints on an irreplaceable device, a CONFIRMED/STRONGLY INDICATED/POSSIBLE/UNKNOWN evidence standard, one-physical-experiment-at-a-time, and a never-commit-sensitive-data rule. Use at the start of a new device project, or when an existing project has no CLAUDE.md.
---

# Moderator operating model

A single physical device, usually a bespoke or discontinued one, cannot be replaced if a
session gets impatient. Everything in this skill exists because a rushed session, working
alone against an irreplaceable board, will eventually try to do two things at once, promote
a guess to a fact, or leave a secret in git history. The rules below are the discipline that
let a real project like this run 22 phases and 16 firmware releases against one device
without bricking it or leaking anything. Adopt them on day one, not after the first mistake.

## 1. When to use

- Starting a new hardware reverse-engineering or modding project on any device you cannot
  easily buy a second one of.
- An existing project has grown past a couple of sessions and still has no CLAUDE.md, or has
  one that doesn't cover safety/evidence/session-structure.
- Onboarding a new contributor or a fresh assistant session to a project that already has
  these rules, so they read the same constraints before touching anything.

If the device is cheap, replaceable, and mistakes cost nothing, this skill is still useful
for the session-structure and evidence-standard parts, but the hardware-safety block can be
trimmed.

## 2. Install

Copy the template and fill in the placeholders:

```
cp "${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md" <REPO>/CLAUDE.md
```

(or, from a plain checkout of this toolkit: `cp templates/CLAUDE.md <REPO>/CLAUDE.md`)

Then edit every placeholder. This table is the full set used in the template:

| Placeholder | What goes there |
|---|---|
| `<DEVICE>` | The product name/model you are working on, e.g. what's printed on the box |
| `<VENDOR>` | The device manufacturer |
| `<MCU>` | The primary/USB-facing microcontroller (e.g. an ESP32 variant) |
| `<MCU2>` | A second MCU on the board, if one exists (e.g. a companion Bluetooth chip) — delete the whole block if there's only one |
| `<SOC_FAMILY>` | The chip family/toolchain family (e.g. an ESP32 family, an STM32 family) |
| `<PANEL>` | The display panel or other key peripheral, if relevant |
| `<REPO>` | This project's repo root path or name |
| `<HOST_OS>` | The developer host OS (macOS/Linux/Windows) — safety-script assumptions may depend on this |
| `<TOOLCHAIN>` | The firmware SDK/toolchain (e.g. an IDF version) |
| `<PORT_GLOB>` | The serial-port glob your OS assigns the device (e.g. `/dev/cu.usbmodem*`) |
| `<PRODUCT_STRING>` | The USB product string(s) you expect to see enumerated |
| `<FLASH_SIZE>` | Total flash size, once known |
| `<OTADATA_OFFSET>` / `<OTADATA_LEN>` | The OTA-selector partition's offset and length, once the partition table is read — do not guess these |
| `<UPDATE_PATH>` | Wherever the stock updater looks for an update file (e.g. an SD card folder) |
| `<PROJECT>` | This project's short name, used in log/branch naming |

Fill in only what you actually know; leave the rest as the placeholder and mark it UNKNOWN in
your own notes rather than guessing a value that looks plausible.

## 3. The eight rule blocks

**Session structure.** The top-level/main session acts only as a moderator: it plans,
dispatches subagents, collects and reconciles their results, and keeps the human informed —
it does not write files, run device commands, or do the analysis itself when a subagent could.
Every substantive piece of work (recon, research, doc-writing, scripting, review) is delegated.
Pick the model tier per task rather than running everything on the same model (see §4), and
parallelize subagents whenever their work is independent — different docs, different recon
phases that don't depend on each other's output. This exists because a single session doing
everything itself has no separation between "propose an action" and "review whether the
action was safe," which is exactly the check that catches a bad idea before it reaches the
device.

**Hardware safety (hard constraints — never violate).** Never run an erase or write operation
against the device's flash. Never touch efuses. Never make secure-boot changes. Never blindly
enter a download/bootloader mode without a specific, understood reason and the human's
go-ahead. Never short pads or pins to probe behavior. Never apply a higher voltage than a
signal is rated for (e.g. 5V on a 3.3V-rated line). Never overwrite NVS, a partition, or the
bootloader until a verified backup **and** a tested recovery path both exist — this is an AND,
not an OR: a backup you haven't proven you can restore from is not a safety net. Where the
device already has protections (secure boot, flash encryption, read-out protection), document
them — never attempt to defeat or bypass them; understanding a lock is in scope, picking it is
not. Exit any download-mode/bootloader session by fully power-cycling the device (unplug and
reconnect, or the device's own power button) rather than a single MCU's reset line alone — on
a multi-MCU board, resetting one MCU can leave a companion MCU or a display controller
un-reset, which shows up later as display artifacts, wrong contrast, or unresponsive input
that has nothing to do with the firmware you just flashed and everything to do with a stale
peripheral state. See `references/rule-rationale.md` for the concrete failure each of these
prevents.

**Evidence standard.** Every hardware claim gets one of four labels, stated next to the claim:
- **CONFIRMED** — directly observed or verified (a legible silkscreen, a working command's
  actual output, a byte-for-byte-matched dump).
- **STRONGLY INDICATED** — strong circumstantial evidence, not directly verified (matches a
  known reference design closely; behavior consistent with only one likely cause).
- **POSSIBLE** — plausible, weakly supported.
- **UNKNOWN** — not legible, or not yet determined.

Never hallucinate a chip marking, part number, register value, or silkscreen text. If it is
not clearly legible in a photo or capture, it is UNKNOWN — say so, and say what would resolve
it. A claim is only promoted from one label to a stronger one when new, stated evidence
supports the promotion; it never just gets more confident with repetition.

**Human-performed physical actions, one at a time.** The human performs all physical actions
on the device — connecting cables, pressing buttons, probing test points, soldering. An
assistant proposes exactly one small, reversible-where-possible experiment at a time and
states what it expects to observe; it never proposes a batch of actions, and never an
irreversible or ambiguous one, without the human stopping to confirm first. Before anything
uncertain or device-state-changing: stop and ask, don't proceed on assumption.

**Sensitive data.** Never commit to git: firmware/NVS/filesystem dumps, credentials of any
kind, or network configuration extracted from the device (SSIDs, passwords, tokens, MACs).
These belong, if kept at all, in a gitignored backups directory. Run any serial or USB capture
through a redaction pass before staging it, and grep the result — never blindly `git add -A`
a captures directory. If a secret does slip into a commit, redacting the working tree is not
enough; it is still in git history and needs a history rewrite (`git filter-repo`, not
`filter-branch`) before the repo is shared with anyone, with every clone-holder told before a
force-push.

**Document as you go.** Write discoveries to the relevant doc immediately, not saved up for
the end of a session — a session that ends abruptly (crash, context limit, human interrupt)
should not cost the findings that happened in it. Every research action gets one entry
appended to a running research log in a fixed shape (DATE/TIME, PHASE, ACTION, COMMAND,
RESULT, INTERPRETATION, CONFIDENCE, NEXT STEP) — see
`${CLAUDE_PLUGIN_ROOT}/templates/research-log-entry.md`. A decision that changes course later
gets its own new decision record rather than an edit to the old one — see
`${CLAUDE_PLUGIN_ROOT}/templates/decision-record.md` — so the reasoning trail stays intact
even after the conclusion changes.

**Immutable original evidence.** Original photographs (and any other primary capture of the
device's as-found state) are permanent evidence: never edit, move, rename, recompress, or
delete them, and never point any command's output at that directory. Verify their integrity
before relying on them with a checked hash manifest, e.g.:

```
shasum -a 256 -c photos/analysis/ORIGINALS.sha256
```

Derived or annotated images go in a separate `analysis/` directory, never mixed into
`original/`.

**Directory layout.** Fix a project layout before work fans out across subagents, so
concurrent agents don't collide on where things go and safety rules can be enforced by path
rather than by vigilance — e.g. a command whose output path would land under an
`original/` evidence directory is a bug, not a judgement call. A layout that has worked:

```
<REPO>/
  docs/                 findings, plans, specs, decisions, research log
  photos/original/       immutable source photos -- never edit
  photos/analysis/        derived images, ORIGINALS.sha256
  backups/original/       raw dumps (gitignored)
  captures/usb/            USB enumeration/descriptor captures
  captures/serial/          UART/serial logs
  captures/logic/            logic analyzer captures
  firmware/<mcu>/              per-MCU firmware source
  firmware/common/               shared firmware code
  host/                          host-side companion app/tools
  scripts/                      repo-wide automation
  tests/                       automated tests
  notes/                      scratch notes -- non-authoritative
```

## 4. Choosing the model tier per task

| Tier | Use for | Examples from a real run |
|---|---|---|
| Cheap/mechanical | Fast, low-judgment, high-volume work | File listing, grep sweeps across captures, formatting a doc, a redaction check before staging |
| Implementation | Writing code, moderate research, running tests | Protocol client code, a packaging script, a host-tool CLI command, writing up a phase's findings |
| Design + adversarial verify | Architecture calls, hard debugging, anything that will gate a physical action | Choosing the least-invasive mod architecture, root-causing a bricked-looking symptom, verifying another agent's CONFIRMED claim before it's acted on |

Pass the model explicitly on every subagent dispatch — never let a subagent inherit the
top-tier model by default, and never run subagents on whatever model happens to be running
the moderator session itself.

## 5. Anti-patterns actually observed

- **Proposing a batch of irreversible actions at once** — e.g. "let's hold this button, then
  short that pad, then flash this" as a single plan. Real sessions on this project rejected
  exactly this shape of plan (holding an unidentified button at power-on, on the reasoning
  that it *might* trigger a useful mode) because an unknown action taken before a backup
  exists can just as easily trigger a factory-reset or erase path baked into the vendor's own
  firmware. One step, one observation, then decide the next step.
- **Promoting a claim to CONFIRMED without the observation that supports it** — e.g. reading a
  part number off a blurry photo of black-on-black silkscreen, or asserting a GPIO mapping
  from a reference design without having actually read it back off the real device. If the
  evidence is "it's probably fine because similar boards do it this way," the correct label is
  STRONGLY INDICATED or POSSIBLE, not CONFIRMED — and the doc says so.
- **Holding findings in context until end of session instead of writing them down** — the
  session that skips this loses everything not yet written the moment it ends unexpectedly,
  and worse, a later session (or a different subagent) re-derives already-answered questions
  because nothing durable recorded the answer.
- **Treating "I made a backup" as satisfying the safety gate** — a backup that has never been
  test-restored is not a verified recovery path; D-003-style gates require both the backup and
  a rehearsed restore before any write-class action is authorized.

## References

- `references/rule-rationale.md` — one paragraph per hard rule, naming the concrete failure it
  prevents.
- `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md` — the fillable operating-rules template.
- `${CLAUDE_PLUGIN_ROOT}/templates/research-log-entry.md` — the fixed-shape log entry.
- `${CLAUDE_PLUGIN_ROOT}/templates/decision-record.md` — the ADR-style decision template.
