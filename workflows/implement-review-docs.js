// implement-review-docs.js
//
// The default implementation loop for a hardware-mod project: one agent implements against
// an explicit file-ownership boundary, an independent agent that did NOT write the code reviews
// the diff and returns a structured, severity-graded verdict, a fix stage applies ONLY the
// critical/major findings and re-runs the real test commands, and documentation is written
// immediately from the implementation report -- in PARALLEL with the review, not appended
// after the whole review/fix cycle finishes. That parallel doc stage is the document-as-you-go
// rule made executable: docs describe what was actually built, not what a reviewer eventually
// approved, and they are never left for "later" (later tends not to happen).
//
// This also carries the file-ownership convention that lets several implement-review-docs runs
// (or this run and a hand-run agent) work the same tree concurrently without collisions: every
// agent in this script is told to touch ONLY args.ownedPaths, and args.docTargets should list
// paths no other concurrent run owns.
//
// RUN RECIPE
//
// Via the Workflow tool, inline or from a saved script:
//   Workflow({
//     scriptPath: "workflows/implement-review-docs.js",
//     args: {
//       repo: "/absolute/path/to/<REPO>",
//       task: "One paragraph describing exactly what to build or change, in enough detail
//              for a single subagent to execute without asking follow-up questions.",
//       ownedPaths: [
//         "firmware/<MCU>/components/<COMPONENT>",
//         "docs/protocol-spec.md"
//       ],
//       testCommands: [
//         "idf.py build",
//         "python3 -m pytest tests/host -q"
//       ],
//       docTargets: [
//         { path: "docs/protocol-spec.md", spec: "Document the new message layout and any new NVS key." },
//         { path: "docs/research-log-entry.md", spec: "Append one research-log entry for this change." }
//       ],
//       commit: true,
//       commitMessage: "<PROJECT>: short summary of the change"
//     }
//   })
//
// As a named plugin workflow, after scripts/install-local.sh has copied this file into a
// project's .claude/workflows/ (or after installing this repo as a Claude Code plugin), run:
//   /hardware-mod-toolkit:implement-review-docs
// and supply the same args shape above when prompted.
//
// ARGS SHAPE
//   repo           string            absolute path to the project root (quote it if it has spaces)
//   task           string            the work to implement, described in enough detail to execute
//   ownedPaths     string[]          the ONLY paths this run may touch (see file-ownership convention)
//   testCommands   string[]          exact commands to run after implementing, and again after any fix
//   docTargets     {path, spec}[]    one doc-writing agent per entry; each writes directly to "path"
//   commit         boolean           if true AND the review verdict is GO, run a final commit agent
//   commitMessage  string            exact commit message to use verbatim (this workflow adds no trailers)
//
// Returns { impl, check, fix, docs, commit }.

export const meta = {
  name: 'implement-review-docs',
  description: 'Implement a task against an owned file set, adversarially review the diff, apply only critical/major fixes, document in parallel with the review, and optionally commit on a GO verdict.',
  phases: [
    { title: 'Implement' },
    { title: 'Review' },
    { title: 'Fix' },
    { title: 'Document' },
  ],
}

const REPO = args && args.repo
const TASK = args && args.task
const OWNED = (args && args.ownedPaths) || []
const TESTS = (args && args.testCommands) || []
const DOC_TARGETS = (args && args.docTargets) || []
const SHOULD_COMMIT = !!(args && args.commit)
const COMMIT_MESSAGE = (args && args.commitMessage) || ''

const SAFETY = 'SAFETY: the project root is "' + REPO + '" (the path may contain spaces -- quote ' +
  'it in every shell command). Read "' + REPO + '/CLAUDE.md" first if it exists, and follow every ' +
  'rule it states -- it is this specific project\'s operating contract and overrides any generic ' +
  'assumption you would otherwise make. NEVER open, probe, flash, erase, or write to a real USB or ' +
  'serial device, and never put a device into a bootloader/download/DFU mode -- this is a host-only, ' +
  'files-and-source task. Never run a flashing tool with a real port argument and never run a device ' +
  'monitor command. Before running any host-side test or script that talks to a "device" object, ' +
  'export whatever mock/simulation environment variable this project defines for that purpose (see ' +
  'CLAUDE.md and any hardware-safety doc it points to) so nothing can reach real hardware even by ' +
  'accident. Touch ONLY these paths -- nothing else in the tree, not even to fix an unrelated typo you ' +
  'notice along the way -- because other agents may be working the rest of the tree at the same time ' +
  'and an out-of-scope edit is a collision: ' + JSON.stringify(OWNED) + '. Never commit unless a step ' +
  'below explicitly tells you to, and even then, stage only the paths you were told to.'

