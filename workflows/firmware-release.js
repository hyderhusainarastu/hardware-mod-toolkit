// firmware-release.js -- analyze, implement, build, package, check, record
//
// Sixteen releases went out through this exact shape on the worked example
// (byok-mod, github.com/hyderhusainarastu/byok-mod) without a bricked device.
// It front-loads analysis of the OBSERVED defect (including reading an
// owner-supplied photograph or capture of the failure) so the fix is traceable
// to a measurement, not a guess; it builds and packages with the project's own
// toolchain; and it ends with the checks that catch the expensive mistakes:
// protected configuration options re-grepped from the freshly regenerated
// config (not assumed unchanged), the packaged artifact's member proven
// byte-identical to the build output (not just "the build succeeded"), and a
// release row that says "not yet installed" honestly instead of implying a
// test that never happened.
//
// HOW TO RUN
//   As a plugin workflow (after scripts/install-local.sh or a plugin install):
//     /hardware-mod-toolkit:firmware-release
//   As a project-local named workflow: copy this file to
//   <REPO>/.claude/workflows/firmware-release.js and invoke the same way, or
//   pass it inline to the Workflow tool via { scriptPath: "<path to this file>" }.
//
// ARGS SHAPE (pass as the Workflow tool's args input, as real JSON -- not a
// JSON-encoded string):
//   {
//     repo: "<REPO>",                    // absolute path to the project root; quote it wherever it contains a space
//     version: "<PROJECT> 0.1.9",         // the new release's own version string
//     observation: "...",                 // the defect as OBSERVED -- symptom, not diagnosis (e.g. "image on <PANEL> is
//                                          // shifted up by an unmeasured number of rows; owner photo attached")
//     evidencePaths: ["<REPO>/photos/original/IMG_0001.jpg"],  // new evidence file(s) this release's analysis is based on
//     protectedConfig: [                  // build options that must hold these exact values across this release
//       { key: "<PROTECTED_CONFIG_KEY_1>", value: "<VALUE_1>" },
//       { key: "<PROTECTED_CONFIG_KEY_2>", value: "<VALUE_2>" }
//     ],
//     packageCmd: "<repo-relative packaging command, e.g. scripts/make-update-tar.sh --no-pico>",
//     testCommands: ["<test suite 1 command>", "<test suite 2 command>"],
//     commit: false                        // true to allow a commit IF the Check phase returns GO
//   }
//
// Returns { analysis, impl, check, record }.

export const meta = {
  name: 'firmware-release',
  description: 'Analyze an observed firmware defect from evidence, implement the traced fix, build and package, check protected config and byte-identity, then record the release honestly',
  phases: [
    { title: 'Analyze', detail: 'hash new evidence into the manifest, measure the defect, grade the cause, state the exact fix', model: 'opus' },
    { title: 'Implement', detail: 'apply exactly that fix behind a build option, build clean, bump version, test, package', model: 'sonnet' },
    { title: 'Check', detail: 'GO/NO-GO: fix matches defect, protected config intact, package byte-identical, manifest verifies', model: 'sonnet' },
    { title: 'Record', detail: 'write the release row and research-log entry; commit only if args.commit and GO', model: 'sonnet' },
  ],
}

if (!args || !args.repo || !args.version || !args.observation) {
  throw new Error('firmware-release requires args: {repo, version, observation, evidencePaths, protectedConfig, packageCmd, testCommands, commit}')
}

const REPO = args.repo
const VERSION = args.version
const OBSERVATION = args.observation
const EVIDENCE_PATHS = args.evidencePaths || []
const PROTECTED_CONFIG = args.protectedConfig || []
const PACKAGE_CMD = args.packageCmd || ''
const TEST_COMMANDS = args.testCommands || []
const ALLOW_COMMIT = args.commit === true

const PROTECTED_CONFIG_LIST = PROTECTED_CONFIG.map(function (c) {
  return c.key + '=' + c.value
}).join(', ') || '(none supplied -- treat every build option present before this release as protected by default and say so explicitly if any of them moved)'

