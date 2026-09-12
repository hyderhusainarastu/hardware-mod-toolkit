/*
 * publish-export.js -- build the curated public export of a private hardware-mod project.
 *
 * Run it with the Workflow tool directly:
 *   Workflow({ script: <contents of this file>, args: { ... } })
 * or install it as a named workflow and run it from a project:
 *   repo checkout   -> scripts/install-local.sh --self   -> .claude/workflows/publish-export.js
 *                      then run it as a project workflow named publish-export
 *   plugin install  -> workflows/publish-export.js is auto-discovered
 *                      then run: /hardware-mod-toolkit:publish-export
 *
 * This script consumes the PLAN written by publish-audit.js (args.planPath) -- it does not
 * re-derive the DROP list, the redaction rules, or the grep checklist itself. Run
 * publish-audit.js first, read its plan, then run this script. This is the writing half of
 * publication: it builds the export tree, rewrites the public documents, integrates and
 * verifies the result, and makes exactly one local commit. It never adds a remote and never
 * pushes -- that is a deliberate, separate, human-approved step outside this workflow.
 *
 * args shape:
 *   {
 *     private:       '<absolute path to the private source project -- READ-ONLY, never
 *                      edited, never git-state-changed here>',
 *     exportDir:     '<absolute path to the export tree to create -- the ONLY writable
 *                      path in this whole workflow>',
 *     planPath:      '<absolute path to the plan file produced by publish-audit.js -- must
 *                      be read in full before any edit is made>',
 *     docGroups: [
 *       { key: '<short id, e.g. "root" or "protocol">',
 *         spec: '<which output files this group owns and what each should contain -- see
 *                 the plan's document ToC; groups MUST be file-disjoint>' },
 *       ...
 *     ],
 *     identity: { name: '<public commit author name>', email: '<public commit author email,
 *                 or a project-noreply-style address if the owner prefers not to publish a
 *                 real one>' },
 *     commitMessage: '<one clean, descriptive commit message -- no trailers of any kind>',
 *   }
 *
 * Hard rules this script enforces at every phase (see COMMON below): the export tree is
 * built ONLY via "git archive HEAD | tar -x", never cp/rsync, so .git, backups, build
 * output and anything gitignored cannot ride along; no personal data, home paths, machine
 * names, serials, MACs, or network names in anything written to the export; no vendor
 * binaries and no verbatim vendor text; evidence grades (CONFIRMED / STRONGLY INDICATED /
 * POSSIBLE / UNKNOWN) survive on every hardware claim; nothing is invented -- every fact in
 * the export traces to a private source document; the export never talks to a real
 * USB/serial device, and any test or host-tool run during this workflow runs in whatever
 * no-hardware / mock-mode the private project's own docs define (check its README/tests for
 * the exact variable name -- do not guess one).
 */

export const meta = {
  name: 'publish-export',
  description: 'Build the curated public export from a private source project: fresh git-archive base, plan-driven redaction and drops, parallel doc rewrite by disjoint ownership groups, integration pass, independent verification with a bounded fix/re-verify loop, then a single gated commit.',
  phases: [
    { title: 'Base' },
    { title: 'Docs' },
    { title: 'Integrate' },
    { title: 'Verify' },
    { title: 'Commit' },
  ],
}

const PRIV = args.private
const EXP = args.exportDir
const PLAN = args.planPath

