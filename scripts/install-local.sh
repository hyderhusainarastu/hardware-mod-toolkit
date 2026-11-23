#!/usr/bin/env bash
#
# install-local.sh — copy this toolkit's skills, agents, workflows and
#                    templates into a project so Claude Code discovers them,
#                    without installing a plugin marketplace.
#
# WHY THIS EXISTS
#   There are two ways to use this toolkit. As a *plugin*, Claude Code reads
#   skills/, agents/ and workflows/ straight out of the checkout and you never
#   run this script. As a *project-local* install — useful when you want the
#   toolkit's assets versioned alongside your own mod project, or want to edit
#   them for your specific device — this script copies them into the project's
#   .claude/ directory, where Claude Code discovers them the same way.
#
#   Copies are deliberate: a project-local install is meant to be forked. You
#   are expected to edit the copied CLAUDE.md and templates to name your own
#   device. Re-running the script will not silently overwrite your edits; it
#   skips anything that already exists unless you pass --force.
#
# USAGE
#   ./scripts/install-local.sh --target /path/to/your/mod-project
#   ./scripts/install-local.sh --target /path/to/your/mod-project --dry-run
#   ./scripts/install-local.sh --target /path/to/your/mod-project --force
#   ./scripts/install-local.sh --self        # install into this checkout itself
#   ./scripts/install-local.sh --codex --target /path/to/your/mod-project
#   ./scripts/install-local.sh --codex --user
#
#   --target DIR   Project root to install into. Quote it if it contains a
#                  space. Must already exist.
#   --self         Shorthand for --target <this toolkit's own root>, so the
#                  workflows can be run as named project workflows from inside
#                  the toolkit checkout while you develop them.
#   --codex        Link skills/* as symlinks into <target>/.agents/skills/<name>
#                  (read by Codex, Cursor and Gemini CLI) and install nothing
#                  else. With --user the links go to ~/.agents/skills and no
#                  --target is needed. An existing path that is not already a
#                  link into this checkout is left alone unless --force.
#   --user         Only with --codex: use the user-level skills dir.
#   --force        Overwrite files that already exist at the destination.
#                  Without this, existing files are left alone and reported.
#   --dry-run      Print what would be copied and change nothing.
#   -h, --help     This message.
#
# WHAT IT INSTALLS
#   <target>/.claude/skills/<name>/      <- skills/<name>/
#   <target>/.claude/agents/<name>.md    <- agents/<name>.md
#   <target>/.claude/workflows/<name>.js <- workflows/<name>.js
#   <target>/docs/toolkit/               <- templates/, docs/PLAYBOOK.md,
#                                           docs/PITFALLS.md  (reference copies
#                                           you fill in and keep)
#
#   It does NOT copy scripts/. Those are host tools you run by hand from this
#   checkout, and several of them take a device port as an argument — copying
#   them around makes it easy to run a stale one. Call them by path.
#
# SAFETY
#   This script only ever reads from this checkout and writes under --target.
#   It never touches a USB or serial device, never runs a build, and never
#   changes git state anywhere.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET=""
CODEX=0
USER_MODE=0
FORCE=0
DRY=0

die() { echo "install-local.sh: $*" >&2; exit 1; }

usage() { sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target) [ $# -ge 2 ] || die "--target needs a directory"; TARGET="$2"; shift 2 ;;
    --self)   TARGET="$HERE"; shift ;;
    --codex)  CODEX=1; shift ;;
    --user)   USER_MODE=1; shift ;;
    --force)  FORCE=1; shift ;;
    --dry-run|--dry) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ "$USER_MODE" -eq 0 ] || [ "$CODEX" -eq 1 ] || die "--user is only valid with --codex"
if [ "$CODEX" -eq 1 ] && [ "$USER_MODE" -eq 1 ]; then
  [ -n "${HOME:-}" ] || die "HOME is not set"
  mkdir -p -- "$HOME/.agents/skills"
  TARGET="$HOME"
