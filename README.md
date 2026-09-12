# hardware-mod-toolkit

A Claude Code plugin for reverse-engineering and modifying a consumer embedded device
**without bricking it** — and for publishing what you learned afterwards without leaking
your home directory, your Wi-Fi SSID, or a vendor's firmware.

It is the process, extracted. Eleven skills, five subagents, six dynamic workflows, eight
document templates and six host scripts, each written from a project that actually ran end
to end on one irreplaceable physical unit: photographic recon of a sealed board, passive USB
and serial capture, static firmware analysis, a verified read-only flash backup with a tested
restore path, custom firmware installed through the vendor's own updater, a framed host
protocol, a companion dashboard, and a curated public release.

None of it is device-specific. Every document is placeholder-driven (`<DEVICE>`, `<MCU>`,
`<PANEL>`, `<REPO>`), and the concrete details are kept as *worked examples* — a real failure
with a real mechanism — rather than as generic advice you have read before.

## What this is actually for

The hard part of a hardware mod is not writing firmware. It is the sequencing: knowing what
you are allowed to do next, what evidence you need before you do it, and which single step is
the one that is unrecoverable. This toolkit encodes that sequencing as:

- **An operating model** — a session that delegates rather than executes, a four-level
  evidence standard (CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN), one physical
  experiment at a time, and hard constraints that are checked by scripts, not just written in
  prose.
- **A phase map** — [`docs/PLAYBOOK.md`](docs/PLAYBOOK.md), fourteen phases from "set the
  rules before you touch the device" to "publish it", each with a named skill, a gate you must
  satisfy before moving on, and the artifacts it leaves behind.
- **A pitfall catalogue** — [`docs/PITFALLS.md`](docs/PITFALLS.md), eleven failures that
  actually happened, with the mechanism behind each one. A panel that ACKs every byte and
  stays blank. A backup that was never test-restored. An SSID redacted in the working tree
  but still sitting in git history.

## Install

**As a plugin** (recommended — Claude Code reads `skills/`, `agents/` and `workflows/`
straight out of the checkout):

```
/plugin marketplace add <owner>/hardware-mod-toolkit
/plugin install hardware-mod-toolkit
```

Or point Claude Code at a local clone of this repo as a marketplace and install from there.

**As a project-local copy** (when you want the assets versioned alongside your own mod
project, and expect to edit them for your specific device):

```
git clone <this repo>
./scripts/install-local.sh --target /path/to/your/mod-project
```

That copies skills into `.claude/skills/`, agents into `.claude/agents/`, workflows into
`.claude/workflows/`, and the templates and reference docs into `docs/toolkit/`. Re-running it
never overwrites your edits unless you pass `--force`; `--dry-run` shows you the plan first.

**Then**, before anything else: copy [`templates/CLAUDE.md`](templates/CLAUDE.md) to your
project's `CLAUDE.md` and fill in every placeholder you already know. Leave the rest as
placeholders — a guessed-in part number that looks plausible is worse than a blank, because
later work will cite it as if it were established.

## Start here

1. Read [`docs/PLAYBOOK.md`](docs/PLAYBOOK.md) — at minimum its "If you only read one thing".
2. Invoke the `moderator-operating-model` skill and do Phase 0. Do not connect the device to
   anything until the safety rules are written down.
3. Work the phases in order the first time through.

## Asset catalogue

### Skills — `skills/<name>/SKILL.md`

| Skill | What it covers |
| --- | --- |
| `moderator-operating-model` | The rules you set before touching the device: delegation, model tiers, the four-level evidence standard, one-experiment-at-a-time, redaction, document-as-you-go, immutable original evidence. |
| `hardware-recon` | Identifying a PCB from photographs: hash-manifested originals, reading silkscreen and module markings without guessing, two independent analysts per photo, and how to grade what you can actually see. |
| `serial-and-usb-recon` | Watching a device enumerate and capturing its boot log without writing a byte to it — then redacting SSIDs, MACs and serials *before* the first capture reaches a commit. |
| `firmware-image-analysis` | Reading a vendor image statically: partition tables, image headers, signed/encrypted determination, string and log-format mining, subsystem mapping, and the few functions worth disassembling. |
| `mcu-safe-backup` | Read-only flash preservation: finding the download-mode window, two-pass hash-compared dumps, dry-run-by-default tooling that refuses write/erase/efuse arguments, and a recovery plan you have actually tested. |
| `stock-updater-packaging` | Installing custom firmware through the vendor's own updater instead of a programmer: deriving the updater's real acceptance rules, a staged install around the one unrecoverable write, and a rehearsal that proves byte-identity. |
| `custom-firmware-bringup` | The first-boot failures worth pre-empting: the display-enable command that is not in the init table, an uncleared scroll register, a stack too small for a frame buffer, a power GPIO racing the brownout detector, blocking I/O under a suspended scheduler. |
| `framed-serial-protocol` | A framed request/response link that survives garbage: CRC, sequence numbers, resync, and the difference between an informational NACK and a fatal one — plus exclusive port ownership, which is what actually breaks. |
| `device-companion-dashboard` | Driving a small 1-bpp panel usefully: the render-quantize-pack pipeline, dirty-rectangle refresh chosen by an explicit transaction-cost model, YAML widgets and presets, and one-shot notifications that coexist with a running loop. |
| `hardware-in-the-loop-testing` | Making the safety rules machine-enforced: a force-mock environment gate the transport itself honours, fake transports, static regression guards that fail on the source pattern behind a past crash, and shared host/firmware test vectors. |
| `publish-hygiene` | The audit and the curated export: six scan categories, severity grading, mechanical redaction rules, and an independent verification pass by an agent that did not build the export. |

