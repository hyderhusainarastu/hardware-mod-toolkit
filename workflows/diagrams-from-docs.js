/*
 * diagrams-from-docs.js -- Plan, draw, and fact-check documentation diagrams (Mermaid + hand-written SVG).
 *
 * WHAT THIS IS FOR
 *   When photos of the physical device cannot be published (privacy, size, or because they show a
 *   specific person's hardware), diagrams are the replacement -- and they must carry the same evidence
 *   discipline as the prose docs they are drawn from. This workflow:
 *     1. Plans a coherent 8-12 diagram set from your project documentation (Plan phase, one opus agent).
 *     2. Draws each diagram from re-read source lines, then fact-checks and syntax-checks it in place
 *        (Draw + Check, a two-stage pipeline over the diagrams).
 *
 * RUN RECIPE
 *   With the Workflow tool, inline:
 *     Workflow({
 *       script: <contents of this file>,
 *       args: {
 *         repo: '/absolute/path/to/your/project',                  // READ-ONLY source of docs
 *         outDir: '/absolute/path/to/publish-staging/diagrams',     // created with mkdir -p; all output goes here
 *         mustInclude: ['system-block-diagram', 'boot-flow', 'protocol-frame-format'],
 *         style: {
 *           mermaidFor: 'flowcharts, sequence diagrams, and state machines',
 *           svgFor: 'board-level block diagrams and physical panel/pinout layouts where Mermaid is inadequate',
 *         },
 *       },
 *     })
 *   As a named workflow (installed under .claude/workflows/diagrams-from-docs.js):
 *     /diagrams-from-docs {"repo": "...", "outDir": "...", "mustInclude": [...], "style": {...}}
 *
 * ARGS SHAPE
 *   {
 *     repo: string,                // absolute path to the documentation source, READ-ONLY, never edited
 *     outDir: string,              // absolute path to write diagrams into; created if missing
 *     mustInclude: [string],       // kebab-case diagram ids the Plan phase must produce (may be [])
 *     style: { mermaidFor: string, svgFor: string },  // guidance strings shown to the Plan/Draw agents
 *   }
 *
 * WHY A PIPELINE, NOT A BARRIER
 *   Draw and Check run as ONE pipeline() over the planned diagrams, not two parallel() barriers. Each
 *   diagram moves through Draw -> Check independently; a diagram that needs several fact-recheck passes
 *   never holds up diagrams that are simple and finish fast. This is deliberate: wall-clock is bounded
 *   by the slowest single diagram's chain, not by the sum of every diagram's slowest stage.
 */

export const meta = {
  name: 'diagrams-from-docs',
  description: 'Plan, draw, and fact-check a set of Mermaid/SVG diagrams from project documentation, with confidence labels and source citations',
  phases: [
    { title: 'Plan' },
    { title: 'Draw' },
    { title: 'Check' },
  ],
}

const REPO = args.repo
const OUT_DIR = args.outDir
const MUST_INCLUDE = (args.mustInclude || [])
const STYLE = args.style || {
  mermaidFor: 'flowcharts, sequence diagrams, and state machines',
  svgFor: 'board-level block diagrams and panel/pinout layouts where Mermaid is inadequate',
}

const SAFETY = 'SAFETY: the documentation source is at "' + REPO + '" (quote paths that contain spaces) and is READ-ONLY for you: never edit, move, or delete anything inside it. Write outputs ONLY under "' + OUT_DIR + '" (create it first with mkdir -p). NEVER touch, open, flash, or otherwise address any USB/serial/hardware device -- this is a documentation task only. Never write any person\'s name, username, home directory path, machine name, serial number, MAC address, or SSID into any output file; write as a generic engineering document, using placeholders such as <DEVICE>, <VENDOR>, <MCU> anywhere the source docs are project-specific. Every fact drawn in a diagram must come from a project document, and every fact carries its confidence label from the source (CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN); anything below CONFIRMED must be marked directly on the diagram or in its facts table (for example a "(strongly indicated)" suffix on the node or edge label) -- never silently upgrade a fact\'s confidence. Never invent a part number, address, or pin name that is not in the source documents. '

const PLAN_SCHEMA = { type: 'object', properties: { diagrams: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, title: { type: 'string' }, format: { type: 'string' }, sources: { type: 'array', items: { type: 'string' } }, content_spec: { type: 'string' } }, required: ['id', 'title', 'format', 'sources', 'content_spec'] } } }, required: ['diagrams'] }
const RESULT_SCHEMA = { type: 'object', properties: { file: { type: 'string' }, facts_used: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } }, required: ['file', 'facts_used', 'notes'] }
const CHECK_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' }, problems: { type: 'array', items: { type: 'string' } } }, required: ['ok', 'problems'] }