const R_SCHEMA = {
  type: 'object',
  properties: {
    done: { type: 'string' },
    files: { type: 'array', items: { type: 'string' } },
    problems: { type: 'array', items: { type: 'string' } },
  },
  required: ['done', 'files', 'problems'],
}

const CHECK_SCHEMA = {
  type: 'object',
  properties: {
    problems: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          problem: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'major', 'minor'] },
          fix: { type: 'string' },
        },
        required: ['file', 'problem', 'severity', 'fix'],
      },
    },
    verdict: { type: 'string', enum: ['GO', 'NO-GO'] },
    summary: { type: 'string' },
  },
  required: ['problems', 'verdict', 'summary'],
}

const DOC_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    written: { type: 'boolean' },
    summary: { type: 'string' },
  },
  required: ['path', 'written', 'summary'],
}

// ---- Phase 1: Implement -----------------------------------------------------------------

phase('Implement')

const implementPrompt = SAFETY + '\n\nTASK: ' + TASK + '\n\n' +
  'Implement this task now, editing only the owned paths above. When you are done, run EVERY ' +
  'one of these commands, in order, from "' + REPO + '", and report each command\'s output ' +
  'verbatim (do not summarize or paraphrase a failure -- paste the actual failing output): ' +
  JSON.stringify(TESTS) + '. If a command fails, fix the cause within your owned paths and ' +
  're-run it before reporting done. Do NOT commit anything -- a later stage decides whether to ' +
  'commit. Return: "done" (one paragraph, what you actually built, in past tense, naming the exact ' +
  'files/functions/constants involved -- not a restatement of the task), "files" (every path you ' +
  'created or edited), and "problems" (anything you were unsure about, anything you deferred, or ' +
  'any test command output you could not resolve).'

const impl = await agent(implementPrompt, {
  label: 'implement',
  phase: 'Implement',
  model: 'sonnet',
  effort: 'high',
  schema: R_SCHEMA,
})

// ---- Phase 2: Review + Phase 4: Document, running CONCURRENTLY --------------------------
//
// Docs are written from the implementation report the moment it exists -- not after review,
// not after fix, not "at the end of the session". The review runs against the same report at
// the same time. Neither stage depends on the other's output, so there is no reason to make
// documentation wait on a human-paced review/fix cycle. Each agent() below is tagged with an
// explicit "phase" because both branches run inside one parallel() barrier -- relying on the
// global phase() cursor here would race between the two branches.

const reviewPrompt = SAFETY + '\n\nYou are reviewing a diff you did NOT write and have no stake in ' +
  'defending. Your job is to find real problems, not to bless the work. TASK THAT WAS ASKED FOR: ' +
  TASK + '\n\nDIFF SCOPE (only these paths should show changes -- flag anything outside them as a ' +
  'critical problem): ' + JSON.stringify(OWNED) + '\n\nTHE IMPLEMENTER\'S OWN REPORT (treat as a ' +
  'claim to verify, not a fact -- read the actual diff yourself): ' + JSON.stringify(impl) + '\n\n' +
  'Read the actual diff (e.g. git diff, or git status plus reading the changed files if the repo ' +
  'is not a git checkout) yourself before judging it. Check: does the diff actually stay inside the ' +
  'owned paths; does it actually do what the task asked, not just something adjacent to it; does it ' +
  'match this project\'s own conventions and any spec/protocol doc it should agree with; are the ' +
  'test commands the implementer says they ran the same ones you were given, and do their reported ' +
  'results look like real output rather than an assumed pass; any hardware-safety rule violated ' +
  '(a real port opened, a mock bypassed, an irreversible operation attempted); any secret, credential, ' +
  'device serial, MAC, or SSID introduced. Grade every problem you find "critical" (breaks safety, ' +
  'breaks the build/tests, or does something the task did not ask for), "major" (wrong behavior, ' +
  'wrong protocol/spec match, missing test coverage for the new behavior), or "minor" (style, a ' +
  'better name, a nit). Return "verdict" GO only if there are zero critical and zero major problems.'