// SAFETY is built by concatenation (no template literals anywhere in this file --
// a real parse failure on a backtick-quoted string hit the source session this
// toolkit is drawn from). Every phase below prepends this verbatim.
const SAFETY =
  'HARD SAFETY RULES for this entire workflow, all phases, no exceptions: ' +
  '(1) Never open, probe, or address any device node (a serial port, a USB device file, ' +
  'a debug/JTAG adapter) -- this is a 100% host-side workflow, source files and build ' +
  'artifacts only. ' +
  '(2) Never run a flashing command, a monitor command, or anything that opens a serial ' +
  'connection to a device (no esptool write/erase, no "idf.py flash", no "idf.py monitor", ' +
  'no equivalent for another toolchain) -- building and packaging are allowed, addressing a ' +
  'live device is not, ever, from this workflow. ' +
  '(3) Never run anything with sudo. ' +
  '(4) Never install, upgrade, or remove a system package, a language toolchain, or a ' +
  'dependency -- work with whatever is already set up in the project (its own env-setup ' +
  'script, if it has one, e.g. scripts/idf-env.sh or equivalent). ' +
  '(5) Never modify, move, rename, delete, or write derived output into the project\'s ' +
  'immutable evidence directory (this toolkit\'s convention: something like ' +
  '<REPO>/photos/original for photographs, or wherever this project keeps original captures ' +
  '-- check its own CLAUDE.md/README for the exact name if unsure). New evidence gets hashed ' +
  'INTO that directory\'s manifest, never edited once placed there; every derived/annotated ' +
  'file (a crop, an overlay, an extracted frame) goes into the project\'s analysis/scratch ' +
  'directory instead (this toolkit\'s convention: a sibling "analysis" directory, e.g. ' +
  '<REPO>/photos/analysis), never into the original directory and never as an output target ' +
  'of any command whose input was read from the original directory. ' +
  '(6) The following protected configuration keys must hold EXACTLY these values before and ' +
  'after every phase of this release -- do not change them, do not let a Kconfig default, a ' +
  'stale generated-config file, or an unrelated refactor move them, and re-verify by grep ' +
  'against the regenerated config at the end, not by assuming a diff would have shown it: ' +
  PROTECTED_CONFIG_LIST + '. ' +
  'Project root: "' + REPO + '" (quote it in every shell command -- the path may contain a ' +
  'space). Read this project\'s own CLAUDE.md/README first for anything these rules don\'t ' +
  'cover (its exact toolchain, its exact evidence-directory names, its own additional gates).'

// ---------------------------------------------------------------------------
// Phase 1: Analyze
// ---------------------------------------------------------------------------

const ANALYSIS_SCHEMA = {
  type: 'object',
  properties: {
    evidence_hashed: { type: 'array', items: { type: 'string' }, description: 'each new evidence path that was hashed into its manifest' },
    manifest_verified: { type: 'boolean' },
    manifest_verify_command: { type: 'string' },
    measurements: { type: 'string', description: 'the concrete, numeric measurement(s) taken from the evidence -- not a description, actual numbers/offsets/deltas' },
    candidate_causes_considered: { type: 'array', items: { type: 'string' } },
    cause: { type: 'string' },
    evidence_grade: { type: 'string', enum: ['CONFIRMED', 'STRONGLY INDICATED', 'POSSIBLE', 'UNKNOWN'] },
    evidence_grade_basis: { type: 'string' },
    exact_fix_file: { type: 'string' },
    exact_fix_constant_or_command: { type: 'string' },
    exact_fix_value: { type: 'string' },
    prediction: { type: 'string', description: 'what should be observed after the fix, stated concretely enough to be falsified' },
    next_experiment_if_prediction_fails: { type: 'string' },
  },
  required: [
    'evidence_hashed', 'manifest_verified', 'manifest_verify_command', 'measurements',
    'cause', 'evidence_grade', 'evidence_grade_basis',
    'exact_fix_file', 'exact_fix_constant_or_command', 'exact_fix_value',
    'prediction', 'next_experiment_if_prediction_fails',
  ],
}

