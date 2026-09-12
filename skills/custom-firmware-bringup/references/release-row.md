# Per-release record

Keep one row per built-and-packaged firmware image, in a single running table (`docs/releases.md`
or equivalent), oldest first. The point of the table is that "which build is on the device right
now, and what does it do differently from the last one" is a lookup, not a reconstruction from
git log and memory. Fill in every field every time — an empty field is a question the next reader
has to re-answer from scratch.

## Fields

| Field | What goes here |
|---|---|
| Version | The build's own version string (`CONFIG_APP_PROJECT_VER` or equivalent) and date. |
| Image | Path to the built binary, its size, and (if relevant) how much of its target partition/slot is free. |
| Package | Path to the packaged update artifact (tar, zip, vendor container format) actually meant to be staged on the device. |
| Package hash | sha256 (or equivalent) of the whole package artifact. |
| Member hashes | sha256 of each member inside the package individually — catches a corrupt or stale member even when the outer archive hash alone would not tell you which member changed. |
| Build command | The exact command(s) run, including any stale-config cleanup step. Copy-pasteable, not paraphrased. |
| Tests run | Which test suites ran (protocol/container unit tests, fuzz tests, host-side integration tests) and their pass/fail result — against the packaged artifact, not only the source build. |
| First-boot result | CONFIRMED/owner-performed once an actual install has happened, with what was observed; "not yet performed" is a valid, honest value before that happens — never leave it implying a test that didn't happen. |
| Changes vs. previous | What changed and why, in enough detail that a reader who only has this row (not the full diff) understands the change's shape and its risk. |
| Notes | Anything that doesn't fit the above: what was deliberately NOT done and why, protected-config-gate verification, caveats on evidence grade. |

## Worked example (generic device, illustrative shape only)

| | |
|---|---|
| Version | `<PROJECT> 0.1.9` — 2026-09-03 |
| Image | `build/<project>.bin`, 416,976 B, 87% of the OTA slot free |
| Package | `<UPDATE_PATH>/<PROJECT>.tar` (two-member: firmware image + unchanged stock assets) |
| Package hash | `sha256:...` |
| Member hashes | firmware image `sha256:...`; assets member `sha256:...` (unchanged from stock, MATCH) |
| Build command | `rm -f sdkconfig && idf.py set-target <SOC_FAMILY> && idf.py build` (stale sdkconfig from the previous release removed first — same gotcha every release since has documented) |
| Tests run | protocol unit tests (18 checks incl. a 1M-iteration fuzz run) and container tests — ALL PASSED; host-side test suite — 133 tests, OK |
| First-boot result | CONFIRMED, owner-performed: self-test rendered fully for the first time; image shifted a fixed number of rows, traced to an uncleared display-origin register (see the matching incident report) |
| Changes vs. previous | Added the vendor's missing post-first-frame display-enable step (see §4 of `SKILL.md`) |
| Notes | Protected config gates confirmed unchanged by direct grep of the regenerated config post-build. Root-cause and fix for the remaining row-shift defect deferred to the next release, tracked in a separate incident report rather than folded into this row silently. |

## Why hash members, not just the package

An outer archive hash tells you the *bag* is identical to a known-good one. A per-member hash
tells you *which* member changed when it isn't — the difference between "this exact package was
staged before" and "the firmware image inside changed but the assets member happens to still
match stock," which matters when you're comparing a suspect install against a table of known-good
rows during a debugging session, not just verifying integrity at download time.