const documentAgents = DOC_TARGETS.map(function (target, i) {
  return function () {
    const docPrompt = SAFETY + '\n\nTASK THAT WAS JUST IMPLEMENTED: ' + TASK + '\n\n' +
      'IMPLEMENTATION REPORT: ' + JSON.stringify(impl) + '\n\n' +
      'Write to "' + REPO + '/' + (target && target.path) + '" now: ' + (target && target.spec) + '\n\n' +
      'Follow this project\'s own document templates and conventions for a file at this path (look ' +
      'for a matching template under this toolkit\'s templates/ directory, or for the project\'s own ' +
      'existing docs of the same kind, and match their structure and level of detail). Write the ' +
      'actual finding/entry/section now, in full -- do not write a placeholder or an outline to fill ' +
      'in later, and do not wait to see what the review stage concludes; document what was actually ' +
      'built, per the implementation report above. If the path is an append-only log (for example a ' +
      'research log), append one entry and do not rewrite existing entries. Touch only this one path. ' +
      'Return "path" (the path you wrote), "written" (true once the content is actually saved to ' +
      'disk), and "summary" (one sentence on what you added).'

    return agent(docPrompt, {
      label: 'doc:' + ((target && target.path) || i),
      phase: 'Document',
      model: 'sonnet',
      schema: DOC_SCHEMA,
    })
  }
})

const parallelResults = await parallel([
  function () {
    return agent(reviewPrompt, {
      label: 'review',
      phase: 'Review',
      model: 'opus',
      effort: 'high',
      schema: CHECK_SCHEMA,
    })
  },
  function () {
    return parallel(documentAgents)
  },
])

const check = parallelResults[0]
const docs = (parallelResults[1] || []).filter(Boolean)

// ---- Phase 3: Fix (conditional) ----------------------------------------------------------

phase('Fix')

const severeProblems = ((check && check.problems) || []).filter(function (p) {
  return p.severity === 'critical' || p.severity === 'major'
})

let fix = null

if (severeProblems.length > 0) {
  log('review found ' + severeProblems.length + ' critical/major problem(s) -- running fix stage')

  const fixPrompt = SAFETY + '\n\nTASK THAT WAS ASKED FOR: ' + TASK + '\n\n' +
    'A reviewer who did not write this code found the following problems in your diff. Apply a ' +
    'fix for EVERY item in this list and nothing else -- do not use this pass to make unrelated ' +
    'changes, and do not touch the minor/nit items the reviewer chose not to flag as critical or ' +
    'major: ' + JSON.stringify(severeProblems) + '\n\n' +
    'After applying every fix, re-run EVERY one of these commands again, in order, and report each ' +
    'one\'s output verbatim: ' + JSON.stringify(TESTS) + '. Do NOT commit. Return "done" (what you ' +
    'changed, per problem), "files" (every path you touched in this fix pass), and "problems" (any ' +
    'item from the list above you could not fully resolve, and why).'

  fix = await agent(fixPrompt, {
    label: 'fix',
    phase: 'Fix',
    model: 'sonnet',
    effort: 'high',
    schema: R_SCHEMA,
  })
} else {
  log('review found no critical/major problems -- skipping fix stage')
}

// ---- Optional final commit -----------------------------------------------------------------
//
// Gated strictly on the ORIGINAL review verdict being GO. If severe problems were found (and a
// fix pass ran above), the verdict recorded for this run stays NO-GO -- this run does not
// auto-commit its own fixes. That is deliberate: a diff that needed a critical/major fix gets a
// human or a fresh review pass before it lands, not an automatic pass on the second try.

let commit = null

if (SHOULD_COMMIT && check && check.verdict === 'GO') {
  const changedPaths = OWNED.concat(docs.map(function (d) { return d && d.path }).filter(Boolean))

  const commitPrompt = SAFETY + '\n\nThe review verdict was GO and a commit was requested. Before ' +
    'committing: run git status and git diff --stat in "' + REPO + '" and confirm that ONLY these ' +
    'paths show changes: ' + JSON.stringify(changedPaths) + '. If anything else is modified or ' +
    'untracked, STOP and return without committing -- report exactly what was unexpected instead. ' +
    'Otherwise, stage exactly these changed paths (never git add -A, never a bare git add .) and ' +
    'commit with EXACTLY this message and nothing appended to it -- no trailers, no signature, no ' +
    'extra footer of any kind: ' + JSON.stringify(COMMIT_MESSAGE) + '\n\n' +
    'Return the commit hash, or, if you stopped instead of committing, exactly why.'

  commit = await agent(commitPrompt, {
    label: 'commit',
    phase: 'Review',
    model: 'sonnet',
    effort: 'medium',
  })
} else if (SHOULD_COMMIT) {
  log('commit was requested but the review verdict was not a clean GO -- skipping automatic commit')
}

return { impl: impl, check: check, fix: fix, docs: docs, commit: commit }
