#!/usr/bin/env bash
#
# mcu-backup-window.sh — a READ-ONLY esptool session for an Espressif MCU
#                         that only exposes its download-mode bridge for a
#                         short window after boot/reset.
#
# WHAT THIS IS FOR
#   Some devices hand a shared USB peripheral from a debug/download bridge
#   (USB-Serial-JTAG, a CDC-ACM bridge, etc.) to the running application some
#   fixed time after boot, after which the bridge stops enumerating and a
#   flashing tool's usual reset sequence stops working. See the
#   `mcu-safe-backup` skill (§2, "Finding the window") for how to measure
#   that window on <DEVICE> before you ever run this script for real.
#
#   This script (a) waits for the port to appear, (b) immediately runs
#   READ-ONLY esptool commands against it, (c) logs everything under its
#   output directory. It NEVER runs write_flash, erase_flash, erase_region,
#   write_flash_status, or any espefuse/secure-boot command — see SAFETY
#   GATES below. The one sanctioned exception to "read-only, always" that
#   a project like this eventually needs (reverting boot selection to
#   stock) is a SEPARATE script by design — see "THE ONE SANCTIONED WRITE"
#   near the end of this header. This file has no code path that can ever
#   construct a write/erase/efuse command.
#
# SUBCOMMANDS
#   identify           Wait for the port, then run chip-id, flash-id,
#                       read-flash-status, and a 64KB timed probe read of
#                       offset 0x0 (bootloader region on most ESP-IDF
#                       layouts — confirm against your own device's map).
#                       Prints elapsed time per step. Leaves the chip in
#                       download mode (--after no-reset throughout) so
#                       partition-table and dump can chain onto the same
#                       session without re-triggering a reset.
#
#   partition-table     Assumes the chip is already in download mode (i.e.
#                       run identify first, or the chip is otherwise known
#                       to still be in ROM download mode). Reads the
#                       partition-table region (default 0x8000, length
#                       0x4000 — the ESP-IDF default; pass --pt-offset if
#                       <DEVICE> relocates it) and decodes it.
#
#   dump                Reads the FULL flash TWICE (size auto-detected from
#                       flash-id unless --flash-size overrides it) into the
#                       output directory, sha256-compares the two passes,
#                       and prints PASS/FAIL. See the throughput warning
#                       under "KNOWN PERFORMANCE TRAP" below before you
#                       budget a session window around this.
#
# SAFETY GATES (all unconditional, not just for one task)
#   - DRY RUN BY DEFAULT: every subcommand only PRINTS the exact esptool
#     command line(s) it would run and exits 0. Nothing is executed, no
#     port is opened, no device is touched, unless the explicit --yes flag
#     is given. This is what lets you review or test this script with no
#     device attached at all.
#   - Any argument to this script containing "write", "erase", or "efuse"
#     (case-insensitive substring match) is refused immediately, before
#     anything else runs. The same check is repeated on every assembled
#     esptool command array as defense-in-depth. This script never
#     constructs a write_flash / erase_flash / erase_region /
#     write_flash_status / espefuse command — there is no code path here
#     that could.
#   - partition-table and dump refuse to run unless the output directory
#     is confirmed gitignored (`git check-ignore`, when run inside a git
#     work tree) — flash-derived binaries are never written somewhere that
#     could accidentally get committed. Outside a git work tree, this
#     check is skipped with a loud warning instead of a silent pass.
#
# SYNTAX DETECTION (esptool v4 vs v5)
#   esptool v4.x spells subcommands and --before/--after values with
#   underscores (chip_id, flash_id, read_flash, read_flash_status,
#   default_reset, no_reset). esptool v5.x switched to dashes (chip-id,
#   flash-id, read-flash, read-flash-status, default-reset, no-reset).
#   This script detects which is installed by grepping
#   `python3 -m esptool --help` for "chip-id" vs "chip_id" and picks the
#   matching spelling for every command it prints/runs — do not hardcode
#   either form when reading this script's output; it changes with
#   whatever esptool is on PATH at the moment you run it.
#
# PARTITION TABLE DECODING
#   `python3 -m esptool.gen_esp32part` is tried first (present on some
#   esptool installs, e.g. when installed via ESP-IDF). If it's not
#   importable (as on a plain `pip install esptool`, where this module is
#   not packaged), this script falls back to a small built-in Python
#   decoder that parses the standard 32-byte ESP-IDF partition-table entry
#   format directly (magic 0xAA50 little-endian, MD5-checksum entries
#   marked 0xEBEB skipped, 0xFFFF/all-0xFF terminates the table).
#
# KNOWN PERFORMANCE TRAP
#   esptool's read_flash over USB-Serial-JTAG has, on at least one chip
#   family (ESP32-S3), a documented unresolved upstream throughput bug
#   (esptool GitHub issue #936) measured in the field at roughly 8-11.5
#   KB/s instead of the multi-hundred-KB/s a healthy USB-Serial-JTAG
#   transfer should manage — turning a 16 MiB read into 25-35 minutes
#   instead of well under a minute. `identify`'s 64KB timed probe exists
#   so you measure YOUR unit's actual throughput before `dump` runs two
#   full passes unattended — do not assume a datasheet or another
#   project's number applies to your <DEVICE>/<MCU>/transport combination.
#   If the probe comes back slow, that is very likely this same class of
#   bug, not a fault on your end; if `dump`'s progress output stops
#   advancing for much longer than one progress interval, that IS a hang.
#
# USAGE
#   ./scripts/mcu-backup-window.sh identify                    # dry run
#   ./scripts/mcu-backup-window.sh identify --yes
#   ./scripts/mcu-backup-window.sh identify --yes --port /dev/cu.usbmodem* --timeout 8
#   ./scripts/mcu-backup-window.sh partition-table --yes
#   ./scripts/mcu-backup-window.sh dump --yes
#   ./scripts/mcu-backup-window.sh dump --yes --out backups/original --flash-size 0x1000000
#
# FLAGS
#   --port PATTERN      Serial port path or glob (default: /dev/cu.usbmodem*
#                        on macOS; pass /dev/ttyACM* or /dev/ttyUSB* on
#                        Linux — this script does not guess your OS).
#   --chip NAME          esptool --chip value (e.g. esp32, esp32s3, esp32c3).
#                        Default: omitted entirely, letting esptool
#                        auto-detect — do not hardcode your device's chip
#                        family here unless auto-detect has proven
#                        unreliable for you.
#   --timeout SECONDS   Max seconds to wait for the port to appear
#                        (default: 15).
#   --pt-offset HEX      Partition-table region offset for `partition-table`
#                        (default: 0x8000, the ESP-IDF default). Read this
#                        from your own bootloader/linker docs if <DEVICE>
#                        relocates it — never guess.
#   --flash-size HEX|DEC `dump`'s flash size, e.g. 0x1000000 or 16777216.
#                        Default: auto-detect from flash-id. If auto-detect
#                        fails AND this flag is absent, `dump` refuses to
#                        guess a size and exits with an error — a wrong
#                        assumed size silently truncates or overruns a
#                        "full" dump. Get the real number by running
#                        `identify` first and reading its flash-id output,
#                        or from your device's datasheet, before dumping.
#   --out DIR            Output directory for logs and binaries (default:
#                        ./backups/original, matching this toolkit's
#                        .gitignore convention — see templates/CLAUDE.md).
#   --yes                Actually execute esptool. Without it, every
#                        subcommand only prints the exact command line(s)
#                        it would run (DRY RUN) and exits 0 — no port is
#                        opened.
#   -h, --help           Show this help.
#
# THE ONE SANCTIONED WRITE (documented here, NOT implemented in this file)
#   Every project like this eventually needs exactly one write-class
#   operation: reverting boot selection back to a factory/stock slot so a
#   bricked or over-modified device recovers. That does NOT belong in this
#   script — it belongs in its own separate, narrowly-scoped script, built
#   like this, and no looser:
#     1. The target region (offset + length) is a COMPILE-TIME CONSTANT in
#        that script, never a CLI argument. Any argument that even looks
#        like an attempt to override it (--offset, --address, --region,
#        --size, ...) is rejected outright, before anything else runs.
#     2. Before writing anything, that script independently RE-DERIVES the
#        same region by reading and decoding the device's OWN partition
#        table this session (not a cached copy, not this script's own
#        earlier output) and locating the matching entry by type/subtype/
#        label. If the freshly-read entry's offset or size does not match
#        the hardcoded constant exactly, it ABORTS WITHOUT WRITING.
#     3. The assembled command is scanned immediately before every
#        invocation: "write"/"efuse" anywhere still refuses the whole run;
#        an "erase" substring is permitted ONLY as the exact, contiguous,
#        hardcoded verb-plus-offset-plus-size sequence from step 1 — any
#        other shape refuses. This is the only place in a project like
#        this where "erase" is ever allowed past the gate.
#     4. It reads back the erased/written region and verifies every byte
#        (for an erase: the erased-state value; for any other write: a
#        hash match) before declaring success.
#     5. It leaves the device in download mode by default afterward, with
#        an explicit opt-in flag to trigger a reset — so "let it boot on
#        the new state" is a distinct, deliberate step.
#     6. It never runs without an explicit --yes, and that --yes is never
#        treated as standing authorization for a future run — see
#        `mcu-safe-backup` skill §7 and `templates/decision-record.md`.
#   See the `mcu-safe-backup` skill for the full pattern and its rationale.
#
# REQUIRES: bash, python3, esptool (`python3 -m pip install --user esptool`),
# git (optional, for the gitignore confirmation), shasum or sha256sum. No
# sudo. No installs performed by this script beyond what you already have.

