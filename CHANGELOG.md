# Changelog

## Unreleased

- Add AGENTS.md as the single instruction file, with CLAUDE.md, GEMINI.md and
  .github/copilot-instructions.md pointing at it.
- Add PROMPT.md, a paste version of the core rules for chat assistants.
- Add `docs/workflows-as-steps.md`: each workflow script rewritten as numbered manual steps.
- Add `install.sh` (Claude Code, `.agents/skills`, and pointer blocks for Gemini, Cursor and
  Copilot) and a `--codex` target in `scripts/install-local.sh`.
- Add `tests/test_install.sh` and a CI workflow that runs it.
- README: per-platform install table, "Using with other AI tools", related repositories;
  remove the "Built with" section and replace the `<owner>` placeholder.
- Shorten every SKILL.md description to 300 characters or fewer.

## 0.1.0

- Initial release: eleven skills, five subagents, six workflows, eight templates, six host
  scripts, playbook and pitfall catalogue.