phase('Analyze')
const analysis = await agent(
  SAFETY +
  '\nTASK -- Analyze an observed defect ahead of release ' + VERSION + '.\n' +
  'OBSERVATION (as reported, symptom not diagnosis): ' + OBSERVATION + '\n' +
  'NEW EVIDENCE FILES for this analysis: ' + JSON.stringify(EVIDENCE_PATHS) + '\n' +
  'Steps:\n' +
  '1. For each new evidence file: locate its evidence directory\'s hash manifest (this ' +
  'toolkit\'s convention: a sibling file such as ORIGINALS.sha256, in shasum -a 256 format, ' +
  'living alongside the immutable evidence directory -- read this project\'s hardware-recon ' +
  'notes or CLAUDE.md if the exact manifest path or convention isn\'t obvious). Append the new ' +
  'file\'s hash line if it is not already present, in the same format as the existing lines. ' +
  'Then re-verify the WHOLE manifest (every line, not just the new one) and report the exact ' +
  'verification command and its result -- every line must read OK; if any line does not, STOP ' +
  'and report that as the finding instead of proceeding.\n' +
  '2. Read the evidence (photo, capture, log -- whatever it is) directly. If it is an image and ' +
  'measuring the defect requires a closer look, crop a region with whatever image tool this ' +
  'host provides (e.g. sips on macOS, ImageMagick\'s convert/magick elsewhere) with output ' +
  'written ONLY into the analysis/scratch directory, never into the original evidence ' +
  'directory and never overwriting the source file. Take an actual numeric measurement from ' +
  'what you see (a pixel-row count, a byte offset, a timestamp delta, a voltage, whatever the ' +
  'defect is) -- do not settle for a qualitative description when a number is obtainable.\n' +
  '3. Cross-check the measurement against this project\'s own reverse-engineered constants and ' +
  'code (its hardware-constants notes, its firmware source, its protocol spec -- whatever is ' +
  'relevant to this defect). Consider more than one candidate cause where more than one is ' +
  'plausible, and say why you ruled each one out except the one you keep.\n' +
  '4. State the cause with an evidence grade (CONFIRMED / STRONGLY INDICATED / POSSIBLE / ' +
  'UNKNOWN) and the specific basis for that grade (do not grade CONFIRMED off a single ' +
  'observation if a second, independent check was available and skipped).\n' +
  '5. State the EXACT fix: which file, which named constant OR which exact command, and which ' +
  'exact value it should become. Not "adjust the offset" -- the actual value.\n' +
  '6. State what you would predict to observe after the fix is applied and re-tested, concrete ' +
  'enough to be falsified, and state the single next experiment you would run if that ' +
  'prediction turns out wrong.\n' +
  'Return the schema fields. Do not edit any source file in this phase -- analysis and ' +
  'measurement only.',
  { label: 'analyze-defect', phase: 'Analyze', model: 'opus', effort: 'high', schema: ANALYSIS_SCHEMA }
)

// ---------------------------------------------------------------------------
// Phase 2: Implement
// ---------------------------------------------------------------------------

