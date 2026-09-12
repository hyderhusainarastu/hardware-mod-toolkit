// publish-audit.js — six-category parallel scan, completeness + legal verification,
// and a nine-part publication plan for taking a private hardware-mod repo public.
//
// RUN RECIPE
//   As a plugin workflow (after install-local.sh or a marketplace install):
//     /hardware-mod-toolkit:publish-audit
//     then supply args when prompted, or pass them programmatically via the Workflow tool:
//       Workflow({ name: "publish-audit", args: {
//         repo: "/absolute/path/to/private-repo",   // quote paths with spaces at the shell;
//                                                    // pass the raw string here, no quoting needed
//         planOut: "/absolute/path/to/scratch/publication-plan.md",
//         goal: {
//           repoName: "<REPO>",                      // the public repo's intended name
//           licence: "MIT (code) + CC BY 4.0 (docs)", // or whatever you've decided
//           mediaPolicy: "diagrams-first; curated EXIF-stripped subset under 150MB; originals as a release asset",
//           forbiddenTerms: ["claude", "anthropic", "assistant", "agent", "subagent", "workflow", "moderator"]
//         }
//       }})
//   As a project-local named workflow (after install-local.sh --self, or a manual copy into
//   .claude/workflows/publish-audit.js): same args shape, invoked the same way.
//
// OUTPUT
//   Returns { planPath, counts }. planPath is args.planOut — the Synthesize-phase agent writes
//   the nine-part publication plan there directly with its own file tools; the script itself
//   never touches the filesystem. That plan file is the INPUT to publish-export.js (pass its
//   path as that workflow's planIn arg) — this workflow decides what must change, that one
//   builds the change.
//
// ARGS SHAPE
//   {
//     repo: string,                 // absolute path to the PRIVATE repo being audited (read-only)
//     planOut: string,              // absolute path where the synthesis agent writes the plan
//     goal: {
//       repoName: string,           // intended public repo name, for framing prompts
//       licence: string,            // e.g. "MIT" or "MIT (code) + CC BY 4.0 (docs)"
//       mediaPolicy: string,        // e.g. "diagrams over photos; strip EXIF; <150MB target"
//       forbiddenTerms: [string],   // case-insensitive terms that must not appear in the public
//                                   // repo — this is how you encode "no mention of the tooling
//                                   // or process that built this" without hardcoding any one
//                                   // vendor's tool names into the workflow itself
//     }
//   }

export const meta = {
  name: 'publish-audit',
  description: 'Audit a private hardware-mod repo for anything that must not be published (secrets, PII, vendor IP, forbidden tooling/process terms, oversized or EXIF-bearing media, portability blockers) and synthesize a publication plan',
  phases: [{ title: 'Scan' }, { title: 'Verify' }, { title: 'Synthesize' }],
}

const REPO = args.repo
const PLAN_OUT = args.planOut
const REPO_NAME = args.goal.repoName
const LICENCE = args.goal.licence
const MEDIA_POLICY = args.goal.mediaPolicy
const FORBIDDEN_TERMS = args.goal.forbiddenTerms

const SAFETY = 'SAFETY: the repo under audit is at "' + REPO + '" (the path may contain spaces; ' +
  'quote it in every shell command). This is a READ-ONLY audit: do not edit, move, rename, or ' +
  'delete anything inside the audited repo, and do not create files inside it either — write ' +
  'any working notes only to your own scratch space. Do not run any git command that changes ' +
  'state (no add / commit / checkout / reset / rebase / filter-repo / push), even to "clean up" ' +
  'a finding — describe the recommended fix, never apply it. Never touch, open, or attempt to ' +
  'talk to any USB, serial, or other hardware device attached to this machine, under any ' +
  'circumstance. If the repo defines a mock-mode / no-hardware environment variable for its own ' +
  'tests or scripts (grep its README, CLAUDE.md, or scripts/ for something like a *_FORCE_MOCK ' +
  'or *_MOCK env var), set it before running anything that could otherwise probe for real ' +
  'hardware; if you cannot find one and a script looks like it might touch a device, do not run ' +
  'it — read it instead. '