set -uo pipefail

# ------------------------------------------------------------------------
# usage
# ------------------------------------------------------------------------
usage() {
  awk 'NR>1 && /^# ?/{sub(/^# ?/,""); print; next} NR>1 && !/^#/{exit}' "$0"
}

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

# ------------------------------------------------------------------------
# lowercase a string portably (no bash-4-only ${var,,})
# ------------------------------------------------------------------------
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ------------------------------------------------------------------------
# safety gate: refuse write/erase/efuse anywhere in argv, before anything
# else runs
# ------------------------------------------------------------------------
assert_no_forbidden_args() {
  local arg lower
  for arg in "$@"; do
    lower="$(to_lower "$arg")"
    case "$lower" in
      *write*|*erase*|*efuse*)
        echo "mcu-backup-window.sh: REFUSED — argument contains a forbidden term (write/erase/efuse): '$arg'" >&2
        echo "This script is read-only only; write/erase/efuse operations are never permitted here." >&2
        exit 3
        ;;
    esac
  done
}
assert_no_forbidden_args "$@"

SUBCOMMAND="$1"
shift

PORT_ARG='/dev/cu.usbmodem*'
CHIP_ARG=""
TIMEOUT=15
PT_OFFSET="0x8000"
PT_LEN="0x4000"
FLASH_SIZE_ARG=""
OUT_DIR="./backups/original"
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)        PORT_ARG="$2"; shift 2 ;;
    --chip)        CHIP_ARG="$2"; shift 2 ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    --pt-offset)   PT_OFFSET="$2"; shift 2 ;;
    --flash-size)  FLASH_SIZE_ARG="$2"; shift 2 ;;
    --out)         OUT_DIR="$2"; shift 2 ;;
    --yes)         YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)
      echo "mcu-backup-window.sh: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

