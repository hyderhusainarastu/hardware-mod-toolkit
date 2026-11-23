# hardware-mod-toolkit

Skills, subagent prompts, workflow scripts, templates and host scripts for reverse-engineering
and modding an embedded device without bricking it. Skills use the SKILL.md format.

## Using this in your project

- Start with `docs/PLAYBOOK.md` (fourteen phases, each with a gate). Do Phase 0 first.
- Load a skill from `skills/<name>/SKILL.md` when the task matches its description. Phase to
  skill mapping is in the playbook.
- Never write to, erase or flash a device until a full read-only backup exists AND a restore
  of it has been tested. A backup you have not test-restored is not a backup.
- Work one physical experiment at a time. Ask the owner before any step that touches the unit.
- Grade every hardware claim CONFIRMED, STRONGLY INDICATED, POSSIBLE or UNKNOWN, and cite the
  evidence file.
- Do not open real USB or serial ports from automated runs. Use the project's mock-mode
  environment switch (see `skills/hardware-in-the-loop-testing/SKILL.md`).
- Never commit captures, dumps, vendor firmware, photographs of a specific unit, SSIDs, MAC
  addresses, serial numbers or home-directory paths. Run `skills/publish-hygiene` before
  publishing.
- Scripts in `scripts/` are read-only or host-only. `mcu-backup-window.sh` is dry-run by
  default and refuses write, erase and efuse arguments. Run it only when the owner says so.
- The six scripts in `workflows/` are Claude Code workflows. In any other tool, follow
  `docs/workflows-as-steps.md` instead.
- Install: `./install.sh --agents --project DIR` links the skills into `DIR/.agents/skills`
  (Codex, Cursor, Gemini CLI). `./install.sh --claude` links them into `~/.claude/skills`.
  `./scripts/install-local.sh --codex --target DIR` does the same for `.agents/skills`.
  Add `--dry-run` to preview. No PROMPT.md is shipped per skill; see `PROMPT.md` for a paste
  version of the core rules.
- Placeholders such as `<DEVICE>` and `/Users/<you>` in docs are intentional. Fill them for
  your project; do not guess values.

## Working on this repo

- Test: `bash tests/test_install.sh` (offline; uses a temporary HOME and project).
- Syntax check: `bash -n install.sh scripts/*.sh`.
- Keep each SKILL.md `description` at or under 300 characters and the body under 400 lines (aim for 300 or fewer);
  put detail in the skill's `references/` directory.
- Do not add vendor binaries, captures or photographs. `.gitignore` blocks the common ones.
- Do not edit `.claude-plugin/plugin.json` author fields without the owner's say-so.

<!-- cc-only -->
- As a Claude Code plugin, `skills/`, `agents/` and `workflows/` load from the checkout.
  Subagent definitions are in `agents/`. Run a workflow as `/hardware-mod-toolkit:<name>`.
<!-- /cc-only -->