const GOAL = 'GOAL: the owner wants to publish this project publicly as a new, standalone ' +
  'repository named "' + REPO_NAME + '" so a stranger can replicate and modify the hardware mod ' +
  'from a fresh clone. Hard requirements, in the owner\'s own words: (1) nothing here may violate ' +
  'any law — copyright in vendor firmware or vendor assets, trade secrets, trademarks, anti-' +
  'circumvention statutes (DMCA 1201(f) and equivalents) all apply; (2) NONE of the following ' +
  'terms may appear anywhere in the published content or its commit history, checked case-' +
  'insensitively (these encode whatever internal tooling or process actually built this repo, ' +
  'which is nobody else\'s business and not something a replicator needs): ' +
  FORBIDDEN_TERMS.join(', ') + '; (3) no credentials, Wi-Fi network names or passwords, MAC ' +
  'addresses, device or host serial numbers, a real person\'s name/username/email, or absolute ' +
  'home-directory paths may survive into the public repo. Target licence: ' + LICENCE + '. Media ' +
  'policy: ' + MEDIA_POLICY + '. Publication will be built as a curated EXPORT into a fresh ' +
  'repository with fresh history — the private repo itself is never rewritten and never pushed ' +
  'anywhere — so express every finding as: the file, exactly what to drop / redact / rewrite in ' +
  'the export, and why. '

const FINDINGS = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          kind: { type: 'string' },
          detail: { type: 'string' },
          action: { type: 'string' },
          severity: { type: 'string' },
        },
        required: ['file', 'kind', 'detail', 'action', 'severity'],
      },
    },
    method: { type: 'string' },
  },
  required: ['summary', 'findings', 'method'],
}