CAPTURE_DIR="$OUT_DIR/logs"

# ------------------------------------------------------------------------
# esptool subcommand/flag syntax detection (v4 underscore vs v5 dash)
# ------------------------------------------------------------------------
detect_esptool() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "mcu-backup-window.sh: python3 not found on PATH." >&2
    exit 1
  fi

  local version_raw
  version_raw="$(python3 -m esptool version 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo "mcu-backup-window.sh: 'python3 -m esptool version' failed:" >&2
    echo "$version_raw" >&2
    echo "Install with: python3 -m pip install --user esptool" >&2
    exit 1
  fi
  ESPTOOL_VERSION_STR="$(printf '%s\n' "$version_raw" | head -n1)"

  ESPTOOL_HELP="$(python3 -m esptool --help 2>&1)"
  if printf '%s\n' "$ESPTOOL_HELP" | grep -q -- 'chip-id'; then
    ESPTOOL_SYNTAX="dash (v5+)"
    CMD_CHIP_ID="chip-id"
    CMD_FLASH_ID="flash-id"
    CMD_READ_FLASH="read-flash"
    CMD_READ_FLASH_STATUS="read-flash-status"
    BEFORE_DEFAULT="default-reset"
    BEFORE_NO="no-reset"
    AFTER_NO="no-reset"
  elif printf '%s\n' "$ESPTOOL_HELP" | grep -q -- 'chip_id'; then
    ESPTOOL_SYNTAX="underscore (v4.x)"
    CMD_CHIP_ID="chip_id"
    CMD_FLASH_ID="flash_id"
    CMD_READ_FLASH="read_flash"
    CMD_READ_FLASH_STATUS="read_flash_status"
    BEFORE_DEFAULT="default_reset"
    BEFORE_NO="no_reset"
    AFTER_NO="no_reset"
  else
    echo "mcu-backup-window.sh: could not detect esptool subcommand spelling from --help output:" >&2
    echo "$ESPTOOL_HELP" >&2
    exit 1
  fi
}
detect_esptool

