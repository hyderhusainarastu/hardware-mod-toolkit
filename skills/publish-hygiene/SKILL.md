---
name: publish-hygiene
description: Audit a private project before publishing it and build a curated public export -- scan for secrets, personal data, vendor intellectual property, oversized or EXIF-bearing media, process narrative, and fresh-clone portability; then export with fresh history, apply redaction rules, and verify independently before pushing. Use before open-sourcing any repository that touched real hardware, vendor firmware, or personal infrastructure.
---

# Publish hygiene

A private hardware project accumulates exactly the material that must never leave it: the
owner's Wi-Fi credentials in a boot log, a device's own serial number, absolute paths under
`/Users/<name>/`, a vendor's firmware dumped byte-for-byte, a narrative full of internal process
detail nobody outside the project needs. None of that is a reason not to publish -- it's a reason
to publish a **curated export**, not the repo itself.

The one fact this whole skill is built around: **redacting a secret in the working tree does not
remove it from history.** A real project's final publication audit found a Wi-Fi SSID string that
had been committed early on, then redacted in a later commit -- the working-tree file was clean,
but `git log -p` on the earlier commit still showed the SSID in plain text, and would keep showing
it in every future clone forever. Fixing that after the fact means a history rewrite, which is
disruptive to anyone who already has a clone. The fix that avoids the problem entirely is to never
publish the private repo's history at all: build a fresh export from a single point-in-time
snapshot, with one clean commit, and let the private repo (and its imperfect history) stay
private. That decision is the spine of section 3 below.

Do the audit (section 1) before you build anything. Do the export (sections 3-5) only from the
audit's output. Do the independent verification (section 7) after the export is built, by an
agent -- or a person -- who did not build it.

## 1. The six audit categories

Run each of these as an independent scan over **all tracked files and the full history**
(`git log -p`, `git log --all`, not just `git grep` on the working tree -- a secret can be absent
from HEAD and still sit in an earlier commit). Each category produces a list of findings, not a
pass/fail: `file`, `kind`, `detail`, `recommended action`, `severity` (section 2).

Full grep recipes for every category are in `references/audit-categories.md`. Summary:

**a. Secrets and PII.** Wi-Fi SSIDs and passwords, MAC addresses in both notations
(`xx:xx:xx:xx:xx:xx` and bare 12-hex), device and host serial numbers, USB serial strings,
a person's name/username/email, absolute paths under `/Users/` or `/home/`, machine names,
IP addresses, API tokens/keys, and any session/run URL a tool may have embedded in a commit
message or file. Watch for the trap in the other direction too: a document that **describes** a
past leak ("commit `abc123` briefly contained the office SSID before it was redacted") is not
itself a leak -- don't flag or scrub the description, flag the actual value if it's still
reachable in history.

**b. Tooling and process mentions.** If the public repo should read as engineering work rather
than a transcript of how it was produced, grep case-insensitively for the tool names, role words,
and process vocabulary specific to however the private project was actually run (assistant names,
agent/subagent/orchestration terms, internal workflow or session identifiers, hook script paths,
`.claude`-style config directories, and narrative phrases like "delegated to," "dispatched," or
"owner-approved, assistant-performed"). Classify every hit's file as:
- **DROP** -- the file exists only because of the process (a session-state note, an internal
  operating-rules file for the tool that ran the project);
- **REWRITE** -- real technical content wrapped in process language, strip the language and keep
  the content;
- **CLEAN** -- no action.