fi
[ -n "$TARGET" ] || die "no target. Pass --target /path/to/project (or --self)."
[ -d "$TARGET" ] || die "target is not a directory: $TARGET"

TARGET="$(cd -- "$TARGET" && pwd)"

echo "install-local.sh: source $HERE"
echo "install-local.sh: target $TARGET"
[ "$DRY" -eq 1 ] && echo "install-local.sh: DRY RUN — nothing will be written"

copied=0
skipped=0

# copy_one <src> <dst>  — file or directory; respects FORCE and DRY
copy_one() {
  local src="$1" dst="$2"
  if [ -e "$dst" ] && [ "$FORCE" -eq 0 ]; then
    echo "  skip (exists)  ${dst#"$TARGET"/}"
    skipped=$((skipped + 1))
    return 0
  fi
  echo "  install        ${dst#"$TARGET"/}"
  if [ "$DRY" -eq 0 ]; then
    mkdir -p -- "$(dirname -- "$dst")"
    rm -rf -- "$dst"
    cp -R -- "$src" "$dst"
  fi
  copied=$((copied + 1))
}

if [ "$CODEX" -eq 1 ]; then
  if [ "$USER_MODE" -eq 1 ]; then base="$HOME/.agents/skills"; else base="$TARGET/.agents/skills"; fi
  echo "codex / .agents skills (symlinks into this checkout):"
  linked=0
  for d in "$HERE"/skills/*/; do
    [ -d "$d" ] || continue
    name="$(basename -- "$d")"
    dst="$base/$name"
    if [ -L "$dst" ] && [ "$(cd -- "$dst" 2>/dev/null && pwd -P)" = "$(cd -- "$d" && pwd -P)" ]; then
      echo "  ok (already linked)  $dst"
      continue
    fi
    if { [ -e "$dst" ] || [ -L "$dst" ]; } && [ "$FORCE" -eq 0 ]; then
      echo "  skip (exists)  $dst"
      continue
    fi
    echo "  link           $dst"
    if [ "$DRY" -eq 0 ]; then
      mkdir -p -- "$base"
      rm -rf -- "$dst"
      ln -s -- "${d%/}" "$dst"
    fi
    linked=$((linked + 1))
  done
  echo
  echo "install-local.sh: $linked linked under $base."
  exit 0
fi

echo "skills:"
for d in "$HERE"/skills/*/; do
  [ -d "$d" ] || continue
  name="$(basename -- "$d")"
  copy_one "${d%/}" "$TARGET/.claude/skills/$name"
done

echo "agents:"
for f in "$HERE"/agents/*.md; do
  [ -f "$f" ] || continue
  copy_one "$f" "$TARGET/.claude/agents/$(basename -- "$f")"
done

echo "workflows:"
for f in "$HERE"/workflows/*.js; do
  [ -f "$f" ] || continue
  copy_one "$f" "$TARGET/.claude/workflows/$(basename -- "$f")"
done

echo "reference docs and templates:"
copy_one "$HERE/templates" "$TARGET/docs/toolkit/templates"
for f in "$HERE"/docs/*.md; do
  [ -f "$f" ] || continue
  copy_one "$f" "$TARGET/docs/toolkit/$(basename -- "$f")"
done

echo
echo "install-local.sh: $copied installed, $skipped skipped."
if [ "$skipped" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
  echo "install-local.sh: re-run with --force to overwrite the skipped files."
fi
cat <<'NEXT'

Next:
  1. Copy docs/toolkit/templates/CLAUDE.md to your project's CLAUDE.md and fill
     in every placeholder you already know. Leave the rest as placeholders
     rather than guessing a plausible-looking value.
  2. Read docs/toolkit/PLAYBOOK.md and start at Phase 0.
  3. Do not connect the device to anything until Phase 0's safety rules are
     written down and you have agreed what counts as a physical action.
NEXT