### Subagents — `agents/<name>.md`

| Agent | Model | Role |
| --- | --- | --- |
| `hardware-recon-analyst` | opus | Reads board photographs and reports components, markings, connectors and pad groups, each with an explicit confidence grade. |
| `firmware-analyst` | opus | Analyses images, bootloaders and update archives statically — headers, partition tables, strings, log tags, updater acceptance rules. |
| `adversarial-verifier` | opus | Tries to *refute* a specific claim from primary evidence, and defaults to refuted when it cannot personally confirm the mechanism. |
| `hygiene-auditor` | sonnet | Read-only scan for anything that must not be published: secrets, personal data, absolute home paths, device identifiers, vendor binaries. |
| `release-packager` | sonnet | Builds, packages and records a firmware release — and never opens a port or flashes anything. |

### Workflows — `workflows/<name>.js`

Dynamic multi-agent workflow scripts. Run an installed one as
`/hardware-mod-toolkit:<name>`, or point the Workflow tool at the file directly.

| Workflow | Shape |
| --- | --- |
| `diagnose-verify-synthesize` | Map each side of a boundary independently, hypothesise, have two differently-lensed agents try to refute each hypothesis, then synthesize one diagnosis. |
| `implement-review-docs` | Implement against an explicit file-ownership boundary, review the diff with an agent that did not write it, apply only critical/major findings, and write docs *in parallel* with the review. |
| `firmware-release` | Analyse the observed defect from evidence, implement the traced fix, build and package, re-verify protected config and package byte-identity, then write an honest release row. |
| `publish-audit` | Six parallel scan categories over a private repo, severity-graded, synthesized into a nine-part publication plan. |
| `publish-export` | Build the curated export from that plan: fresh `git archive` base, plan-driven redaction, parallel doc rewrite, independent verification with a bounded fix loop, one gated commit. No remote, no push. |
| `diagrams-from-docs` | Plan, draw and fact-check a Mermaid/SVG diagram set from your own docs, preserving each fact's confidence label — for when photographs of your unit cannot be published. |

### Templates — `templates/`

`CLAUDE.md` (project operating rules) · `research-log-entry.md` (append-only log) ·
`decision-record.md` (immutable, with dated status updates) · `incident-report.md` (report →
code reading → graded root cause → fix → regression guard) · `recon-findings.md` ·
`protocol-spec.md` · `verification-matrix.md` (with the by-path / demonstrated / tested grade
distinction) · `publication-checklist.md`.

### Scripts — `scripts/`

| Script | What it does |
| --- | --- |
| `usb-watch.sh` | Passive, read-only USB attach/detach observation with a plain-words verdict. |
| `serial-listen.sh` | Captures a short-lived boot/console node, follows re-enumeration, and redacts before anything can be committed. |
| `mcu-backup-window.sh` | A read-only esptool session for an MCU that only exposes its download bridge briefly after reset. Dry-run by default; refuses write, erase and efuse arguments at two layers. |
| `make-update-tar.sh` | Builds a stock-format update package from a vendor release plus your own image. |
| `idf-env.sh` | Activates a pinned ESP-IDF toolchain for **building only** — never flashing. |
| `install-local.sh` | Project-local install of the assets above. |

## Safety

Every script here is read-only or host-only by default. `mcu-backup-window.sh` refuses
write/erase/efuse arguments at both the argument layer and the assembled-command layer.
`idf-env.sh` builds and does not flash. `release-packager` never opens a port. The
`hardware-in-the-loop-testing` skill exists specifically so that "never touch the device
automatically" is enforced by a transport-level gate rather than by a sentence in a prompt.

You are still the one holding the hardware. The single rule worth repeating: **a backup you
have not test-restored is not a backup**, and no write to the device is justified before both
halves of that exist.

## The worked example

This toolkit was extracted from a real mod of a distraction-free writing device — an
ESP32-class main MCU with a companion MCU, a 1-bpp panel, an SD-card stock updater, and a
custom protocol plus macOS host application built on top. That project is published separately
as **`byok-mod`** (<https://github.com/hyderhusainarastu/byok-mod>). Where a skill here says
"the worked example", that is the project it means, and the numbers quoted — a ~220 ms full
panel refresh, a ~4.24 s USB PHY hand-over window, sixteen firmware releases without a brick —
are measurements from it, not illustrations.

Nothing device-specific from that project is reproduced here: no vendor binaries, no vendor
text, no serial numbers, no MAC addresses, no photographs.

## Built with Claude Code

This is a Claude Code plugin, and the process it encodes was itself run through Claude Code —
a moderator session that delegated every substantive piece of work to subagents on explicitly
chosen model tiers, with adversarial verification before any finding was promoted. The
`moderator-operating-model` skill and the six workflow scripts are that arrangement, made
reusable. You do not need to work that way to use the skills, templates and scripts; if you do
want to, Phase 0 of the playbook sets it up.

## Licence

MIT — see [LICENSE](LICENSE).