If the private tooling shipped an integration feature that is itself process-specific (a
dashboard widget that only makes sense with the private assistant setup, a build flag gated on an
internal tool's presence), decide up front whether to drop it or generalize it, and if dropping
it, walk every file that references it -- code, tests, docs, manifests, CLI help text -- so the
export doesn't ship a dangling import or a test asserting a feature that no longer exists.

**c. Vendor intellectual property and legal exposure.** Vendor firmware binaries, raw dumps,
partition images, disassembly listings, decompiled code, verbatim vendor source or documentation
text beyond short attributed quotation, copied assets (fonts, bitmaps, icons pulled from the
vendor's own firmware), and long quoted vendor log strings. The recurring judgment call: a table
of register values or an init sequence **read from** vendor firmware is a fact about how the
hardware works, and facts and interfaces are not copyrightable -- but the same table presented as
"here is the vendor's byte blob, copied" invites exactly the objection that presenting it as
"here is the interoperability specification we determined, with each value's decoded meaning (or
`UNKNOWN` where undetermined)" avoids. Same content, different framing, very different legal
posture. Also check: does any packaging or build script embed a vendor archive directly, when it
could instead require the *user* to supply their own copy of the vendor firmware they already
own (a `--stock-from <path>` flag, erroring cleanly with instructions if it's missing, rather than
finding a vendor `.tar` sitting in the repo)? And separately: third-party code license
compatibility (anything GPL, Apache-2.0, MIT that's vendored in), and trademark handling -- naming
the device or vendor by name is normally fine as nominative use ("interoperates with the
`<DEVICE>` sold by `<VENDOR>`") with a disclaimer that the project is unaffiliated; treat vendor
company statements and marketing claims as off-limits to reproduce.

**d. Media size and metadata.** Per-directory and per-file size, total repo size, and file count
(a git host will hard-reject files over its per-file limit and will make every future clone slow
past a certain total size). For every photo: EXIF metadata (`exiftool`, or `python3` with
Pillow, or macOS `sips`/`mdls`) for GPS coordinates, the capturing device's serial number, and the
owner's name if the camera/software wrote one in. Three real options, in order of how much the
public repo commits to carrying media at all: (1) drop photos entirely and replace them with
diagrams generated from the photos' *findings* (a block diagram, a pinout diagram, a protocol
frame diagram) -- diagrams carry no EXIF and no size problem and are often clearer to a reader
than a phone photo of a PCB; (2) keep a curated, EXIF-stripped, resized subset with a documented
target (dimensions, quality, byte budget) and keep the sha256 manifest of the *originals* as
provenance without publishing the originals themselves; (3) publish the full original set as a
release asset (not tracked in git) if the originals genuinely matter to a reader. Never publish an
EXIF-bearing original as a repository asset by accident -- strip metadata as a build step, not as
a one-time manual pass someone might forget to repeat.

**e. Document triage: KEEP / REWRITE / DROP.** Read every document a public reader who wants to
replicate and modify the project would encounter, and sort it:
- **KEEP AS IS** -- already a clean technical reference (a protocol spec, a pinout table).
- **REWRITE** -- technical content wrapped in project-management or session narrative (a
  phase-by-phase roadmap, a decision log with internal timestamps, an incident log written as
  "session notes"). Rewrite it into a technical document with the narrative stripped, and --
  this is the hard rule, not optional -- **migrate every fact graded `CONFIRMED` in the dropped or
  rewritten document into a document that survives**, before deleting the source. A project
  management roadmap ("Phase 5: display identification -- DONE") that gets deleted wholesale
  without first pulling its one CONFIRMED technical claim (the panel's controller family, say)
  into `docs/hardware.md` is how real findings quietly disappear at publish time.
- **DROP** -- pure session state, internal tool operating rules, scratch notes with nothing a
  reader needs. Only after its facts have been migrated per the rule above.

Also check whether the top-level structure itself reads as a project-management artifact (a
numbered phase roadmap as the README's spine) rather than an architecture-first structure a
newcomer can navigate (hardware architecture -> buses/protocol -> firmware -> host tools ->
sample projects). If so, that's a REWRITE finding on the README too, and its replacement table of
contents is worth writing out explicitly as part of this audit's output so the later doc-rewrite
work has a target to write to.

**f. Fresh-clone portability.** Everything that would stop a stranger, on a machine that has
never seen this project, from building and using it: absolute paths anywhere in scripts, docs, or
config (`grep -rn '/Users/\|/home/'`); machine-specific environment assumptions (a toolchain path
hardcoded instead of using an environment variable with a sane default); files the build depends
on that are gitignored and never shipped (a vendor archive a packaging script expects to find,
a large binary asset, a locally-built helper); a missing `LICENSE`; tests that read the actual
developer's home directory or a personal cache path instead of a fixture; and undocumented
toolchain version pins (say the exact SDK/compiler version that was actually used to build,
not just "recent"). The bar is: `git clone`, follow the README with no other context, and reach a
working build.

## 2. Severity levels

Tag every finding with one of four severities so the moderator can triage without re-reading the
raw scan output:

- **BLOCKER** -- illegal or flatly forbidden to publish (a vendor binary, a live credential, a
  literal secret still reachable in history). Publication does not happen until every BLOCKER is
  resolved.
- **HIGH** -- violates an explicit owner requirement (no mention of the tool that built this, no
  personal data of any kind, no vendor text). Also gates publication.
- **MEDIUM** -- should be fixed for quality/credibility but isn't a hard blocker (an
  under-explained architecture doc, an inconsistent naming convention).
- **LOW** -- nice to have (a diagram that would help but isn't essential, a typo).

## 3. Build the export with fresh history -- never edit or copy the private repo

Do not `cp -r` or `rsync` the private project directory into the export location. That drags in
`.git` (the entire history you're trying to leave behind), gitignored backup directories, build
output, and anything else sitting in the working tree that was never meant to be tracked at all.
Instead, snapshot exactly what git tracks, at exactly one point in time, with no history:

```bash
mkdir -p <EXPORT_DIR>
cd <PRIVATE_REPO> && git archive HEAD | tar -x -C <EXPORT_DIR>
```

This gives you the tracked-file tree with zero git history, zero gitignored files, and zero
build artifacts -- a clean base to edit. From here, in order:

1. **Apply the DROP list** from the audit's document-triage and tooling-mentions findings: delete
   files that exist only for private-tooling or process reasons, any internal operating-rules
   file (rename its human-relevant safety content into a public `SAFETY.md` first if any of it is
   worth keeping -- see the templates directory), scratch notes, and anything the media audit
   said not to ship.
2. **Apply mechanical redactions** (section 4) across whatever remains -- usernames, home paths,
   serials, MACs, tool/process vocabulary -- with `sed`/`python3`, not by hand file-by-file.
3. **Rewrite documents** per the triage's REWRITE list, migrating every surviving `CONFIRMED` fact
   before you delete its source document.
4. **Re-run the entire audit checklist from section 1 over the export**, not the private repo.
   Code and script hits should be zero; doc-prose hits are expected mid-process but must also
   reach zero before the export is done.

Only after all four steps pass does the export get a single commit and, eventually, a remote --
see section 5.

## 4. Redaction rules -- a numbered, re-greppable list

Write every mechanical substitution as a numbered rule, `pattern -> replacement`, before running
any of them. Numbering them (R1, R2, ...) makes each one independently auditable: you can point at
"R4 turned every MAC address into `XX:XX:XX:XX:XX:XX`" instead of "we redacted some stuff." A
starter set with generic placeholders is in `references/redaction-rules.md` -- copy it, fill in
your project's actual patterns, and keep the list next to the export so the independent verifier
in section 7 can check each rule was actually applied (re-grep for the *pattern* side of every
rule after the export is built -- zero hits is the pass condition).

Apply rules with `sed -i` or a small `python3` script, never by hand -- hand-editing means the
next file with the same pattern gets missed. Example shape (fill in your own project's strings):

```bash
# R2: absolute home path -> relative marker
grep -rl '/Users/<owner>/' <EXPORT_DIR> | xargs sed -i '' 's#/Users/<owner>/[^ "'"'"']*#<repo-root>#g'

# R4: MAC addresses -> placeholder form (keep the placeholder recognizable as a placeholder)
grep -rlE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' <EXPORT_DIR> | \
  xargs sed -i '' -E 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/XX:XX:XX:XX:XX:XX/g'
```

Do not apply a rename rule to a project's own product/code identifiers (its CLI name, its
`<PROJECT>_`-prefixed config symbols) just because they're distinctive -- those aren't secrets,
they're the project's public identity, and renaming them mid-codebase is a needless, error-prone
transformation. Reserve redaction rules for things that are actually private: people, places,
specific device instances, and the tooling that built the project.

## 5. Fresh history, one commit

Once the export tree passes every re-run check in section 3 step 4:

```bash
cd <EXPORT_DIR>
git init -b main
git config user.name "<chosen public identity>"
git config user.email "<chosen public identity email, or omit if the host allows>"
git add -A
git commit -m "<one clean, descriptive message>"   # no trailers of any kind
```

Before treating this as done, verify it directly rather than assuming the commands above did
what you intended:

```bash
git log --format="%an %ae %B"          # only the chosen identity and message appear
git status --porcelain | wc -l          # 0 -- nothing left uncommitted
git ls-files | wc -l                    # sanity-check against the expected tracked-file count
git ls-files | xargs du -ch | tail -1   # total size
git ls-files | grep -iE '<forbidden-pattern-1>|<forbidden-pattern-2>'   # empty
```

This single-commit, chosen-identity, no-trailers approach is what eliminates historical secrets
and any tool-attribution trailers (a real `Co-Authored-By:` line pointing at the private
project's tooling, or a session URL) *without* needing `git filter-repo` or any other
history-rewriting tool -- because there is no history to rewrite. The private repo's real history,
warts included, simply never leaves the private repo. Do not add a remote or push until section 7
has passed.

## 6. Licensing and notices

Decide and state, explicitly and separately:

- **A license for code** (commonly a permissive license like MIT for a hardware-mod toolkit) and,
  if you want documentation under different terms, **a separate license for docs** (e.g.
  CC BY 4.0) -- put each in its own file (`LICENSE`, `LICENSE-DOCS`) and say which covers what in
  the README. Don't let one license's terms be assumed to cover the other's content.
- **A notices section (`LEGAL.md` / `NOTICE`)** stating plainly: no vendor binary or vendor
  firmware is redistributed by this repository; any register tables, protocol descriptions, or
  init sequences documented here were determined by observing the device's own behavior
  (interoperability reverse engineering), not by copying vendor source.
- **Nominative trademark use with a disclaimer** -- naming the device and vendor to describe what
  the project interoperates with is normal and fine; add one sentence stating the project is
  unaffiliated with and not endorsed by the vendor.
- **A no-warranty / recovery-risk line** -- anyone repeating physical steps on their own hardware
  should be told plainly that mistakes can be irreversible on their unit, and that the project
  carries no warranty.

## 7. Independent verification

The agent (or person) who built the export is the worst-positioned reviewer of it -- they already
believe it's clean. Before anything is pushed, have someone who did **not** build the export:

1. Run the **entire** audit checklist from section 1 against the export tree, from scratch, with
   their own greps -- not by reading the builder's report.
2. Re-check every redaction rule from section 4 by re-grepping for its *pattern* side across the
   export; every rule should show zero remaining hits.
3. Read every public document **end to end, as a stranger would** -- README, license/notice files,
   and everything under the docs tree -- flagging any sentence that reveals the process the
   project was built with, any personal data, any vendor material beyond a short attributed
   quotation, or any hardware claim stated as fact without an evidence label.
4. Confirm **at least one complete replication path is documented end to end** -- a reader
   following only the public docs can build the firmware/software, package it, install it on
   real hardware, and get back to the original state. A toolkit that documents pieces but never
   walks one path start-to-finish isn't actually replicable yet.
5. If the private project ships tests or a build, run them from a genuinely fresh checkout (not
   the builder's working directory) and confirm they pass without any of the builder's local
   state.

Only when this independent pass reports a clean result does the export get a remote and a push.
If it finds failures, fix them, then **re-run the independent verification from scratch** rather
than just re-checking the specific failures -- a fix can introduce a new problem the original
pass didn't have a reason to look for.

## Output

Run this skill's process against the `templates/publication-checklist.md` template -- that
template is the copy-paste checklist a human works through by hand; this skill is the reasoning
and the concrete recipes behind each of its items. Don't duplicate the checklist's items here or
there; fill the template in as you go, and keep it committed to the private project (not the
public export) as the record that the process ran.

## References

- `references/audit-categories.md` -- the full grep/scan recipe for each of the six categories in
  section 1, ready to adapt with your project's actual patterns.
- `references/redaction-rules.md` -- a starter R1-R8 redaction rule table with generic
  placeholders, ready to fill in and apply.
- `templates/publication-checklist.md` -- the copy-paste, human-run version of this process.
- `agents/hygiene-auditor.md` -- the subagent role that runs the section-1 scans and the
  independent verification in section 7.
- `agents/release-packager.md` -- the subagent role that builds the export in sections 3-5.
- `workflows/publish-audit.js` -- runs the six section-1 scans in parallel plus two adversarial
  verification passes and synthesizes a publication plan.
- `workflows/publish-export.js` -- builds the export end to end: base tree, doc rewrites,
  integration pass, independent verification (looping fix/re-verify until clean), then the
  single fresh commit.