const SCANS = [
  {
    key: 'secrets-pii',
    prompt: 'SCAN for secrets and personal data across ALL tracked files (git ls-files) AND the ' +
      'full git history (git log -p is fine, read-only; also git log --all --format=%an%n%ae%n%b ' +
      'for author identities): network names and passwords (Wi-Fi SSIDs/PSKs, Bluetooth device ' +
      'names), MAC addresses in both notations (xx:xx:xx:xx:xx:xx and bare 12-hex), device and ' +
      'host serial numbers or USB serial strings, a real person\'s name or username, machine ' +
      'names/hostnames, absolute home-directory paths (/Users/<name>/ and /home/<name>/), IP ' +
      'addresses, API tokens or keys, and any session/run URL a tool may have stamped into a ' +
      'commit message or file. Watch the trap in the other direction: a document that describes ' +
      'a past leak ("commit abc123 briefly contained the office SSID before it was redacted") is ' +
      'not itself a leak — do not flag the description, only flag an actual reachable instance of ' +
      'the sensitive value. For every real finding, give the exact file and line, and the exact ' +
      'replacement (a relative-path form, a placeholder token, or "drop this file/line").',
  },
  {
    key: 'tooling-and-process',
    prompt: 'SCAN every tracked file for the forbidden terms the owner named — ' +
      FORBIDDEN_TERMS.join(', ') +
      ' — case-insensitively, counted per file (grep -ic for each term against each tracked ' +
      'file; whole-word match for any term three characters or shorter to avoid noise). Classify ' +
      'every file that has at least one hit as DROP (the file exists only because of the tooling ' +
      'or process that built the repo — an internal operating-rules file, a session-state note, a ' +
      'process log), REWRITE (real technical content wrapped in tooling/process language that can ' +
      'be stripped without losing the technical content), or CLEAN (a hit that turns out to be a ' +
      'false positive, e.g. a common English word matched by an overly short term — say so ' +
      'explicitly). Separately: if any shipped feature exists ONLY because of this tooling (an ' +
      'integration widget, a build flag, a CLI mode gated on the tool\'s presence), list every ' +
      'file and every reference to it — source, tests, build manifests, README/CLI help text — ' +
      'that would have to change to remove that feature cleanly without leaving a dangling import, ' +
      'a broken test, or a stale doc reference.',
  },
  {
    key: 'vendor-ip',
    prompt: 'SCAN for vendor intellectual property and legal exposure: vendor firmware binaries, ' +
      'raw memory/flash dumps, partition or NVS images, disassembly listings or decompiled code, ' +
      'verbatim vendor source or documentation text quoted beyond a short attributed excerpt, ' +
      'copied vendor assets (fonts, bitmaps, icons pulled out of the vendor\'s own firmware or ' +
      'app), vendor download URLs, and long quoted vendor log strings. For any reverse-engineered ' +
      'table (register maps, init sequences, protocol framing) determined by observing the ' +
      'device\'s own behaviour: make the argument, explicitly, for presenting it as an ' +
      'interoperability specification (facts and interfaces determined through observation, not ' +
      'copied vendor source) rather than as "here is the vendor\'s byte blob" — note anywhere the ' +
      'framing in the current text undermines that distinction. Check whether any packaging or ' +
      'build script embeds a vendor archive directly versus requiring the user to supply their ' +
      'own copy of firmware they already legitimately own; check trademark and product-name usage ' +
      '(nominative use with an unaffiliated-disclaimer is normally fine, reproducing vendor ' +
      'marketing claims is not); check third-party code licence compatibility for anything ' +
      'vendored (GPL/Apache/MIT components) and whether their licence terms and attribution are ' +
      'actually satisfied in the current tree. Report file:line, recommended action, and severity, ' +
      'plus a short section on exactly what a NOTICE/LEGAL file should state to cover: no vendor ' +
      'code or binary redistributed, interoperability-reverse-engineering framing, trademark ' +
      'disclaimer, and no-warranty / physical-recovery-risk language.',
  },
  {
    key: 'media',
    prompt: 'SCAN every image, screenshot, and media file in the repo: total size and file count ' +
      'per directory, the largest individual files, any file over a typical git host\'s single-' +
      'file limit (100MB) or that would push total repo size past roughly 1GB. For every photo, ' +
      'read its EXIF metadata (exiftool if available, else python3 with Pillow, else the ' +
      'platform\'s built-in metadata CLI) for GPS coordinates, the capturing device\'s serial ' +
      'number, and any owner name embedded by the camera or editing software. Cross-reference ' +
      'against the docs to see which images are actually cited/referenced versus orphaned. Given ' +
      'the owner\'s stated media policy — ' + MEDIA_POLICY + ' — recommend the concrete strategy: ' +
      'which images to keep versus replace with a diagram, a target max dimension/quality/byte ' +
      'budget for anything kept, an EXIF-stripping step, whether to keep a checksum manifest of ' +
      'the originals as provenance without publishing the originals themselves, and whether the ' +
      'full original set (if any) should ship as a release asset outside git rather than tracked. ' +
      'Do not modify any media file yourself — this is a read-only scan.',
  },
  {
    key: 'docs-triage',
    prompt: 'Read every document a stranger who wants to replicate and modify this project would ' +
      'encounter (README, top-level markdown, everything under a docs/ or notes/ tree) and ' +
      'classify each one: KEEP AS IS (already a clean technical reference — a protocol spec, a ' +
      'pinout table, a bring-up procedure), REWRITE (real technical content wrapped in project-' +
      'management or session narrative — a phase-by-phase roadmap, a decision log with internal ' +
      'timestamps, an incident report written as session notes), or DROP (pure session state, ' +
      'internal operating rules for whatever tool ran the project, scratch brainstorm notes with ' +
      'nothing a reader needs). For every REWRITE or DROP verdict, explicitly list every fact ' +
      'graded as confirmed/verified in that document that does NOT already appear in a document ' +
      'that will survive — those facts must be migrated before the source is rewritten or deleted, ' +
      'and losing one silently is the single most common failure mode of this kind of cleanup. ' +
      'Also assess whether the top-level structure itself reads as a project-management artifact ' +
      '(a numbered phase roadmap as the README\'s spine) rather than something a newcomer can ' +
      'navigate by subsystem, and if so propose an explicit architecture-first table of contents ' +
      '(hardware architecture, buses/protocol, firmware, host tooling, worked examples, and so ' +
      'on, adapted to what this specific project actually has) mapping each proposed public ' +
      'document to the private document(s) it should be built from.',
  },
  {
    key: 'portability',
    prompt: 'SCAN for everything that would stop a stranger, on a machine that has never seen ' +
      'this project, from cloning it and reaching a working build by following only the README: ' +
      'absolute paths anywhere in scripts, docs, or config (grep for /Users/ and /home/); ' +
      'machine-specific environment assumptions (a toolchain install path hardcoded instead of an ' +
      'environment variable with a documented default); files a build or packaging step depends ' +
      'on that are gitignored or simply untracked (a vendor archive a packaging script expects to ' +
      'find locally, a large derived asset, a helper binary built out-of-band); a missing top-' +
      'level LICENSE file or missing package metadata (author/licence fields in a manifest); tests ' +
      'that read the actual developer\'s home directory or a personal cache path instead of a ' +
      'fixture; undocumented toolchain version pins (name the exact SDK/compiler/language version ' +
      'actually required, not "recent"); and the largest tracked files by size (git ls-files with ' +
      'sizes, top 30) as a check against anything that shouldn\'t be tracked at all. List each ' +
      'with file:line and the concrete fix.',
  },
]