# ------------------------------------------------------------------------
# wait_for_port <pattern> <timeout-seconds>
#   Polls every 0.2s. Prints the matched path on stdout and returns 0, or
#   prints nothing and returns 1 on timeout. Uses bash globbing, not `ls`,
#   so a glob that matches nothing does not print a literal error line.
# ------------------------------------------------------------------------
wait_for_port() {
  local pattern="$1" timeout="$2"
  local waited=0
  local -a matches
  while true; do
    if [[ -e "$pattern" ]]; then
      printf '%s\n' "$pattern"
      return 0
    fi
    matches=( $pattern )
    if [[ -e "${matches[0]:-}" ]]; then
      printf '%s\n' "${matches[0]}"
      return 0
    fi
    if awk -v w="$waited" -v t="$timeout" 'BEGIN{exit !(w>=t)}'; then
      return 1
    fi
    sleep 0.2
    waited="$(awk -v w="$waited" 'BEGIN{printf "%.1f", w+0.2}')"
  done
}

# ------------------------------------------------------------------------
# refuse_if_port_busy <port>
#   `lsof`-only check (no device I/O) that another process already has
#   this exact node open. Prints an error and returns 1 if so; silent,
#   returns 0 otherwise (including when lsof isn't installed).
# ------------------------------------------------------------------------
refuse_if_port_busy() {
  local port="$1"
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi
  local busy_pid
  busy_pid="$(lsof -t -- "$port" 2>/dev/null | head -n 1)"
  if [[ -n "$busy_pid" ]]; then
    echo "ERROR: $port is already held open by pid $busy_pid (lsof -t \"$port\")." >&2
    echo "       If that is an in-progress esptool/flash session, DO NOT proceed —" >&2
    echo "       refusing rather than risk two processes touching the same node." >&2
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------
# print_failure_hint <logfile>
#   Grep the log tail for known esptool failure strings and print the
#   matching plain-language hint.
# ------------------------------------------------------------------------
print_failure_hint() {
  local logfile="$1"
  local tail_text
  tail_text="$(tail -n 60 "$logfile" 2>/dev/null)"
  if printf '%s\n' "$tail_text" | grep -qi "wrong boot mode\|invalid head of packet"; then
    echo "HINT: esptool reported a 'wrong boot mode' / framing error — the app was"
    echo "      running (chip never entered download mode). Wait for the next"
    echo "      boot/reset and retry inside the window (see the mcu-safe-backup skill)."
  elif printf '%s\n' "$tail_text" | grep -qi "failed to connect\|no serial data received\|timed out waiting for packet\|could not open\|port is busy or doesn't exist\|inappropriate ioctl"; then
    echo "HINT: esptool could not connect in time — the device likely left the"
    echo "      download-mode window before esptool's reset sequence landed, or the"
    echo "      port disappeared. Reset/replug the device and retry immediately."
  else
    echo "HINT: unrecognized failure — inspect $logfile for the full esptool output."
  fi
}

# ------------------------------------------------------------------------
# run_esptool_step <description> <logfile> <esptool argv...>
#   - always echoes the exact command line
#   - dry run (YES=0): prints "DRY RUN", appends the plan to the logfile,
#     returns 0, never executes anything
#   - real run (YES=1): defense-in-depth forbidden-term scan on the
#     assembled argv, times the call, tees output to the logfile, prints
#     elapsed time and exit code, prints a failure hint on nonzero exit
# ------------------------------------------------------------------------
run_esptool_step() {
  local desc="$1" logfile="$2"
  shift 2
  local -a cmd=("$@")

  local word lower
  for word in "${cmd[@]}"; do
    lower="$(to_lower "$word")"
    case "$lower" in
      *write*|*erase*|*efuse*)
        echo "mcu-backup-window.sh: REFUSED — assembled esptool command contains a forbidden term: '$word'" >&2
        exit 3
        ;;
    esac
  done

  echo ""
  echo "--- $desc ---"
  printf '$ %s\n' "${cmd[*]}"

  if (( ! YES )); then
    echo "DRY RUN (pass --yes to execute)"
    {
      echo "--- $desc ---"
      printf '$ %s\n' "${cmd[*]}"
      echo "DRY RUN (pass --yes to execute)"
    } >> "$logfile"
    return 0
  fi

  {
    echo "--- $desc ---"
    printf '$ %s\n' "${cmd[*]}"
    echo "started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >> "$logfile"

  local t0 t1 elapsed rc
  t0=$(date +%s)
  "${cmd[@]}" >>"$logfile" 2>&1
  rc=$?
  t1=$(date +%s)
  elapsed=$(( t1 - t0 ))

  echo "elapsed: ${elapsed}s"
  { echo "elapsed: ${elapsed}s"; echo "exit code: $rc"; } >> "$logfile"

  if (( rc != 0 )); then
    echo "FAILED ($desc), rc=$rc, ${elapsed}s"
    print_failure_hint "$logfile"
  else
    echo "OK ($desc), ${elapsed}s"
  fi
  return $rc
}

# ------------------------------------------------------------------------
# sha256_of <file> — prefers shasum (macOS default), falls back to
# sha256sum (most Linux distros)
# ------------------------------------------------------------------------
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ------------------------------------------------------------------------
# confirm a path is covered by .gitignore before writing flash-derived
# binaries under it; refuses (exit 4) if not. Skipped with a warning
# outside a git work tree.
# ------------------------------------------------------------------------
confirm_gitignored() {
  local target_path="$1"
  mkdir -p "$target_path"
  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "WARNING: not inside a git work tree — skipping the gitignore confirmation." >&2
    echo "         Make sure $target_path is not somewhere you will later 'git add'." >&2
    return 0
  fi
  if git check-ignore -q "$target_path" 2>/dev/null; then
    echo "confirmed gitignored: $target_path"
  else
    echo "mcu-backup-window.sh: REFUSING — $target_path is not covered by .gitignore." >&2
    echo "Not writing flash-derived binaries somewhere that could be committed." >&2
    echo "Add it to .gitignore (this toolkit's own convention: backups/, captures/) and retry." >&2
    exit 4
  fi
}

# ------------------------------------------------------------------------
# decode_partition_table <bin-file>
#   tries esptool's own gen_esp32part module first, falls back to a
#   built-in parser of the standard 32-byte partition-entry format
# ------------------------------------------------------------------------
decode_partition_table() {
  local file="$1"
  local out
  out="$(python3 -m esptool.gen_esp32part "$file" 2>&1)"
  if (( $? == 0 )); then
    printf '%s\n' "$out"
    return 0
  fi

  echo "(python3 -m esptool.gen_esp32part not available in this esptool install — using built-in decoder)"
  python3 - "$file" <<'PYEOF'
import struct
import sys

TYPE_NAMES = {0x00: "app", 0x01: "data"}
APP_SUBTYPE = {0x00: "factory", 0x20: "test"}
for _i in range(16):
    APP_SUBTYPE[0x10 + _i] = "ota_%d" % _i
DATA_SUBTYPE = {
    0x00: "ota", 0x01: "phy", 0x02: "nvs", 0x03: "coredump",
    0x04: "nvs_keys", 0x05: "efuse_em", 0x06: "undefined",
    0x80: "esphttpd", 0x81: "fat", 0x82: "spiffs",
}


def subtype_name(t, st):
    if t == 0x00:
        return APP_SUBTYPE.get(st, "0x%02x" % st)
    if t == 0x01:
        return DATA_SUBTYPE.get(st, "0x%02x" % st)
    return "0x%02x" % st


path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()

print("%-16s %-6s %-10s %-10s %-14s %s" % ("Name", "Type", "SubType", "Offset", "Size", "Flags"))
off = 0
count = 0
while off + 32 <= len(data):
    entry = data[off:off + 32]
    if entry == b"\xff" * 32:
        break
    magic = struct.unpack_from("<H", entry, 0)[0]
    if magic == 0xFFFF:
        break
    if magic == 0xEBEB:
        # MD5-checksum entry, not a partition
        off += 32
        continue
    if magic != 0x50AA:
        print("  (stopping: unexpected magic 0x%04x at offset 0x%x)" % (magic, off))
        break
    ptype, psub = struct.unpack_from("<BB", entry, 2)
    poff, psize = struct.unpack_from("<II", entry, 4)
    label = entry[12:28].split(b"\x00", 1)[0].decode("ascii", "replace")
    flags = struct.unpack_from("<I", entry, 28)[0]
    print(
        "%-16s %-6s %-10s 0x%06x   0x%06x (%d B)  0x%08x"
        % (label, TYPE_NAMES.get(ptype, hex(ptype)), subtype_name(ptype, psub), poff, psize, psize, flags)
    )
    count += 1
    off += 32

print("")
print("%d partition entries decoded from %s" % (count, path))
PYEOF
}

# ------------------------------------------------------------------------
# esptool_base — the shared --port/--chip prefix, built fresh each call so
# an empty CHIP_ARG (the "let esptool auto-detect" default) omits --chip
# entirely rather than passing it empty.
# ------------------------------------------------------------------------
esptool_base() {
  local port="$1"
  if [[ -n "$CHIP_ARG" ]]; then
    printf '%s\n' python3 -m esptool --port "$port" --chip "$CHIP_ARG"
  else
    printf '%s\n' python3 -m esptool --port "$port"
  fi
}

# ------------------------------------------------------------------------
# subcommand: identify
# ------------------------------------------------------------------------
cmd_identify() {
  local TS LOGFILE BIN_OUT_DIR PROBE_FILE PORT rc_total=0
  TS="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$CAPTURE_DIR"
  LOGFILE="$CAPTURE_DIR/${TS}-esptool-identify.txt"
  BIN_OUT_DIR="$OUT_DIR/identify-$TS"
  PROBE_FILE="$BIN_OUT_DIR/probe-64k.bin"
  PORT="$PORT_ARG"

  echo "mcu-backup-window.sh identify"
  echo "  esptool:    $ESPTOOL_VERSION_STR ($ESPTOOL_SYNTAX syntax)"
  echo "  chip:       ${CHIP_ARG:-<auto-detect>}"
  echo "  port:       $PORT_ARG  (poll 0.2s, timeout ${TIMEOUT}s)"
  echo "  log file:   $LOGFILE"
  echo "  probe file: $PROBE_FILE"
  if (( YES )); then echo "  mode:       EXECUTE (--yes given)"; else echo "  mode:       DRY RUN (pass --yes to execute)"; fi

  {
    echo "mcu-backup-window.sh identify — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "esptool: $ESPTOOL_VERSION_STR ($ESPTOOL_SYNTAX syntax)"
  } > "$LOGFILE"

  if (( YES )); then
    confirm_gitignored "$OUT_DIR"
    mkdir -p "$BIN_OUT_DIR"
    echo ""
    echo "waiting for $PORT_ARG ..."
    local found
    found="$(wait_for_port "$PORT_ARG" "$TIMEOUT")"
    if [[ -z "$found" ]]; then
      echo "ERROR: no matching port appeared within ${TIMEOUT}s." >&2
      echo "HINT: device left the download-mode window before esptool connected, or was" >&2
      echo "      never plugged in / reset. Reset or replug the device and retry immediately." >&2
      echo "ERROR: no matching port appeared within ${TIMEOUT}s." >> "$LOGFILE"
      return 1
    fi
    PORT="$found"
    echo "port found: $PORT"
    refuse_if_port_busy "$PORT" || return 1
  fi

  local -a base=( $(esptool_base "$PORT") )

  run_esptool_step "chip-id" "$LOGFILE" "${base[@]}" --before "$BEFORE_DEFAULT" --after "$AFTER_NO" "$CMD_CHIP_ID"
  (( $? != 0 )) && rc_total=1

  run_esptool_step "flash-id (already in download mode)" "$LOGFILE" "${base[@]}" --before "$BEFORE_NO" --after "$AFTER_NO" "$CMD_FLASH_ID"
  (( $? != 0 )) && rc_total=1

  run_esptool_step "read-flash-status (read-only status-register read, --bytes 3)" "$LOGFILE" "${base[@]}" --before "$BEFORE_NO" --after "$AFTER_NO" "$CMD_READ_FLASH_STATUS" --bytes 3
  (( $? != 0 )) && rc_total=1

  run_esptool_step "read-flash 0x0 0x10000 (64KB timed probe)" "$LOGFILE" "${base[@]}" --before "$BEFORE_NO" --after "$AFTER_NO" "$CMD_READ_FLASH" 0x0 0x10000 "$PROBE_FILE"
  (( $? != 0 )) && rc_total=1

  echo ""
  echo "log: $LOGFILE"
  (( ! YES )) && echo "DRY RUN complete — nothing executed, no port was touched."
  return $rc_total
}

# ------------------------------------------------------------------------
# subcommand: partition-table
# ------------------------------------------------------------------------
cmd_partition_table() {
  local TS LOGFILE BIN_OUT_DIR PT_FILE PORT rc
  TS="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$CAPTURE_DIR"
  LOGFILE="$CAPTURE_DIR/${TS}-esptool-partition-table.txt"
  BIN_OUT_DIR="$OUT_DIR/parttable-$TS"
  PT_FILE="$BIN_OUT_DIR/partition-table.bin"
  PORT="$PORT_ARG"

  echo "mcu-backup-window.sh partition-table"
  echo "  esptool:    $ESPTOOL_VERSION_STR ($ESPTOOL_SYNTAX syntax)"
  echo "  chip:       ${CHIP_ARG:-<auto-detect>}"
  echo "  port:       $PORT_ARG"
  echo "  region:     $PT_OFFSET, length $PT_LEN"
  echo "  assumes chip already in download mode (e.g. run 'identify' first)"
  echo "  output:     $PT_FILE"
  if (( YES )); then echo "  mode:       EXECUTE (--yes given)"; else echo "  mode:       DRY RUN (pass --yes to execute)"; fi

  { echo "mcu-backup-window.sh partition-table — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"; } > "$LOGFILE"

  if (( YES )); then
    confirm_gitignored "$OUT_DIR"
    mkdir -p "$BIN_OUT_DIR"
    echo ""
    echo "waiting for $PORT_ARG ..."
    local found
    found="$(wait_for_port "$PORT_ARG" "$TIMEOUT")"
    if [[ -z "$found" ]]; then
      echo "ERROR: no matching port appeared within ${TIMEOUT}s." >&2
      return 1
    fi
    PORT="$found"
    echo "port found: $PORT"
    refuse_if_port_busy "$PORT" || return 1
  fi

  local -a base=( $(esptool_base "$PORT") )

  run_esptool_step "read-flash $PT_OFFSET $PT_LEN (partition-table region)" "$LOGFILE" "${base[@]}" --before "$BEFORE_NO" --after "$AFTER_NO" "$CMD_READ_FLASH" "$PT_OFFSET" "$PT_LEN" "$PT_FILE"
  rc=$?

  if (( ! YES )); then
    echo ""
    echo "DRY RUN complete — nothing executed, no port was touched."
    return 0
  fi

  if (( rc != 0 )); then
    echo "read-flash failed (rc=$rc); cannot decode." >&2
    return $rc
  fi

  echo ""
  echo "decoding partition table..."
  decode_partition_table "$PT_FILE" | tee -a "$LOGFILE"
}

# ------------------------------------------------------------------------
# subcommand: dump
# ------------------------------------------------------------------------
cmd_dump() {
  local DATE TS LOGFILE PORT DUMP_DIR
  DATE="$(date +%Y%m%d)"
  TS="$(date +%Y%m%d-%H%M%S)"
  DUMP_DIR="$OUT_DIR/flash-$DATE"
  mkdir -p "$CAPTURE_DIR"
  LOGFILE="$CAPTURE_DIR/${TS}-esptool-dump.txt"
  PORT="$PORT_ARG"

  echo "mcu-backup-window.sh dump"
  echo "  esptool:    $ESPTOOL_VERSION_STR ($ESPTOOL_SYNTAX syntax)"
  echo "  chip:       ${CHIP_ARG:-<auto-detect>}"
  echo "  port:       $PORT_ARG"
  echo "  output dir: $DUMP_DIR"
  echo "  WARNING: esptool read-flash over a USB-Serial-JTAG bridge has, on at least"
  echo "           one chip family, an unresolved upstream throughput bug (esptool"
  echo "           issue #936) observed around 8-11.5 KB/s — a 16MB dump can take"
  echo "           25-35 minutes PER PASS. This subcommand reads TWO full passes;"
  echo "           run 'identify' first and check its probe-read elapsed time so"
  echo "           you know what to expect on YOUR unit before budgeting the window."
  if (( YES )); then echo "  mode:       EXECUTE (--yes given)"; else echo "  mode:       DRY RUN (pass --yes to execute)"; fi

  { echo "mcu-backup-window.sh dump — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"; } > "$LOGFILE"

  if (( YES )); then
    confirm_gitignored "$OUT_DIR"
    mkdir -p "$DUMP_DIR"
    echo ""
    echo "waiting for $PORT_ARG ..."
    local found
    found="$(wait_for_port "$PORT_ARG" "$TIMEOUT")"
    if [[ -z "$found" ]]; then
      echo "ERROR: no matching port appeared within ${TIMEOUT}s." >&2
      return 1
    fi
    PORT="$found"
    echo "port found: $PORT"
    refuse_if_port_busy "$PORT" || return 1
  fi

  local -a base=( $(esptool_base "$PORT") )
  local FLASH_SIZE_HEX=""

  if [[ -n "$FLASH_SIZE_ARG" ]]; then
    FLASH_SIZE_HEX="$(printf '0x%X' "$FLASH_SIZE_ARG" 2>/dev/null || printf '%s' "$FLASH_SIZE_ARG")"
    echo "using --flash-size override: $FLASH_SIZE_HEX"
  elif (( YES )); then
    run_esptool_step "flash-id (determine flash size; already in download mode)" "$LOGFILE" "${base[@]}" --before "$BEFORE_NO" --after "$AFTER_NO" "$CMD_FLASH_ID"
    local detected_mb
    detected_mb="$(grep -i 'detected flash size' "$LOGFILE" | tail -1 | grep -oE '[0-9]+' | head -1)"
    if [[ -n "$detected_mb" ]]; then
      FLASH_SIZE_HEX="$(printf '0x%X' $(( detected_mb * 1024 * 1024 )))"
      echo "detected flash size: ${detected_mb}MB"
    else
      echo "ERROR: could not auto-detect flash size from flash-id output, and no" >&2
      echo "       --flash-size was given. Refusing to guess a size for a 'full'" >&2
      echo "       dump — a wrong guess silently truncates or overruns it. Re-run" >&2
      echo "       with --flash-size <bytes-or-hex> using a value you have confirmed" >&2
      echo "       (from 'identify', from your device's datasheet, or from the flash" >&2
      echo "       die's own marking)." >&2
      return 1
    fi
  else
    echo ""
    echo "(dry run — flash size not probed and no --flash-size given; pass"
    echo " --flash-size explicitly to see real command lines for a real size)"
    FLASH_SIZE_HEX="<FLASH_SIZE>"
  fi

  local SIZE_LABEL PASS1 PASS2
  if [[ "$FLASH_SIZE_HEX" != "<FLASH_SIZE>" ]]; then
    SIZE_LABEL="$(( $(( FLASH_SIZE_HEX )) / 1048576 ))MB"
  else
    SIZE_LABEL="unknownMB"
  fi
  PASS1="$DUMP_DIR/flash-full-${DATE}-${SIZE_LABEL}-pass1.bin"
  PASS2="$DUMP_DIR/flash-full-${DATE}-${SIZE_LABEL}-pass2.bin"

  run_esptool_step "read-flash 0x0 $FLASH_SIZE_HEX pass 1" "$LOGFILE" "${base[@]}" --before "$BEFORE_NO" --after "$AFTER_NO" "$CMD_READ_FLASH" 0x0 "$FLASH_SIZE_HEX" "$PASS1"
  local rc1=$?

  run_esptool_step "read-flash 0x0 $FLASH_SIZE_HEX pass 2" "$LOGFILE" "${base[@]}" --before "$BEFORE_NO" --after "$AFTER_NO" "$CMD_READ_FLASH" 0x0 "$FLASH_SIZE_HEX" "$PASS2"
  local rc2=$?

  if (( ! YES )); then
    echo ""
    echo "DRY RUN complete — nothing executed, no port was touched."
    return 0
  fi

  if (( rc1 != 0 || rc2 != 0 )); then
    echo "one or both read-flash passes failed; skipping sha256 compare." >&2
    return 1
  fi

  echo ""
  echo "computing sha256..."
  local h1 h2
  h1="$(sha256_of "$PASS1")"
  h2="$(sha256_of "$PASS2")"
  echo "pass1: $h1  $PASS1"
  echo "pass2: $h2  $PASS2"
  { echo "pass1 sha256: $h1  $PASS1"; echo "pass2 sha256: $h2  $PASS2"; } >> "$LOGFILE"

  if [[ "$h1" == "$h2" ]]; then
    echo "PASS: both passes match (sha256 $h1)"
    echo "PASS: both passes match (sha256 $h1)" >> "$LOGFILE"
    return 0
  else
    echo "FAIL: passes do not match — do NOT trust this as a verified backup" >&2
    echo "FAIL: passes do not match" >> "$LOGFILE"
    return 1
  fi
}

case "$SUBCOMMAND" in
  identify)         cmd_identify ;;
  partition-table)  cmd_partition_table ;;
  dump)             cmd_dump ;;
  *)
    echo "mcu-backup-window.sh: unknown subcommand: $SUBCOMMAND" >&2
    usage
    exit 2
    ;;
esac
exit $?