const COMMON = 'CONTEXT: we are building a curated PUBLIC export of a private hardware-mod ' +
  'project so a stranger can replicate and modify the work. Private source project ' +
  '(READ-ONLY -- never edit it, never run any git state-changing command there, only read ' +
  'from it): "' + PRIV + '". Export tree (this is the ONLY path you write to): "' + EXP +
  '". The publication plan -- DROP list, feature-removal / dangling-reference list, ' +
  'numbered redaction rules, licence decision, document table of contents, and the grep ' +
  'checklist -- is at "' + PLAN + '". Read that plan IN FULL before touching anything; do ' +
  'not improvise a drop list, a redaction rule, or a checklist item that isn\'t in it -- if ' +
  'the plan is silent on something you think matters, say so in your report instead of ' +
  'inventing a rule. HARD CONTENT RULES for every file you write or leave in the export: no ' +
  'personal data of any kind (a person\'s name, username, email, home directory path, ' +
  'machine name, device or host serial number, MAC address, Wi-Fi network name); no vendor ' +
  'binaries, vendor firmware images, or verbatim vendor source/documentation text beyond a ' +
  'short attributed quotation; keep the CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN ' +
  'evidence labels on every hardware claim exactly as graded in the private sources; never ' +
  'invent a fact -- every technical claim in the export must trace to a private source ' +
  'document, and if you cannot find its source, flag it as a problem rather than writing it ' +
  'down. DEVICE / MOCK RULES: never open, flash, or otherwise touch a real USB or serial ' +
  'device from this workflow. Before running any test or host-tool command, check the ' +
  'private project\'s own README/docs/tests for the exact no-hardware or mock-mode ' +
  'environment variable it defines and export that -- do not guess a name, and do not run ' +
  'anything that would open a real port if no such mode is documented. Paths may contain ' +
  'spaces: quote every path in every shell command. '

const R = { type: 'object', properties: { done: { type: 'string' }, files: { type: 'array', items: { type: 'string' } }, problems: { type: 'array', items: { type: 'string' } } }, required: ['done', 'files', 'problems'] }
const V = { type: 'object', properties: { pass: { type: 'boolean' }, failures: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } }, required: ['pass', 'failures', 'notes'] }

phase('Base')
const base = await agent(COMMON +
  'TASK (Base): create the export tree from a single clean snapshot and bring it to a green, ' +
  'plan-compliant baseline before any doc rewriting happens. (1) mkdir -p "' + EXP + '" and ' +
  'populate it ONLY via: cd "' + PRIV + '" && git archive HEAD | tar -x -C "' + EXP + '". Do ' +
  'NOT use cp or rsync on the private project directory under any circumstance, and do not ' +
  'copy .git, any backup directory, any build/output directory, or anything the private ' +
  'project gitignores -- git archive already excludes all of that by construction, which is ' +
  'exactly why it is the only allowed method. (2) Apply the plan\'s DROP list exactly: delete ' +
  'every file and directory it names (internal operating-rules files, session/process notes, ' +
  'media the plan says not to ship, anything superseded). (3) Apply the plan\'s feature-' +
  'removal edits: for every feature the plan says must be removed or generalized for this ' +
  'export, walk its full dangling-reference list from the plan (tests, scripts, config ' +
  'manifests, CLI help text, doc mentions) and fix or delete every one of them so the export ' +
  'never ships a broken import, a test asserting a removed feature, or documentation for a ' +
  'command that no longer exists. (4) Apply the plan\'s numbered mechanical redaction rules ' +
  '(R1..Rn) across the whole export with sed or a small python3 script -- never by hand, ' +
  'hand-editing means the next matching file gets missed. Do not apply a rule that would ' +
  'rename the project\'s own product or code identifiers (its CLI name, its own config-symbol ' +
  'prefix) -- those are the project\'s public identity, not a secret; redaction rules are for ' +
  'people, places, specific device instances, and mentions of the tooling that built the ' +
  'project, exactly as the plan specifies. (5) Reconcile package/module metadata (e.g. a ' +
  'pyproject.toml, package.json, or equivalent) to the plan\'s chosen licence, with neutral ' +
  'author fields (a project-contributors name, no personal email) instead of whatever the ' +
  'private project had. (6) Do NOT rewrite document prose yet -- the Docs phase below owns ' +
  'that; this phase is mechanical only. (7) Create a clean, fresh build/test environment ' +
  'inside the export (a new virtualenv or equivalent -- never reuse anything from the ' +
  'private project\'s own environment) and run the project\'s test suite in its documented ' +
  'no-hardware/mock mode until it is green; fix whatever the drops/edits above broke. (8) Run ' +
  'the plan\'s full grep checklist over the export and report every remaining hit grouped by ' +
  'file: doc-prose hits are EXPECTED at this stage (the Docs phase hasn\'t run yet) and should ' +
  'just be listed; any hit inside code, a script, or a config file must already be zero -- if ' +
  'it isn\'t, fix it before returning. Return done/files/problems.',
  { label: 'base', phase: 'Base', model: 'sonnet', effort: 'high', schema: R })