phase('Scan')
const scans = await parallel(SCANS.map(function (s) {
  return function () {
    return agent(
      SAFETY + GOAL + s.prompt +
        ' Return structured findings with severity BLOCKER (illegal or flatly forbidden to ' +
        'publish), HIGH (violates an explicit owner requirement), MEDIUM (should be fixed for ' +
        'quality/credibility but is not a hard blocker), or LOW (nice to have).',
      { label: 'scan:' + s.key, phase: 'Scan', model: 'sonnet', effort: 'high', schema: FINDINGS }
    )
  }
}))
const all = scans.filter(Boolean)
log('scan findings: ' + all.reduce(function (n, s) { return n + s.findings.length }, 0) + ' across ' + all.length + '/' + SCANS.length + ' scans (a missing scan means that agent errored — see the run log)')

phase('Verify')
const scanSummary = all.map(function (s) {
  return { summary: s.summary, n: s.findings.length, files: s.findings.map(function (f) { return f.file }) }
})
const vendorFindings = all.flatMap(function (s) {
  return s.findings.filter(function (f) {
    return /vendor|copyright|licen|trademark|dmca|dump|firmware|asset|disassem/i.test(f.kind + ' ' + f.detail)
  })
})
const verify = await parallel([
  function () {
    return agent(
      SAFETY + GOAL +
        'Adversarially verify COMPLETENESS of the six scans above. Their summaries: ' +
        JSON.stringify(scanSummary, null, 1) +
        '\nIndependently re-scan the repo with DIFFERENT techniques than a plain text grep would ' +
        'use: run strings on any binary or capture file and grep that output for the same secret ' +
        'and forbidden-term patterns; check git log --all --format=%an%n%ae%n%b | sort -u for any ' +
        'author identity or process phrase the scans might have missed because it only ever ' +
        'appeared in a commit message, not a file; check for the forbidden terms and personal-' +
        'data patterns inside filenames themselves, not just file contents; check any file the ' +
        'scans may have skipped as "binary" or "too large". List everything the six scans MISSED, ' +
        'each with file:line, kind, and severity, in the same findings schema. Also state ' +
        'explicitly whether a curated export built with fresh history (a brand-new single commit, ' +
        'no carried-over history) is sufficient on its own to eliminate every historical secret ' +
        'and every tool-attribution trailer or session URL — true if and only if no file\'s ' +
        'CONTENT (as opposed to history alone) still carries one; verify this against the actual ' +
        'current tree rather than assuming it.',
      { label: 'verify:completeness', phase: 'Verify', model: 'opus', effort: 'high', schema: FINDINGS }
    )
  },
  function () {
    return agent(
      SAFETY + GOAL +
        'You are a counsel-minded reviewer — not formal legal advice, but a careful, specific ' +
        'engineering-legal analysis a competent non-lawyer engineer would want before publishing. ' +
        'Review these vendor-IP-related findings: ' + JSON.stringify(vendorFindings, null, 1) +
        '\nRead the actual files each finding cites. For each item, decide one of: PUBLISH AS IS / ' +
        'PUBLISH WITH CHANGE (state exactly what changes) / DO NOT PUBLISH, and give the legal ' +
        'basis in plain terms: facts and interfaces are not copyrightable; interoperability ' +
        'reverse engineering has real legal footing (DMCA 1201(f) in the US, the EU Software ' +
        'Directive 2009/24/EC Article 6, and general fair-use/fair-dealing considerations) ' +
        'PROVIDED no technical protection measure was actually circumvented to obtain the ' +
        'information — check the cited files for whether that is true here; vendor binaries and ' +
        'assets themselves must not be redistributed regardless of how the surrounding analysis is ' +
        'framed; nominative use of a product/vendor name to describe interoperability is normally ' +
        'fine with a clear unaffiliated-disclaimer; a packaging flow should require the user to ' +
        'supply their own vendor firmware rather than embedding one. Pay particular attention to ' +
        'whether any reverse-engineered table is currently presented as "copied from the vendor" ' +
        'rather than as a determined interoperability fact — recommend the reframing where that ' +
        'gap exists. Return findings in the schema (action = the PUBLISH verdict) plus, in your ' +
        'summary, the exact wording you\'d put in a NOTICE/LEGAL.md section and a README ' +
        'disclaimer paragraph covering: no vendor code/firmware redistributed, interoperability-' +
        'reverse-engineering framing, trademark disclaimer, and no-warranty / recovery-risk.',
      { label: 'verify:legal', phase: 'Verify', model: 'opus', effort: 'high', schema: FINDINGS }
    )
  },
])
const verifyOk = verify.filter(Boolean)

