// diagnose-verify-synthesize.js
//
// WHAT THIS DOES
// A four-phase workflow for diagnosing a cross-boundary bug in a hardware-mod
// project -- a bug that only makes sense once you read BOTH sides of a
// boundary together (host <-> firmware, app <-> driver, protocol sender <->
// protocol receiver, etc). It does NOT guess from one side's code in
// isolation. Shape:
//
//   Map        -- one agent per side of the boundary, reading ONLY its own
//                 side's paths, answering the same set of questions, citing
//                 file:line for every claim. The two maps never see each
//                 other while being written -- this keeps them independent.
//   Diagnose   -- one strong agent reads both maps AND the code itself (maps
//                 are notes, not ground truth) and produces RANKED
//                 hypotheses. Every candidate mechanism you already suspect
//                 is passed in and must be addressed explicitly, even to be
//                 dismissed. Each hypothesis must state whether it explains
//                 the EXACT observed numbers/symptom, not just "something
//                 like this could happen".
//   Verify     -- the top hypotheses are each attacked by two independent
//                 agents with DIFFERENT lenses (e.g. "does the code actually
//                 do this" vs "do the numbers/timing actually work out").
//                 Both default to refuted=true when they cannot personally
//                 confirm the mechanism in the code. A hypothesis survives
//                 only if at least one verdict is not refuted.
//   Synthesize -- one agent turns the surviving, verified hypotheses into a
//                 single answer: most likely root cause with a confidence
//                 label, the ONE cheapest check a human can run by hand to
//                 tell the survivors apart, a fix split into host-side vs
//                 device-side work, a regression-test idea, and an explicit
//                 "do not do this" list.
//
// This is the shape that actually found root causes in the source project:
// independent maps prevent one side's assumptions from contaminating the
// other; forcing every hypothesis to explain the EXACT symptom (not a vague
// family of symptoms) kills plausible-sounding-but-wrong theories early;
// defaulting verifiers to refuted=true means a hypothesis has to earn
// survival instead of surviving by default. It generalises to any bug that
// spans a boundary between two things you can read independently.
//
// HOW TO RUN
//   Option A -- as an installed plugin command (after installing this
//   toolkit into a project, see scripts/install-local.sh):
//     /hardware-mod-toolkit:diagnose-verify-synthesize
//   then supply the args below when the Workflow tool prompts for them, or
//   pass them programmatically via the Workflow tool's args input.
//
//   Option B -- point the Workflow tool directly at this file:
//     Workflow({ scriptPath: "<path-to>/workflows/diagnose-verify-synthesize.js",
//                args: { ... shape below ... } })
//
// ARGS SHAPE
//   {
//     repo: "<REPO>",                       // absolute path to the project root.
//                                            // Quote it yourself if it contains
//                                            // spaces when you use it in shell
//                                            // commands -- this script only
//                                            // passes it to agents as text.
//     incident: "free text description of the bug: exact symptom, exact\n" +
//               "observed values/numbers, what command was run, what the\n" +
//               "expected vs actual behaviour was, and any release/version\n" +
//               "context that might matter",
//     sideA: {
//       name: "host",                       // short label, used in agent labels
//       paths: ["<REPO>/host/...", "..."],  // files/dirs this agent reads --
//                                            // ONLY this side, nothing more
//       questions: ["exact question 1", "exact question 2", "..."]
//     },
//     sideB: {
//       name: "firmware",
//       paths: ["<REPO>/firmware/...", "..."],
//       questions: ["...", "..."]
//     },
//     candidates: [
//       "hypothesis you already suspect, stated as one sentence",
//       "another candidate mechanism",
//       "..."
//     ]
//   }
//
// Works for any two-sided bug: swap sideA/sideB for host/device, app/driver,
// encoder/decoder, sender/receiver -- whatever the boundary is in your project.

export const meta = {
  name: 'diagnose-verify-synthesize',
  description: 'Map both sides of a boundary, hypothesise, adversarially refute, synthesize a single diagnosis',
  phases: [
    { title: 'Map', detail: 'one agent per side, independent, file:line evidence only' },
    { title: 'Diagnose', detail: 'one strong agent reads the code itself and ranks hypotheses' },
    { title: 'Verify', detail: 'two lenses per hypothesis, default to refuted' },
    { title: 'Synthesize', detail: 'single root cause, cheapest distinguishing check, fix, what not to do' },
  ],
}

