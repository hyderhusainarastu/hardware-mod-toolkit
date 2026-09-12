# Audit categories -- full scan recipes

Each recipe below is written to run over **both** the tracked working tree and the full git
history (`git log -p`, `git log --all`) unless noted otherwise -- a value absent from `HEAD` can
still be sitting in an earlier commit, which a working-tree-only grep will never find. Adapt the
bracketed patterns to your project's actual identifiers before running these; run them again,
unmodified, as the re-check step after building the export.

Every scan should be run by an agent (or person) that does not already know what it's supposed to
find -- state the categories, not the expected answers, or the scan degenerates into confirming
what the builder already believed was clean.

## a. Secrets and PII

```bash
# Tracked files
git ls-files -z | xargs -0 grep -InE \
  '<ssid-pattern>|([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}|[0-9a-fA-F]{12}\b|<owner-name>|<owner-username>|/Users/[A-Za-z0-9_.-]+|/home/[A-Za-z0-9_.-]+|<device-serial-pattern>|<host-serial-pattern>|\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'

# Full history (author/committer identity, and content of every diff ever committed)
git log --all --format='%an|%ae|%cn|%ce' | sort -u
git log -p --all | grep -InE '<ssid-pattern>|<owner-name>|<owner-username>|<serial-pattern>'

# Session/run URLs a tool may have written into commit messages
git log --all --format='%B' | grep -inE 'session[_-][a-z0-9]{6,}|https?://[a-z0-9.-]+/(code|session)/'
```

For each hit, before recording it as a finding, read the surrounding sentence: is the string
itself the leaked value, or is it prose *describing* a past incident ("an SSID was briefly
committed in `<sha>` and later redacted")? Only the former is a finding requiring action; the
latter is a legitimate, honest incident note and should usually survive into the public docs
(with the actual value still checked -- confirm it isn't quoted verbatim inside the description
itself).

## b. Tooling and process mentions

```bash
git ls-files -z | xargs -0 grep -InE \
  '<assistant-name>|<vendor-of-assistant>|\bagent\b|\bsubagent\b|\bmoderator\b|\borchestrat|\bworkflow\b|\bsession\b|\bhook\b|\.claude|<internal-tool-config-dir>' \
  | sort
```

Run with `-c` (counts per file) first to see scale, then per-file to classify. For every file with
hits, decide DROP / REWRITE / CLEAN (see SKILL.md section 1b). For a process-specific feature you
decide to drop entirely, build its full dangling-reference list before deleting anything:

```bash
# example: find every file that references a feature named <FEATURE>
git grep -ln '<FEATURE>' -- . | sort
```

Walk that list and confirm each reference is either deleted or updated (a test that exercised the
feature, a CLI subcommand's help text, a config manifest entry, a README line) so the export
doesn't ship a broken import, a failing test, or documentation for a command that no longer
exists.

## c. Vendor intellectual property and legal exposure

```bash
# Binaries and archives that shouldn't be under version control
git ls-files -z | xargs -0 file | grep -iE 'executable|ELF|Mach-O|PE32|archive'

# Anything explicitly named after the vendor's own release artifacts
git ls-files | grep -iE '\.(bin|img|elf|tar)$'

# Long verbatim vendor text (heuristic: look for suspiciously long unbroken quoted blocks
# in docs near words like "vendor", "datasheet", "manual")
git ls-files -z -- '*.md' | xargs -0 grep -ilE '<vendor-name>' 
```

Read every hit's surrounding context and classify: is this a fact derived by observing the
device's behavior (safe to keep, framed as an interoperability specification with decoded
meanings, or `UNKNOWN` where undetermined), or is it the vendor's own binary, source, or verbatim
documentation text (must not ship, at most a short attributed quotation)? Also confirm:

```bash
# .gitignore actually excludes the directories meant to hold vendor dumps / backups
git check-ignore -v <backups-dir>/ <dumps-dir>/
git ls-files <backups-dir>/    # must be empty
```

Check third-party code licenses for compatibility with the license you intend to publish under
(a vendored GPL component under an MIT project is a real conflict, not a formality), and check
whether any packaging/build script embeds a vendor archive directly rather than requiring the
user to supply their own copy of firmware they already legitimately own.

## d. Media size and metadata

```bash
# Size per top-level media directory, and the largest tracked files overall
du -sh <media-dir>/*/ 2>/dev/null
git ls-files -z | xargs -0 du -h 2>/dev/null | sort -rh | head -30

# Total tracked size and file count
git ls-files -z | xargs -0 du -ch 2>/dev/null | tail -1
git ls-files | wc -l

# EXIF on every JPEG -- prefer exiftool if present; Pillow or macOS sips/mdls as fallbacks
exiftool -GPSLatitude -GPSLongitude -SerialNumber -Artist -Make -Model <file> 2>/dev/null
# or, without exiftool:
python3 -c "from PIL import Image; from PIL.ExifTags import TAGS; im=Image.open('<file>'); \
print({TAGS.get(k,k): v for k, v in (im._getexif() or {}).items()})"
```

Flag anything over your git host's per-file limit (commonly 100 MB) and anything that would push
the total repo size past a size you're comfortable with new contributors cloning. Flag any GPS
tag, device serial, or personal name found in EXIF on an image you're considering publishing.

## e. Document triage

There's no grep for this one -- it's a read. Walk every document a newcomer would encounter (a
top-level README, everything under a docs directory, every top-level markdown file) and sort each
into KEEP / REWRITE / DROP per SKILL.md section 1e. Produce a table: `file -> verdict -> (for
REWRITE/DROP) which CONFIRMED facts must be migrated and to which surviving document`. Do not mark
a document DROP until every fact it's carrying that matters to a replicator has a confirmed
destination.

## f. Fresh-clone portability

```bash
# Absolute paths anywhere in tracked files
git ls-files -z | xargs -0 grep -InE '/Users/[A-Za-z0-9_.-]+|/home/[A-Za-z0-9_.-]+'

# Hardcoded toolchain paths that should instead read an env var with a documented default
grep -rnE '<toolchain-name>_PATH\s*=\s*"?/(Users|home)' <scripts-dir>/ <docs-dir>/

# Untracked-but-required build inputs (compare what a script expects to exist vs. what's tracked)
grep -rn '<required-input-filename>' <scripts-dir>/
git ls-files | grep '<required-input-filename>'   # if this is empty and the grep above isn't, flag it

# Missing license
test -f LICENSE || echo "MISSING LICENSE"

# Tests reading the developer's own machine state instead of a fixture
grep -rnE '\$HOME/\.|~/\.[a-z]' <tests-dir>/
```

The bar for this category is behavioral, not just grep-clean: actually try a fresh clone (or a
freshly created empty directory with only the exported tree copied in, no lingering environment
from the machine that built it) and follow the README with no additional context. Anywhere that
fails or requires an undocumented step is a finding.