phase('Synthesize')
const synthPayload = JSON.stringify({ scans: all, verify: verifyOk }, null, 1).slice(0, 180000)
const synth = await agent(
  SAFETY + GOAL +
    'Synthesize a publication plan from these scan and verification results: ' + synthPayload +
    '\nWrite the plan as a single markdown file to exactly this path: "' + PLAN_OUT + '" (create ' +
    'parent directories if needed; this path is your own scratch output, not inside the audited ' +
    'repo, so writing here is fine). The plan must have exactly these nine sections, in this ' +
    'order, and be concrete — cite real files and real replacement text, not generic advice: ' +
    '(1) BLOCKERS that must be resolved before anything goes public, each with the file and the ' +
    'required action; (2) the DROP list — every file/directory excluded from the export, with ' +
    'why; (3) the REDACT/REWRITE list, grouped by document, as a numbered rule set R1..Rn, each ' +
    'rule stated as "pattern -> replacement" so it can be independently re-grepped later; (4) the ' +
    'forbidden-tooling/feature-removal checklist — every file and reference that must change to ' +
    'remove any tooling-only feature cleanly; (5) the media strategy — what ships, what\'s ' +
    'replaced with a diagram, target size/quality, EXIF handling, whether originals ship as a ' +
    'release asset; (6) the NOTICE/LEGAL and README-disclaimer wording, verbatim, ready to paste; ' +
    '(7) the licence recommendation for code and for docs, with the reasoning; (8) the proposed ' +
    'public repo layout and a docs table of contents mapping each public doc to its private ' +
    'source(s); (9) the pre-push verification checklist an independent reviewer (a different ' +
    'agent or person, per this toolkit\'s publish-hygiene skill) will run against the finished ' +
    'export before it is ever pushed — the exact grep patterns for every forbidden term and every ' +
    'PII/secret pattern from this audit, the forbidden-file check, the size checks, and which ' +
    'tests/builds must pass from a genuinely fresh checkout. Keep the whole plan under roughly ' +
    '1800 words; prefer a short, specific sentence per item over a paragraph. After writing the ' +
    'file, read it back to confirm it saved correctly, then return its findings count as your ' +
    'structured output.',
  { label: 'synthesize', phase: 'Synthesize', model: 'opus', effort: 'high' }
)

return {
  planPath: PLAN_OUT,
  counts: all.map(function (s) { return { n: s.findings.length, summary: s.summary } }),
}
