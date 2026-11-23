#!/usr/bin/env bash
# Multi-skill installer for hardware-mod-toolkit: installs every skills/<name>/ directory.
# Adapted from the shared single-skill installer.
# Skill install locations, verified 2026-11-23 against current official docs:
#   Claude Code  ~/.claude/skills/<name>/ (personal), .claude/skills/<name>/ (project)
#                https://code.claude.com/docs/en/skills
#   Codex        $HOME/.agents/skills (user), <repo>/.agents/skills (project; scanned from cwd up to repo root)
#                https://learn.chatgpt.com/docs/build-skills  (redirected from https://developers.openai.com/codex/skills)
#   Gemini CLI   ~/.gemini/skills or ~/.agents/skills (user); .gemini/skills or .agents/skills (workspace)
#                https://geminicli.com/docs/cli/skills/
#   Cursor       .agents/skills, .cursor/skills (project); ~/.agents/skills, ~/.cursor/skills (user)
#                https://cursor.com/docs/context/skills
# Copilot has no skills dir here: --copilot adds a pointer block to .github/copilot-instructions.md.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd -P)
TOOLKIT=hardware-mod-toolkit
SKILLS=
for d in "$ROOT"/skills/*/; do
  [ -f "${d}SKILL.md" ] || continue
  SKILLS="$SKILLS $(basename "$d")"
done
[ -n "$SKILLS" ] || { echo "no skills found under $ROOT/skills" >&2; exit 2; }
SRC=$ROOT
NAME=$TOOLKIT

usage() {
  cat <<USAGE
Usage: ./install.sh [--claude] [--agents] [--gemini] [--cursor] [--copilot]
                    [--project DIR] [--user] [--copy] [--dry-run] [--uninstall] [-h]
  --claude    skill dirs: ~/.claude/skills/<skill> (default) or <project>/.claude/skills/<skill> with --project
  --agents    skill dirs: <project>/.agents/skills/<skill> (Codex, Cursor, Gemini CLI); ~/.agents/skills with --user
  --gemini    add a pointer block to <project>/GEMINI.md
  --cursor    add a pointer block to <project>/AGENTS.md (Cursor reads it natively)
  --copilot   add a pointer block to <project>/.github/copilot-instructions.md
  --project   project directory (default: current directory)
  --user      use the user-level skills dir
  --copy      copy instead of symlink (writes .installed-by-<skill>)
  --dry-run   print actions only
  --uninstall remove only what this installer owns
With no target flag nothing changes.
USAGE
}

DO_CLAUDE=0 DO_AGENTS=0 DO_GEMINI=0 DO_CURSOR=0 DO_COPILOT=0
USER_MODE=0 COPY=0 DRY=0 UNINST=0 PROJECT= PROJECT_SET=0
while [ $# -gt 0 ]; do
  case $1 in
    --claude) DO_CLAUDE=1;; --agents) DO_AGENTS=1;; --gemini) DO_GEMINI=1;;
    --cursor) DO_CURSOR=1;; --copilot) DO_COPILOT=1;;
    --user) USER_MODE=1;; --copy) COPY=1;; --dry-run) DRY=1;; --uninstall) UNINST=1;;
    --project) [ $# -ge 2 ] || { echo "--project needs a directory" >&2; exit 2; }; PROJECT=$2; PROJECT_SET=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2;;
  esac
  shift
done

if [ $((DO_CLAUDE+DO_AGENTS+DO_GEMINI+DO_CURSOR+DO_COPILOT)) -eq 0 ]; then
  usage
  echo
  echo "Detected tools:"
  for t in claude codex gemini cursor; do
    if command -v "$t" >/dev/null 2>&1; then echo "  $t: found"; else echo "  $t: not found"; fi
  done
  exit 0
fi

[ -n "$PROJECT" ] || PROJECT=$PWD
if [ -d "$PROJECT" ]; then PROJECT=$(cd "$PROJECT" && pwd -P); else
  [ "$UNINST" -eq 1 ] || [ "$DRY" -eq 1 ] || { echo "project dir not found: $PROJECT" >&2; exit 2; }
fi

BEGIN="<!-- BEGIN $NAME -->"
END="<!-- END $NAME -->"

say() { echo "$*"; }
run() { if [ "$DRY" -eq 1 ]; then say "[dry-run] $*"; else "$@"; fi; }

owned() { # $1 path (uses SRC and MARK of the current skill): symlink into this repo, or dir with our marker
  if [ -L "$1" ]; then
    t=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    [ "$t" = "$SRC" ]
  else
    [ -d "$1" ] && [ -f "$1/$MARK" ]
  fi
}

install_dir() { # $1 destination skill dir
  d=$1
  if [ -e "$d" ] || [ -L "$d" ]; then
    if owned "$d"; then say "ok (already installed): $d"; return 0; fi
    say "refusing: $d exists and is not owned by this installer" >&2; return 1
  fi
  run mkdir -p "$(dirname "$d")"
  if [ "$COPY" -eq 1 ]; then
    run mkdir "$d"
    for f in "$SRC"/* "$SRC"/.[!.]*; do
      [ -e "$f" ] || continue
      case $(basename "$f") in .git|node_modules) continue;; esac
      run cp -R "$f" "$d/"
    done
    if [ "$DRY" -eq 1 ]; then say "[dry-run] write $d/$MARK"; else : > "$d/$MARK"; fi
  else
    run ln -s "$SRC" "$d"
  fi
  say "installed: $d"
}

prune_empty() { # remove empty parent dirs up to (not including) $2
  p=$1
  while [ "$p" != "$2" ] && [ "$p" != "/" ] && [ -d "$p" ] && rmdir "$p" 2>/dev/null; do
    p=$(dirname "$p")
  done
}

uninstall_dir() {
  d=$1; stop=$2
  if [ -e "$d" ] || [ -L "$d" ]; then
    if owned "$d"; then
      if [ -L "$d" ]; then run rm "$d"; else run rm -R "$d"; fi
      say "removed: $d"
      [ "$DRY" -eq 1 ] || prune_empty "$(dirname "$d")" "$stop"
    else
      say "skipping: $d is not owned by this installer" >&2
    fi
  fi
}

has_block() { [ -f "$1" ] && grep -qF "$BEGIN" "$1"; }

add_block() { # $1 file, $2 skill path text
  f=$1
  if has_block "$f"; then say "ok (block present): $f"; return 0; fi
  run mkdir -p "$(dirname "$f")"
  if [ "$DRY" -eq 1 ]; then say "[dry-run] append block to $f"; return 0; fi
  {
    [ -s "$f" ] && echo
    echo "$BEGIN"
    for s in $SKILLS; do
      echo "Skill \`$s\`: read $2/skills/$s/SKILL.md when the task matches its description."
    done
    echo "$END"
  } >> "$f"
  say "block added: $f"
}

remove_block() { # $1 file, $2 stop dir
  f=$1
  has_block "$f" || return 0
  if [ "$DRY" -eq 1 ]; then say "[dry-run] remove block from $f"; return 0; fi
  tmp="$f.tmp.$$"
  awk -v b="$BEGIN" -v e="$END" '
    $0==b {skip=1; next}
    skip && $0==e {skip=0; next}
    !skip {print}' "$f" > "$tmp"
  if [ -z "$(tr -d '[:space:]' < "$tmp")" ]; then rm "$f"; rm "$tmp"; else mv "$tmp" "$f"; fi
  say "block removed: $f"
  prune_empty "$(dirname "$f")" "$2"
}

rc=0
if [ "$DO_CLAUDE" -eq 1 ]; then
  if [ "$USER_MODE" -eq 0 ] && [ "$PROJECT_SET" -eq 1 ]; then base=$PROJECT/.claude/skills; stop=$PROJECT
  else base=$HOME/.claude/skills; stop=$HOME; fi
  for s in $SKILLS; do
    SRC=$ROOT/skills/$s MARK=".installed-by-$s"
    if [ "$UNINST" -eq 1 ]; then uninstall_dir "$base/$s" "$stop"; else install_dir "$base/$s" || rc=1; fi
  done
fi
if [ "$DO_AGENTS" -eq 1 ]; then
  if [ "$USER_MODE" -eq 1 ]; then base=$HOME/.agents/skills; stop=$HOME; else base=$PROJECT/.agents/skills; stop=$PROJECT; fi
  for s in $SKILLS; do
    SRC=$ROOT/skills/$s MARK=".installed-by-$s"
    if [ "$UNINST" -eq 1 ]; then uninstall_dir "$base/$s" "$stop"; else install_dir "$base/$s" || rc=1; fi
  done
fi
for pair in "$DO_GEMINI:GEMINI.md" "$DO_CURSOR:AGENTS.md" "$DO_COPILOT:.github/copilot-instructions.md"; do
  on=${pair%%:*}; rel=${pair#*:}
  [ "$on" -eq 1 ] || continue
  if [ "$UNINST" -eq 1 ]; then remove_block "$PROJECT/$rel" "$PROJECT"; else add_block "$PROJECT/$rel" "$ROOT" || rc=1; fi
done
exit $rc