phase('Plan')
const mustIncludeText = MUST_INCLUDE.length
  ? ('The plan MUST include a diagram for every one of these ids (add other project-appropriate diagrams beyond them too): ' + JSON.stringify(MUST_INCLUDE) + '. ')
  : ''
const plan = await agent(
  SAFETY +
  'TASK: read every document under "' + REPO + '" that describes the hardware, protocol, firmware, recovery/update flow, host tooling, and any incident or verification logs, then plan the set of diagrams a public reader needs in order to understand and replicate the project WITHOUT photographs. Aim for 8-12 diagrams. ' +
  mustIncludeText +
  'For each diagram give: id (kebab-case), title, format ("mermaid" for ' + STYLE.mermaidFor + ' -- these render natively on most hosts including GitHub; "svg" hand-written for ' + STYLE.svgFor + '), sources (document paths and line ranges you actually read), and a content_spec listing every node, edge, and label to draw, each tagged with its confidence (CONFIRMED / STRONGLY INDICATED / POSSIBLE / UNKNOWN). Keep the plan grounded: cite the document and line range backing each fact you plan to draw. Typical coverage for a hardware mod project: a system block diagram, a signal/bus map, a memory or partition layout, a boot or bring-up flow, a recovery/update flow, a protocol frame format plus a request/response sequence, a host-side data pipeline, a mode/state machine, and any safety-relevant gesture or timing diagram (drawn as a warning, never as encouragement to try it).',
  { label: 'plan', phase: 'Plan', model: 'opus', effort: 'high', schema: PLAN_SCHEMA }
)
const items = (plan && plan.diagrams) ? plan.diagrams : []
log('diagrams planned: ' + items.length)

phase('Draw')
// Draw and Check run as one pipeline, not two parallel() barriers -- see header note above.
const drawn = await pipeline(
  items,
  (d) => agent(
    SAFETY +
    'Draw this diagram exactly per spec. Spec: ' + JSON.stringify(d) + '. Re-read the cited source lines in the documents before drawing, to confirm every fact and its confidence label -- do not draw from memory of the plan alone. Output file: "' + OUT_DIR + '/' + d.id + '.md" if format is mermaid, containing a one-paragraph caption, a fenced mermaid code block, and a facts table (fact | confidence | source) -- or "' + OUT_DIR + '/' + d.id + '.svg" plus a sidecar "' + OUT_DIR + '/' + d.id + '.md" caption file if format is svg. For mermaid: keep it under about 60 nodes, use subgraphs for logical modules, quote any node label that contains parentheses or other special characters, and make sure every subgraph/flowchart block is properly closed with its matching "end". For svg: hand-write clean markup with a viewBox, a system-ui font-family stack, no external references (no linked fonts, images, or stylesheets), and no embedded raster data; keep it legible at roughly 900px wide. Use placeholders such as <DEVICE>/<VENDOR>/<MCU> for anything project-specific that should not appear as a literal identifying detail.',
    { label: 'draw:' + d.id, phase: 'Draw', model: 'sonnet', schema: RESULT_SCHEMA }
  ),
  (r, d) => agent(
    SAFETY +
    'Check the diagram file ' + ((r && r.file) ? r.file : (OUT_DIR + '/' + d.id + '.md')) + ' against its spec ' + JSON.stringify(d) + ' and against the source documents in "' + REPO + '": (1) every fact matches the documents and carries the correct confidence label, with anything below CONFIRMED visibly marked on the diagram or in its facts table; (2) syntax is valid -- for mermaid, use a mermaid CLI (for example mmdc) via npx if one is available offline, otherwise check carefully by eye for unquoted special characters inside labels, a missing "end" on any subgraph or block, and malformed arrows; for svg, run xmllint --noout if it is available, otherwise check by eye that the markup is well-formed XML with a viewBox; (3) no forbidden content -- grep -i the file for a person\'s name, a username, "/Users/", a home directory path, a machine name, a MAC-address pattern, an SSID, or a vendor-confidential string that should not appear in a public document; (4) no invented part numbers, addresses, or pin names beyond what the spec and documents support. If you find any problems, FIX THEM IN PLACE in the output file -- do not just report them -- and then report what you found and changed.',
    { label: 'check:' + d.id, phase: 'Check', model: 'sonnet', schema: CHECK_SCHEMA }
  )
)

return { planned: items.map((d) => d.id), results: drawn }
