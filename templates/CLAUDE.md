<!--
HOW TO USE THIS TEMPLATE
1. Copy this file to the root of your hardware-mod project as CLAUDE.md.
2. Replace every <PLACEHOLDER> (device name, MCU names, repo name, paths) with your project's
   real values. Angle-bracket placeholders are used consistently across this toolkit:
   <DEVICE>, <VENDOR>, <MCU>, <MCU2>, <SOC_FAMILY>, <PANEL>, <REPO>, <PROJECT>.
3. Delete any section (or sub-bullet) that does not apply to your device — e.g. if there is
   only one MCU, drop every <MCU2> reference and the two-firmware-tree layout in §8.
4. This file is meant to be read in full by an AI assistant before it does anything in the
   repo. Keep it short enough that "read this fully first" is a realistic instruction — this
   template is the ceiling, not a floor to pad out.
-->

# CLAUDE.md — Operating rules for AI assistants in this repo

This file governs any AI assistant (Claude or otherwise) working in `<REPO>`. It is a hardware
reverse-engineering / modding project on a single, often irreplaceable physical device. Read
this fully before doing anything.

## 1. Session structure: moderator + delegated subagents

- The main/top-level session acts **only as a moderator**. It does not do the work itself.
- All actual work (recon, research, doc-writing, analysis, scripting) is delegated to
  subagents running on capable models — dispatched via whatever multi-agent workflow
  mechanism your tooling provides (this toolkit assumes Claude Code's dynamic workflows).
- Work should be **parallelized** across subagents wherever tasks are independent (e.g.,
  different docs, different phases of recon that don't depend on each other's output).
- The moderator's job is to plan, dispatch, collect results, resolve conflicts between
  concurrently-written files, and keep the human informed — not to write files or run
  device commands directly when a subagent could.

## 2. Hardware safety rules (hard constraints — never violate)

<!-- Adjust this list to your device's actual risk surface. The shape (irreversible ops
     named explicitly, physical actions reserved for the human, an exit procedure) is the
     part worth keeping; the specifics are device-dependent. -->

- **Never** run flashing-tool erase or write operations against the device without an
  explicit, current go-ahead.
- **Never** touch efuses / OTP fields.
- **Never** make secure-boot or flash-encryption changes.
- **Never** blindly enter a bootloader/download/DFU mode without a specific, understood
  reason and the user's go-ahead.
- **Never** short pads/pins to probe behavior.
- **Never** apply a voltage rail to a signal not rated for it (e.g. 5V onto a 3.3V line).
- **Never** overwrite NVS, a partition, or the bootloader until a verified backup **and** a
  tested recovery path both exist.
- Where the device has protections (secure boot, flash encryption, read protection, etc.),
  **document them** — never attempt to defeat or bypass them.
- If any action needs physical access to the board (soldering, probing, connecting a
  programmer, pressing buttons in a specific sequence), that action is performed by
  **the user**, not automated by an assistant.
- Document the correct exit/reset procedure after any low-level session (e.g. "unplug and
  full power-cycle, don't rely on a single reset line") — a wrong exit procedure can leave
  a companion MCU or a display controller in a bad state. State the *observed* failure mode
  if you've seen one, not a guess.

## 3. Evidence standard

Every hardware claim gets one of these labels, with the evidence stated:

- **CONFIRMED** — directly observed/verified.
- **STRONGLY INDICATED** — strong circumstantial evidence, not directly verified.
- **POSSIBLE** — plausible, weakly supported.
- **UNKNOWN** — not legible / not yet determined.

Never hallucinate a chip marking, part number, or silkscreen text. If it isn't clearly
legible in a photo or capture, it is UNKNOWN — say so. See the `hardware-recon` skill and
`recon-findings.md` template for how this standard is applied to a findings document.

## 4. Physical actions are one-at-a-time, human-performed

- The user performs all physical actions on the device (connecting cables, pressing buttons,
  probing test points, etc.).
- Only **one small experiment** is proposed at a time — never a batch of irreversible or
  ambiguous actions.
- Before anything irreversible, uncertain, or device-state-changing: **STOP and ask** the
  user first. Do not proceed on assumption.

## 5. Never commit sensitive data

Never commit to git:
- Firmware dumps, NVS dumps, filesystem dumps
- Credentials of any kind
- Wi-Fi SSIDs/passwords or other network configuration extracted from the device
- Device serial numbers, MAC addresses, or other identifiers unique to the physical unit

These belong (if kept at all) under a gitignored backups directory — see
`publication-checklist.md` for the full pre-publish audit. Capture files (serial/USB logs)
can carry identifiers incidentally: run them through a redaction pass and grep before
`git add`; never bulk-add a captures directory blindly.

## 6. Document as you go

- Write discoveries to the relevant doc under `docs/` **immediately**, not at the end of a
  session.
- Every research action gets an entry appended to `docs/research-log.md` in the standard
  8-field format — see `research-log-entry.md`.

## 7. Original evidence is immutable

- Everything under `photos/original/` (or your project's equivalent immutable-evidence
  directory) is permanent evidence. Never edit, move, rename, recompress, or delete these
  files, and never pass a path under it as an output target of any command.
- Before relying on them, verify integrity against a checksum manifest, e.g.:

  ```
  shasum -a 256 -c photos/analysis/ORIGINALS.sha256
  ```

- Derived/annotated images go in a separate `analysis/` directory, never in `original/`.

## 8. Directory layout

<!-- Delete the <MCU2> firmware tree if your device has only one MCU. -->

```
<REPO>/
  docs/                    Findings, plans, specs
  photos/original/         Immutable source photos — never edit
  photos/analysis/         Derived images, ORIGINALS.sha256
  backups/original/        Raw dumps (gitignored)
  captures/usb/            USB enumeration/descriptor captures
  captures/serial/         UART/serial logs
  captures/logic/          Logic analyzer captures
  firmware/<MCU>/          Primary MCU firmware source
  firmware/<MCU2>/         Secondary MCU firmware source
  firmware/common/         Shared firmware code
  host/                    Host-side companion app / tools
  scripts/                 Repo-wide automation
  tests/                   Automated tests
  notes/                   Scratch notes (non-authoritative)
```

See `README.md` for project purpose, roadmap, and safety-rule details.