const REPO = args.repo
const INCIDENT = args.incident
const SIDE_A = args.sideA
const SIDE_B = args.sideB
const CANDIDATES = args.candidates || []

const SAFETY = 'SAFETY (standing rules, do not violate any of these): the project is at "' +
  REPO + '" -- if that path contains spaces, quote it in every shell command you run. ' +
  'Read the project rules file first (CLAUDE.md at the project root, or the nearest ' +
  'README/AGENTS file if there is no CLAUDE.md) before reading anything else, and follow ' +
  'whatever hardware-safety rules it states. This is a READ-ONLY diagnosis task: do not edit, ' +
  'move, rename, or delete any file in the project. NEVER open, probe, flash, or write to any ' +
  'USB or serial device, and never run a flashing/programming tool (e.g. esptool-style tools) ' +
  'under any circumstances. Before running any command that could open a serial port or talk to ' +
  'hardware (tests, CLI tools, servers), set whatever mock/simulation environment variable the ' +
  'project defines for offline runs (check its README/CLAUDE.md for the exact variable name) -- ' +
  'if you cannot find one or are not sure a command is safe, do not run it; read the code instead. ' +
  'If you cannot answer a question from reading code and docs alone, say so rather than guessing. '

const MAP_SCHEMA = {
  type: 'object',
  properties: {
    summary: { type: 'string', description: 'what this side does, in relation to the incident, in a few sentences' },
    rules_observed: { type: 'string', description: 'the exact rules/contract this side implements or enforces -- state and transition logic, validation, retry/resend behaviour, error handling -- as it actually reads in the code, not as it is documented to behave' },
    key_locations: { type: 'array', items: { type: 'string' }, description: 'file:line references for every claim above' },
  },
  required: ['summary', 'rules_observed', 'key_locations'],
}

const HYP_SCHEMA = {
  type: 'object',
  properties: {
    hypotheses: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          mechanism: { type: 'string', description: 'the exact causal chain, step by step' },
          evidence: { type: 'string', description: 'file:line evidence supporting this mechanism' },
          explains_exact_symptom: { type: 'string', description: 'does this mechanism produce the EXACT observed value(s)/symptom in the incident, not just something similar -- show the arithmetic or sequence of events if relevant' },
          confidence: { type: 'string' },
          how_to_confirm: { type: 'string', description: 'the cheapest safe way to confirm this specific hypothesis' },
          fix_sketch: { type: 'string', description: 'a safe fix, host/software-side preferred over firmware/device-side' },
        },
        required: ['title', 'mechanism', 'evidence', 'explains_exact_symptom', 'confidence', 'how_to_confirm', 'fix_sketch'],
      },
    },
  },
  required: ['hypotheses'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean' },
    reasoning: { type: 'string' },
    file_line_evidence: { type: 'string' },
  },
  required: ['refuted', 'reasoning', 'file_line_evidence'],
}

phase('Map')
const maps = await parallel([
  () => agent(
    SAFETY + 'INCIDENT: ' + INCIDENT + '\n' +
    'TASK (side "' + SIDE_A.name + '"): read exactly these paths, in full: ' +
    JSON.stringify(SIDE_A.paths) + '. Do not read anything from the other side of the ' +
    'boundary -- your map must be independent. Answer these questions precisely, citing ' +
    'file:line for every claim: ' + JSON.stringify(SIDE_A.questions) + '. ' +
    'Return your findings in the required schema.',
    { label: 'map:' + SIDE_A.name, phase: 'Map', model: 'sonnet', schema: MAP_SCHEMA }
  ),
  () => agent(
    SAFETY + 'INCIDENT: ' + INCIDENT + '\n' +
    'TASK (side "' + SIDE_B.name + '"): read exactly these paths, in full: ' +
    JSON.stringify(SIDE_B.paths) + '. Do not read anything from the other side of the ' +
    'boundary -- your map must be independent. Answer these questions precisely, citing ' +
    'file:line for every claim: ' + JSON.stringify(SIDE_B.questions) + '. ' +
    'Return your findings in the required schema.',
    { label: 'map:' + SIDE_B.name, phase: 'Map', model: 'sonnet', schema: MAP_SCHEMA }
  ),
])
const mapText = JSON.stringify(maps.filter(Boolean), null, 2)