const IMPL_SCHEMA = {
  type: 'object',
  properties: {
    fix_applied_summary: { type: 'string' },
    build_option_name: { type: 'string', description: 'the new or existing build-time option the fix lives behind, defaulting to the analysed value' },
    build_option_default: { type: 'string' },
    generated_config_file: { type: 'string', description: 'the toolchain\'s generated config file this project uses (e.g. an ESP-IDF sdkconfig or equivalent) -- discovered from this project\'s own build docs, not assumed' },
    generated_config_deleted_and_regenerated: { type: 'boolean' },
    build_command: { type: 'string' },
    build_warnings: { type: 'number' },
    build_errors: { type: 'number' },
    version_constant_bumped: { type: 'string' },
    handshake_patch_field_bumped: { type: 'string' },
    tests_run: { type: 'array', items: { type: 'object', properties: { command: { type: 'string' }, result: { type: 'string' } }, required: ['command', 'result'] } },
    image_path: { type: 'string' },
    image_size_bytes: { type: 'number' },
    package_command_used: { type: 'string' },
    package_path: { type: 'string' },
    package_sha256: { type: 'string' },
    member_hashes: { type: 'array', items: { type: 'object', properties: { member: { type: 'string' }, sha256: { type: 'string' } }, required: ['member', 'sha256'] } },
  },
  required: [
    'fix_applied_summary', 'build_option_name', 'build_option_default',
    'generated_config_file', 'generated_config_deleted_and_regenerated',
    'build_command', 'build_warnings', 'build_errors',
    'version_constant_bumped', 'handshake_patch_field_bumped',
    'tests_run', 'image_path', 'image_size_bytes',
    'package_command_used', 'package_path', 'package_sha256', 'member_hashes',
  ],
}

phase('Implement')
const impl = await agent(
  SAFETY +
  '\nTASK -- implement release ' + VERSION + '\'s fix, build, test, and package. Do NOT commit ' +
  'anything in this phase.\n' +
  'ANALYSIS from the previous phase (apply EXACTLY this fix, nothing broader): ' +
  JSON.stringify(analysis).slice(0, 6000) + '\n' +
  'Steps:\n' +
  '1. Apply exactly the fix named in exact_fix_file / exact_fix_constant_or_command / ' +
  'exact_fix_value above -- no unrelated cleanup, no touching a constant table that isn\'t the ' +
  'one implicated. Put it behind a build-time option (this project\'s Kconfig or equivalent) ' +
  'whose DEFAULT is the analysed value, so the fix is a real toggle, not a silent hardcode.\n' +
  '2. Discover this project\'s own generated-config file name and its exact ' +
  'reconfigure/build command from the project\'s own docs or env-setup script (this toolkit is ' +
  'deliberately toolchain-agnostic -- do not assume ESP-IDF\'s sdkconfig if this project uses ' +
  'something else). Delete the STALE generated config before reconfiguring/rebuilding -- a ' +
  'generated config can silently carry a value from before this change across a target switch ' +
  'or a defaults change, which is the single most common release-to-release build mistake this ' +
  'checklist exists to catch. Then build.\n' +
  '3. The build must produce ZERO warnings and zero errors. If it does not, fix the cause (not ' +
  'by suppressing the warning) and rebuild before continuing.\n' +
  '4. Bump the firmware\'s own version constant/string AND its host-visible handshake/protocol ' +
  'patch field TOGETHER, to the same new value -- a host tool that reads the protocol field, ' +
  'not the human-readable string, must see the bump too or it will silently believe it is ' +
  'talking to the previous build.\n' +
  '5. Run every command in this list, in order, and report each one\'s pass/fail result ' +
  'individually (do not summarize as one aggregate line): ' + JSON.stringify(TEST_COMMANDS) + '\n' +
  '6. Package the build output by running exactly: ' + PACKAGE_CMD + '\n' +
  '7. Report the image path and size, the package path, the package\'s own sha256, and the ' +
  'sha256 of EACH member inside the package individually (an outer-archive hash alone does not ' +
  'tell a later reader WHICH member changed if something regresses -- per-member hashes do).\n' +
  'Return the schema fields.',
  { label: 'implement-fix', phase: 'Implement', model: 'sonnet', effort: 'high', schema: IMPL_SCHEMA }
)

// ---------------------------------------------------------------------------
// Phase 3: Check
// ---------------------------------------------------------------------------