log('base done; problems: ' + (base ? base.problems.length : 'n/a'))

phase('Docs')
const docGroups = Array.isArray(args.docGroups) ? args.docGroups : []
const docs = await parallel(docGroups.map(g => () => agent(COMMON +
  'TASK (Docs, group ' + g.key + '): ' + g.spec + ' Rules for every group: read every private ' +
  'source document this group draws from IN FULL before writing anything -- do not summarize ' +
  'from memory or from a partial read. Preserve every CONFIRMED (and STRONGLY INDICATED / ' +
  'POSSIBLE, correctly labelled) technical fact -- numbers, addresses, pin/GPIO assignments, ' +
  'timings, protocol fields, hashes of the project\'s OWN build artifacts -- a public reader ' +
  'must be able to replicate the work from what you write, so dropping a real number to make ' +
  'prose cleaner is a regression, not an improvement. Strip process/project-management ' +
  'narrative (phase trackers, internal timestamps, session notes) rather than migrating it. ' +
  'Where the DROP list removed media (photos, raw captures) that a document referenced, ' +
  'rewrite the reference as prose describing the finding, or as a link to a diagram file if ' +
  'the plan supplies one for that topic -- never leave a dangling reference to a file that no ' +
  'longer exists in the export. Cross-link only to other files the plan\'s table of contents ' +
  'says will exist in this export -- do not link a document another group hasn\'t written yet ' +
  'without confirming its planned filename first. Touch ONLY the output files this group owns ' +
  '-- other groups are writing their own files concurrently, and touching a file outside your ' +
  'ownership list will race with another agent\'s edits. Before returning, grep every file ' +
  'you wrote against the plan\'s forbidden-term / redaction patterns yourself and fix any hit ' +
  '-- do not rely on a later phase to catch it. Return done/files/problems.',
  { label: 'docs:' + g.key, phase: 'Docs', model: 'sonnet', effort: 'high', schema: R })))
log('docs groups done: ' + docs.filter(Boolean).length + ' / ' + docGroups.length)

phase('Integrate')
const integ = await agent(COMMON +
  'TASK (Integrate): the Base and Docs agents reported: ' +
  JSON.stringify({ base: base, docs: docs.filter(Boolean) }).slice(0, 60000) +
  '. Now make the export coherent as one repository rather than a pile of independently-' +
  'written pieces: (1) list every document still present and remove any leftover file that ' +
  'is superseded by a Docs-phase output or is process-only and was missed by the DROP list -- ' +
  'for each one, decide keep-as-technical-reference or delete, and report the decision; (2) ' +
  'fix every cross-link across the whole export (README and every doc) so it points at a file ' +
  'that actually exists in the tree; (3) confirm any repository-map section in the README ' +
  'matches the real tree exactly; (4) re-run the plan\'s FULL verification checklist end to ' +
  'end over the export -- every grep (report and fix every hit; for a tooling/process-' +
  'vocabulary hit, read the surrounding sentence and reword rather than deleting real ' +
  'content), forbidden files, size limits, the test suite (fresh environment, the project\'s ' +
  'documented no-hardware/mock mode), and a from-scratch build of anything the project builds ' +
  '(firmware, native helpers, packaging scripts) using only what a fresh clone would have -- ' +
  'no reused build directories or local state from earlier phases; (5) fix everything you are ' +
  'able to fix yourself; report what remains for the independent verifier.',
  { label: 'integrate', phase: 'Integrate', model: 'opus', effort: 'high', schema: R })

