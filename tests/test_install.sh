#!/usr/bin/env bash
# Offline test for install.sh: install all targets, re-run, uninstall, assert empty.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd -P)
H=$(mktemp -d); P=$(mktemp -d)
trap 'rm -rf "$H" "$P"' EXIT
export HOME=$H
fail() { echo "FAIL: $*" >&2; exit 1; }
empty() { [ -z "$(find "$1" -mindepth 1 -print -quit)" ]; }

"$HERE/install.sh" >/dev/null
empty "$H" && empty "$P" || fail "no-flag run changed files"

for mode in link copy; do
  c=; [ "$mode" = copy ] && c=--copy
  run() { "$HERE/install.sh" --claude --agents --gemini --cursor --copilot --project "$P" $c "$@" >/dev/null; }
  run; run
  [ -n "$(find "$P" -mindepth 1 -print -quit)" ] || fail "$mode: nothing installed"
  "$HERE/install.sh" --claude --user $c >/dev/null
  "$HERE/install.sh" --agents --user $c >/dev/null
  "$HERE/install.sh" --claude --agents --gemini --cursor --copilot --project "$P" --uninstall >/dev/null
  "$HERE/install.sh" --claude --agents --project "$P" --uninstall >/dev/null
  "$HERE/install.sh" --claude --agents --user --uninstall >/dev/null
  "$HERE/install.sh" --claude --agents --gemini --cursor --copilot --project "$P" --uninstall >/dev/null  # idempotent
  empty "$P" || fail "$mode: project not empty: $(find "$P" -mindepth 1)"
  empty "$H" || fail "$mode: HOME not empty: $(find "$H" -mindepth 1)"
done

# Refuses to overwrite foreign paths; preserves foreign file content.
mkdir -p "$P/.agents/skills"
mkdir "$P/.agents/skills/hardware-recon"
if "$HERE/install.sh" --agents --project "$P" >/dev/null 2>&1; then fail "overwrote foreign dir"; fi
rm -r "$P/.agents"
printf 'mine\n' > "$P/AGENTS.md"
"$HERE/install.sh" --cursor --project "$P" >/dev/null
"$HERE/install.sh" --cursor --project "$P" --uninstall >/dev/null
[ "$(cat "$P/AGENTS.md")" = mine ] || fail "foreign AGENTS.md changed"

# install-local.sh --codex: link, idempotent re-run, refuse foreign dir, no change outside target.
rm -rf "$P/.agents"
"$HERE/scripts/install-local.sh" --codex --target "$P" >/dev/null
"$HERE/scripts/install-local.sh" --codex --target "$P" >/dev/null
[ -L "$P/.agents/skills/mcu-safe-backup" ] || fail "--codex did not link"
rm -r "$P/.agents"
mkdir -p "$P/.agents/skills/hardware-recon"
"$HERE/scripts/install-local.sh" --codex --target "$P" >/dev/null
[ -d "$P/.agents/skills/hardware-recon" ] && [ ! -L "$P/.agents/skills/hardware-recon" ] || fail "--codex overwrote foreign dir"
rm -r "$P/.agents"
empty "$H" || fail "HOME not empty after --codex"
echo "test_install: OK"