phase('Diagnose')
const diag = await agent(
  SAFETY + 'INCIDENT: ' + INCIDENT + '\n' +
  'You are the lead debugger. Two independent mapping agents produced these notes (side "' +
  SIDE_A.name + '" and side "' + SIDE_B.name + '"):\n' + mapText + '\n' +
  'Read the code yourself wherever it matters -- do not trust the notes blindly, they may ' +
  'have missed something or gotten a detail wrong. Produce RANKED hypotheses for the root ' +
  'cause of the incident. You MUST consider every one of the following candidate mechanisms ' +
  'explicitly, even to rule one out with evidence -- do not silently drop any of them: ' +
  JSON.stringify(CANDIDATES) + '. You may also propose hypotheses not in that list. ' +
  'For each hypothesis, state plainly whether it explains the EXACT observed symptom/value(s) ' +
  'from the incident (not merely a similar-looking symptom), cite file:line evidence, and give ' +
  'a fix sketch that is safe to apply -- prefer a fix on the side of the boundary you can change ' +
  'without touching hardware or shipped/vendor state.',
  { label: 'diagnose', phase: 'Diagnose', model: 'opus', effort: 'high', schema: HYP_SCHEMA }
)
const hyps = (diag && diag.hypotheses) ? diag.hypotheses.slice(0, 4) : []
log('hypotheses: ' + hyps.length)

phase('Verify')
const verified = await parallel(hyps.map((h, i) => () =>
  parallel(['code-reading', 'arithmetic-and-timing'].map(lens => () =>
    agent(
      SAFETY + 'INCIDENT: ' + INCIDENT + '\n' +
      'Adversarially try to REFUTE this hypothesis using the ' + lens + ' lens. ' +
      'Hypothesis: ' + h.title + '. Mechanism: ' + h.mechanism + '. Claimed evidence: ' +
      h.evidence + '. Claimed to explain the exact symptom: ' + h.explains_exact_symptom + '. ' +
      'Read the actual code yourself and cite file:line for your own verdict -- do not just ' +
      're-state the hypothesis author\'s evidence. Default to refuted=true if you cannot ' +
      'personally confirm the mechanism exists in the code as claimed. If your lens is ' +
      '"arithmetic-and-timing", work through the actual numbers/ordering of events and state ' +
      'whether they produce exactly the observed symptom given real startup/runtime order -- ' +
      'not just whether the idea is plausible in the abstract.',
      { label: 'verify:' + i + ':' + lens, phase: 'Verify', model: 'opus', schema: VERDICT_SCHEMA }
    )
  )).then(vs => ({
    hypothesis: h,
    votes: vs.filter(Boolean),
    survives: vs.filter(Boolean).filter(v => !v.refuted).length >= 1,
  }))
))
log('verified: ' + verified.filter(Boolean).filter(v => v.survives).length + '/' + verified.filter(Boolean).length + ' hypotheses survive')

phase('Synthesize')
const synth = await agent(
  SAFETY + 'INCIDENT: ' + INCIDENT + '\n' +
  'Synthesize a final diagnosis from these verified hypotheses (JSON): ' +
  JSON.stringify(verified.filter(Boolean), null, 2) + '\n' +
  'Output, in plain text for the moderator, in this order: ' +
  '(1) the most likely root cause, with a confidence label of CONFIRMED, STRONGLY INDICATED, ' +
  'POSSIBLE, or UNKNOWN, and why that label and not a stronger one; ' +
  '(2) if more than one hypothesis survived verification, the single CHEAPEST check a human ' +
  'can run by hand to distinguish between the survivors -- state exactly what output would ' +
  'point to which hypothesis, and make sure the check itself is safe under the SAFETY rules ' +
  'above (no device writes, no flashing, no probing); ' +
  '(3) the recommended fix, split into changes on side "' + SIDE_A.name + '" and changes on ' +
  'side "' + SIDE_B.name + '" (file/function level where possible), plus one regression-test ' +
  'idea that exercises this path without touching real hardware (e.g. via a mock/simulation ' +
  'mode if the project has one); ' +
  '(4) anything the owner should explicitly NOT do while chasing this down. ' +
  'Keep it under 400 words.',
  { label: 'synthesize', phase: 'Synthesize', model: 'opus' }
)

return { synth, verified }
