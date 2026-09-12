# Redaction rules -- starter table

Copy this table into your own project's audit output and fill in the bracketed patterns with
your actual identifiers. Keep the numbering (`R1`, `R2`, ...) so every rule is independently
citable and independently re-greppable after the export is built -- the pass condition for each
rule is "grep for the pattern side across the export tree, get zero hits."

Apply every rule with `sed`/`python3` across the whole export tree in one pass per rule, never by
hand file-by-file:

```bash
grep -rl '<pattern>' <EXPORT_DIR> | xargs sed -i '' 's#<pattern>#<replacement>#g'
```

(On Linux, drop the empty `''` after `-i`; on macOS/BSD `sed`, the empty string argument is
required.)

| Rule | Pattern | Replacement | Notes |
|------|---------|-------------|-------|
| R1 | `<owner-name>` (full name) and `<owner-username>` (any handle/username used in commits, comments, or file paths) | omit entirely, or `<maintainer>` where a role noun is grammatically needed | Check commit trailers, code comments, and any generated file header separately -- a template that stamps an author name into new files needs its default changed too, not just existing instances. |
| R2 | `/Users/<owner-username>/...` or `/home/<owner-username>/...` (absolute home path, any suffix) | `<repo-root>` (if the path was pointing at something inside the project) or delete the line (if it was a personal, project-external path) | Use a greedy match up to the next whitespace or quote so the whole path is caught, not just the username segment. |
| R3 | Device serial number(s), in whatever exact format the device/vendor uses | `<DEVICE-SERIAL-REDACTED>` | If the format itself is useful documentation (e.g. "serials look like `PREFIX` + 6 hex digits"), state the *format* once in prose and redact only the *specific* value everywhere it appears. |
| R4 | MAC addresses, both colon and bare-hex notation: `([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}` and `[0-9a-fA-F]{12}` | `XX:XX:XX:XX:XX:XX` | Bare 12-hex is a wide pattern -- verify each hit is actually a MAC before replacing (false positives on hashes/hex dumps are common; don't run this one fully automated without a spot-check). |
| R5 | Host/workstation serial number, hostname, or machine name | `<HOST-REDACTED>` | Includes anything derived from it, e.g. a USB device node name that embeds the host's identity rather than the peripheral's. |
| R6 | Wi-Fi SSID(s) and any password/PSK value | delete the line, or `<SSID-REDACTED>` for the network name if the fact that Wi-Fi was involved is itself worth keeping in a log | Never replace a password with a placeholder that looks like a real value format -- delete it outright. |
| R7 | Internal tool/process vocabulary specific to how the private project was actually built (assistant name, orchestration/session terminology, an internal safety-rules filename) | neutral engineering wording (`maintainer`, `manual step`, a renamed public safety doc) | This is the rule most likely to need per-sentence human judgment rather than pure `sed` -- a mechanical find-replace can produce grammatically broken sentences; review each substitution site. |
| R8 | Session/run URLs and commit trailers pointing at the tooling that built the project (e.g. `Co-Authored-By:` lines naming an internal tool, `.../session/...` URLs) | remove the trailer/line entirely | If you're building a fresh single-commit history per SKILL.md section 5, this rule is usually moot for the *export's* history (there is none to carry the trailer) -- but still check any URL or trailer that made it into file *content* (a doc that pastes a commit message verbatim, for instance). |

Add project-specific rules past R8 as the audit surfaces them (a particular internal codename, a
specific partner's name, a location). Keep every added rule in this same `pattern -> replacement`
form so the independent verifier (SKILL.md section 7) can mechanically check each one.

Two rules to *not* add, even though they look similar in shape to the ones above:

- **Do not rename the project's own public identifiers** (its CLI command name, its
  `<PROJECT>_`-prefixed config symbols, its repository name) via this mechanism just because
  they're distinctive strings. Those are the project's identity, not a leak, and a blanket
  find-replace across a real codebase is how working code quietly breaks.
- **Do not "redact" a value that's already public** (a vendor's own published product name, a
  public standard's name). Redaction is for private data; over-applying it to public facts makes
  the documentation harder to read for no security benefit.