const CHECK_SCHEMA = {
  type: 'object',
  properties: {
    fix_matches_defect_direction_and_magnitude: { type: 'boolean' },
    fix_matches_defect_evidence: { type: 'string' },
    unrelated_constant_table_changed: { type: 'boolean', description: 'true means a PROBLEM was found -- something outside the named fix changed' },
    unrelated_constant_table_evidence: { type: 'string' },
    all_affected_code_paths_consistent: { type: 'boolean', description: 'every code path this fix should touch (e.g. a full-refresh AND a partial-refresh render path, if this device has both, or any other place the same value is applied) applies it the same way' },
    all_affected_code_paths_evidence: { type: 'string' },
    protected_config_checks: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          key: { type: 'string' },
          expected_value: { type: 'string' },
          grep_command: { type: 'string' },
          grep_output: { type: 'string' },
          match: { type: 'boolean' },
        },
        required: ['key', 'expected_value', 'grep_command', 'grep_output', 'match'],
      },
    },
    package_member_byte_identical_to_build_output: { type: 'boolean' },
    package_member_verification_command: { type: 'string' },
    evidence_manifest_still_verifies: { type: 'boolean' },
    evidence_manifest_verification_command: { type: 'string' },
    problems: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          problem: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'major', 'minor'] },
        },
        required: ['file', 'problem', 'severity'],
      },
    },
    verdict: { type: 'string', enum: ['GO', 'NO-GO'] },
    summary: { type: 'string' },
  },
  required: [
    'fix_matches_defect_direction_and_magnitude', 'fix_matches_defect_evidence',
    'unrelated_constant_table_changed', 'unrelated_constant_table_evidence',
    'all_affected_code_paths_consistent', 'all_affected_code_paths_evidence',
    'protected_config_checks',
    'package_member_byte_identical_to_build_output', 'package_member_verification_command',
    'evidence_manifest_still_verifies', 'evidence_manifest_verification_command',
    'problems', 'verdict', 'summary',
  ],
}

phase('Check')
const check = await agent(
  SAFETY +
  '\nTASK -- adversarially check release ' + VERSION + ' before it is recorded. Default to ' +
  'NO-GO on anything you cannot personally verify against the actual files -- do not accept the ' +
  'prior phases\' own summaries as proof of themselves.\n' +
  'ANALYSIS: ' + JSON.stringify(analysis).slice(0, 3000) + '\n' +
  'IMPLEMENTATION REPORT: ' + JSON.stringify(impl).slice(0, 3000) + '\n' +
  'PROTECTED CONFIGURATION (must hold exactly these values): ' + JSON.stringify(PROTECTED_CONFIG) + '\n' +
  'Verify, each one against the actual current state of the tree/build/package (not against the ' +
  'prior phases\' claims about it):\n' +
  '1. The applied fix matches the measured defect in DIRECTION and MAGNITUDE (a fix that would ' +
  'move the symptom the wrong way, or by the wrong amount, is not a match even if it changes ' +
  'the right constant).\n' +
  '2. No constant table outside the named fix changed (diff the actual change against the ' +
  'named file/constant; anything else that moved is a problem).\n' +
  '3. Every code path this project has for applying the same kind of change (for example: if ' +
  'this device renders via both a full-refresh and a partial-refresh path, or has more than one ' +
  'place a window/offset/parameter like this is set) applies the fix consistently -- read each ' +
  'path, don\'t assume symmetry.\n' +
  '4. Every protected configuration key still holds its exact expected value in the freshly ' +
  'REGENERATED config file (impl.generated_config_file) -- run an actual grep for each key ' +
  'against that file and quote the command and its real output per key; a value that used to ' +
  'be right before this release started is not evidence it still is now.\n' +
  '5. The packaged artifact\'s firmware-image member is BYTE-IDENTICAL to the build output (a ' +
  'checksum/diff between the two, not merely "the package command exited 0").\n' +
  '6. The evidence directory\'s hash manifest still verifies in full (re-run the verification, ' +
  'do not reuse the Analyze phase\'s report of having done so).\n' +
  'List every problem found (file, problem, severity). Return GO only if there are no critical ' +
  'or major problems and every check above passed; otherwise NO-GO.',
  { label: 'check-release', phase: 'Check', model: 'sonnet', effort: 'high', schema: CHECK_SCHEMA }
)