phase('Verify')
let ver = await agent(COMMON +
  'TASK (Independent verification): you did NOT build this export -- come to it as a ' +
  'stranger would. Run the plan\'s ENTIRE verification checklist yourself, from scratch, on ' +
  '"' + EXP + '", with your own greps and your own commands -- do not read the Integrate ' +
  'agent\'s report and treat it as ground truth. In addition: read the README and every public ' +
  'document under the export end to end, as a first-time reader, and flag any sentence that ' +
  'reveals the process the project was built with, any personal data, any vendor material ' +
  'beyond a short attributed quotation, or any hardware claim stated as plain fact without an ' +
  'evidence label; confirm that at least one COMPLETE replication path is documented start to ' +
  'finish (build it, package it, install it on real hardware, recover it if something goes ' +
  'wrong) -- a toolkit that documents pieces but never walks one path all the way through is ' +
  'not actually replicable yet; confirm no dropped media (photos, raw captures) survived ' +
  'anywhere in the tree; confirm the test suite passes and anything the project builds builds, ' +
  'from a genuinely fresh state, not a directory left over from an earlier phase. Return ' +
  'pass=true ONLY if every checklist item passes with no exceptions; otherwise list every ' +
  'failure with a specific file (and line, where it applies).',
  { label: 'verify', phase: 'Verify', model: 'opus', effort: 'high', schema: V })
if (ver && !ver.pass) {
  log('verify failed (' + ver.failures.length + ' failures) -- running ONE bounded fix / re-verify round, not a loop')
  const fix = await agent(COMMON +
    'TASK (Fix): resolve every failure the independent verifier reported: ' +
    JSON.stringify(ver.failures) + '. Re-run the specific check each failure came from after ' +
    'fixing it, to confirm the fix actually took, before returning. Return done/files/problems.',
    { label: 'fix', phase: 'Verify', model: 'sonnet', effort: 'high', schema: R })
  ver = await agent(COMMON +
    'TASK (Re-verify): the previous failures ' + JSON.stringify(ver.failures) +
    ' were reportedly fixed: ' + JSON.stringify(fix) + '. Re-run the plan\'s FULL verification ' +
    'checklist again on "' + EXP + '" from scratch -- not just the items that previously ' +
    'failed, a fix can introduce a new problem the original pass had no reason to look for -- ' +
    'and re-read every file that was touched by the fix. Return pass and any remaining failures.',
    { label: 'verify:round2', phase: 'Verify', model: 'opus', effort: 'high', schema: V })
}

phase('Commit')
let commit = null
if (ver && ver.pass) {
  const identity = args.identity || {}
  const authorName = identity.name || 'project contributors'
  const authorEmail = identity.email || ''
  const message = args.commitMessage || 'Initial public export'
  commit = await agent(COMMON +
    'TASK (Commit): in "' + EXP + '" make exactly one commit on a fresh branch. Run: git init ' +
    '-b main; git config user.name "' + authorName + '"' +
    (authorEmail ? '; git config user.email "' + authorEmail + '"' : '; leave user.email unset only if the host and tooling you are using tolerate that -- otherwise pick a neutral project-contact address and use it') +
    '. Before staging, run git status --porcelain to see everything that would be added, and ' +
    'confirm that every build/output directory, virtual environment, OS metadata file, and ' +
    'anything else the export\'s own .gitignore lists is NOT present in that list (it must be ' +
    'ignored, not merely absent) -- if any of it shows up, fix the .gitignore or remove the ' +
    'file before staging, do not stage it and rely on a later cleanup commit. Then: git add ' +
    '-A; git commit -m "' + message + '" -- the message must be exactly that text with NO ' +
    'trailers of any kind appended (no co-authorship lines, no session/run URLs, no tool ' +
    'attribution). After committing, verify directly rather than assuming: git log ' +
    '--format="%an %ae %B" must show only the identity and message you just set; git ls-files ' +
    '| wc -l and the total size of tracked files, for a sanity check; git ls-files | xargs ' +
    'grep -linE with the plan\'s forbidden-pattern list, over the FINAL tracked-file list (not ' +
    'the working tree before staging) -- must be empty. Do NOT add a remote and do NOT push -- ' +
    'that is a separate, later, human-approved step outside this workflow. Report the commit ' +
    'hash and the result of every check above.',
    { label: 'commit', phase: 'Commit', model: 'sonnet', effort: 'high', schema: R })
} else {
  log('commit skipped: verification did not pass')
}

return { base: base, docs: docs.filter(Boolean), integ: integ, ver: ver, commit: commit }