// ---------------------------------------------------------------------------
// Phase 4: Record
// ---------------------------------------------------------------------------

const shouldCommit = ALLOW_COMMIT && check && check.verdict === 'GO'

const RECORD_SCHEMA = {
  type: 'object',
  properties: {
    release_doc_path: { type: 'string' },
    release_row_written: { type: 'boolean' },
    research_log_path: { type: 'string' },
    research_log_entry_appended: { type: 'boolean' },
    first_boot_status_recorded: { type: 'string', description: 'must be an honest "not yet performed" unless an install has actually happened' },
    committed: { type: 'boolean' },
    commit_hash: { type: 'string' },
    commit_skipped_reason: { type: 'string' },
  },
  required: [
    'release_doc_path', 'release_row_written', 'research_log_path', 'research_log_entry_appended',
    'first_boot_status_recorded', 'committed',
  ],
}

phase('Record')
const record = await agent(
  SAFETY +
  '\nTASK -- record release ' + VERSION + ' whether or not it passed Check; never round a ' +
  'NO-GO up to a clean-looking row.\n' +
  'IMPLEMENTATION REPORT: ' + JSON.stringify(impl).slice(0, 3000) + '\n' +
  'CHECK RESULT: ' + JSON.stringify(check).slice(0, 3000) + '\n' +
  'Steps:\n' +
  '1. Add one release row to this project\'s running release record (its docs/releases.md or ' +
  'equivalent; find the existing table and match its exact column conventions). Use the field ' +
  'list and worked example in ' +
  '"${CLAUDE_PLUGIN_ROOT}/skills/custom-firmware-bringup/references/release-row.md" (plugin ' +
  'install) or "skills/custom-firmware-bringup/references/release-row.md" (repo checkout) as ' +
  'the shape: version, image path/size, package path, package hash, member hashes, the exact ' +
  'build command, which tests ran and their result, changes vs. the previous release, and ' +
  'notes (including that the protected-configuration keys were re-verified this release, and ' +
  'the Check verdict plus any open problems if it was NO-GO). Fill in EVERY field -- an empty ' +
  'field is a question the next reader has to re-answer from scratch.\n' +
  '2. Set the first-boot field to "not yet performed" -- literally that, or this project\'s ' +
  'equivalent honest phrasing -- unless an actual on-device install has already happened and ' +
  'been reported to you as having happened; never imply a test that has not occurred.\n' +
  '3. Append one entry to this project\'s append-only research log (its docs/research-log.md ' +
  'or equivalent) using the format in ' +
  '"${CLAUDE_PLUGIN_ROOT}/templates/research-log-entry.md" (plugin install) or ' +
  '"templates/research-log-entry.md" (repo checkout) -- DATE/TIME (read the real date/time ' +
  'with your own date command, this workflow script cannot supply one), PHASE, ACTION, ' +
  'COMMAND, RESULT, INTERPRETATION, CONFIDENCE, NEXT STEP. Append only -- never edit or delete ' +
  'an existing entry.\n' +
  '4. Commit: ' + (shouldCommit
    ? 'args.commit is true AND Check returned GO, so commit the release\'s changed source, ' +
      'docs, and (if this project tracks it) the new evidence file(s) -- verify nothing under ' +
      'a gitignored build/backup/capture directory and no *.bin/*.tar is staged before ' +
      'committing, then commit with a message naming the release and its one-line change.'
    : 'do NOT commit anything in this run -- ' +
      (ALLOW_COMMIT
        ? 'Check returned NO-GO, so a commit is withheld regardless of args.commit.'
        : 'args.commit was not set to true for this run.')
  ) + '\n' +
  'Return the schema fields, including commit_skipped_reason if committed is false.',
  { label: 'record-release', phase: 'Record', model: 'sonnet', effort: 'medium', schema: RECORD_SCHEMA }
)

return { analysis, impl, check, record }
