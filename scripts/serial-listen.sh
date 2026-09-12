#!/usr/bin/env bash
#
# serial-listen.sh — passively capture a device's boot/console log over a
# short-lived USB-serial node, with automatic redaction before commit.
#
# WHAT THIS IS FOR
#   Some embedded devices enumerate a USB-serial console node for only a
#   few seconds at boot (a debug/console peripheral that then hands the USB
#   PHY to the application, or a node that appears only under a specific
#   button/reset condition) before it disappears. Sitting at a keyboard and
#   typing `screen /dev/...` by hand is too slow to catch that window — by
#   the time you've typed the command, the node is gone. This script waits
#   for the node, opens it strictly READ-ONLY, captures every byte it emits
#   until it disappears (or a timeout), and — by default — follows the
#   device across re-enumeration (a reset, a PHY hand-over, a replug) rather
#   than exiting at the first disappearance.
#
#   Run scripts/usb-watch.sh FIRST to confirm a serial node exists at all
#   and roughly how long it lives, before pointing this script at it.
#
# USAGE
#   ./serial-listen.sh --port '/dev/cu.usbmodem*'
#   ./serial-listen.sh --port '/dev/cu.usbmodem*' --timeout 30
#   ./serial-listen.sh --port /dev/cu.usbmodem101 --yes
#   ./serial-listen.sh --port '/dev/cu.usbmodem*' --once
#   ./serial-listen.sh --port '/dev/cu.usbmodem*' --reconnect-wait 15
#   ./serial-listen.sh --port '/dev/ttyACM*' --baud 921600 --out captures/serial
#
#   Run it, THEN plug in the device (or it's already in). Ctrl-C stops
#   early; --timeout is a hard ceiling on total run time — waiting for the
#   port to appear, capturing, and (in follow mode) waiting for
#   re-enumeration all count against it.
#
#   Before opening the resolved port, this script (a) confirms a matching
#   vendor-ID USB device is currently enumerated, (b) refuses if `lsof`
#   shows another process already holding that node open (e.g. an
#   in-progress flashing session), and (c) prints what it resolved and asks
#   for interactive confirmation unless --yes is passed. None of this opens
#   the device node itself. In follow mode the confirmation prompt is shown
#   ONLY before the first open of the run — every automatic reopen after a
#   later disappearance/re-enumeration happens without a further prompt,
#   though checks (a)/(b) still run before every reopen.
#
# FLAGS
#   --port PATTERN      device-node glob or literal path to wait for (e.g.
#                        '/dev/cu.usbmodem*', '/dev/ttyACM*', or a fixed
#                        path). No default — pass this or edit
#                        DEFAULT_PORT_PATTERN below.
#   --baud N             baud rate for `stty` (default 115200). Irrelevant
#                        for a USB-CDC ACM node (there is no real baud
#                        clock), but `stty` requires the argument; matters
#                        for a real UART bridge.
#   --timeout N          overall run ceiling in seconds (default 90)
#   --reconnect-wait N   in follow mode, how long to wait for the port to
#                        reappear after it disappears, before giving up
#                        (default 30)
#   --once               stop as soon as the port disappears once, instead
#                        of following re-enumeration (default: follow)
#   --yes                skip the interactive confirmation prompt
#   --out DIR            output directory for captures (default:
#                        ./captures/serial)
#   --no-redact          skip the redaction pass (ANSI-stripping still
#                        happens). Only use this on a capture you already
#                        know is clean, or you understand you must run the
#                        redaction manually before committing anything.
#   -h, --help           print this header and exit
#
# OUTPUT (under --out, default ./captures/serial)
#   <timestamp>-boot-log.txt         raw bytes read from the port, verbatim,
#                                     across ALL sessions of one run, in
#                                     order, separated by RE-OPENED marker
#                                     lines when follow mode reconnects
#   <timestamp>-boot-log-clean.txt   same, with ANSI colour escapes stripped
#                                     and (unless --no-redact) secrets
#                                     redacted
#   <timestamp>-usb-events.txt       OS-log USB attach/detach events
#     (macOS only — see PORTABILITY below)
#
# PASSIVE / READ-ONLY — IMPORTANT
#   This script never writes a single byte to the serial port. The device
#   node is opened strictly read-only: `exec 3<"$PORT"` (a `<` redirect,
#   NEVER `>` and NEVER `<>`) BEFORE any `stty` call, and the reader is
#   plain `cat` reading from that read-only fd into a capture file. No
#   `screen`, no `cu`, no `minicom`, no `printf`/`echo` to the port —
#   nothing sent beyond what a plain read-only open implies. This holds for
#   every open in a run, including automatic reopens in follow mode.
#
#   Know what a read-only open means for YOUR device before you rely on
#   "read-only" meaning "harmless": merely opening a USB-CDC serial port
#   asserts DTR and RTS together as a side effect of the open() call itself
#   on every platform, and that is not something this script chooses to do.
#     - Many classic USB-serial bridge chips (CP210x/CH340/FTDI-style, as
#       used on many hobbyist dev boards) use a DTR+RTS *sequence* to
#       auto-reset into a bootloader — opening the port WILL reset such a
#       board, every time, by design of the bridge chip's own auto-reset
#       circuit, not this script.
#     - Some SoCs' native USB-serial/JTAG peripherals need DTR and RTS
#       driven *independently, in a specific sequence*, to pull strapping
#       pins into a download/bootloader mode — a plain simultaneous
#       open-time assertion of both does not match that pattern and will
#       not trigger it. Even if it did cause an ordinary reset, that is
#       non-destructive on most targets: the device just reboots and
#       re-emits its boot log, which is exactly what this script is trying
#       to capture.
#   Read your device's USB-serial bridge/peripheral documentation and find
#   out which of these it is before treating a read-only open as
#   consequence-free. `clocal` is set below so the open never blocks
#   waiting for a carrier-detect signal a CDC device won't assert.
#
# FOLLOW MODE
#   Capture files are opened in append mode across the whole run (truncated
#   once, up front). On disappearance the script logs it, then waits (up to
#   --reconnect-wait seconds) for a port matching the same pattern to
#   reappear, reopens it read-only exactly as above (skipping the
#   confirmation prompt, not the safety checks), and appends — writing a
#   plain marker line at the boundary:
#     ===== RE-OPENED <port> at HH:MM:SS (session N) =====
#   Pass --once to restore single-session behaviour (stop at first
#   disappearance) for a device you already know stays enumerated, or for
#   scripted tests.
#
# REDACTION
#   Assume a boot/console log contains at least one of: a Wi-Fi SSID, a MAC
#   address, a device serial number (which, on macOS, can be embedded
#   verbatim in the /dev/cu.usbmodem<serial> node NAME ITSELF if firmware
#   derives its USB serial descriptor from a hardware identifier — so the
#   port path is redacted on display too, not just the capture contents), a
#   token, a password, an IP, or an mDNS hostname. All patterns live in the
#   REDACTION_RULES array near the top of this script's body — add more
#   there as you learn what your firmware emits; that is the single place
#   they live, so a skill or doc pointing here does not need to duplicate
#   them. This pass runs automatically; it is NOT a substitute for a manual
#   `grep -rEi` sweep of the output before `git add`, and it is NOT a
#   substitute for never `git add -A`-ing a captures directory. Redacting a
#   file in a later commit does not remove a secret from git history — if
#   one slips through, treat it as burned (rotate it) or rewrite history
#   before anyone else clones.
#
# PORTABILITY (this script is written for macOS; Linux equivalents noted)
#   - `stty -f "$PORT" ...`        -> Linux: `stty -F "$PORT" ...` (this
#                                     script auto-detects via `uname -s`)
#   - vendor-ID check via `ioreg`  -> Linux: falls back to `lsusb` if
#                                     `ioreg` is absent
#   - `/usr/bin/log stream` for    -> Linux: `journalctl -f -k` or
#     usb-events.txt                  `dmesg -w` (skipped automatically if
#                                     /usr/bin/log is absent)
#
# REQUIRES: bash, stty, cat, perl (redaction + ANSI stripping), lsof
# (optional, used for the busy-node check). macOS: ioreg, /usr/bin/log
# (both optional — script degrades gracefully without them). No installs,
# no sudo, no esptool/flashing tool, no serial writes ever.

set -u

# --- edit for a fixed <DEVICE> workflow, or pass --port every time ----------
DEFAULT_PORT_PATTERN="<PORT_GLOB>"   # e.g. /dev/cu.usbmodem*
DEFAULT_VID="<VID>"                  # e.g. 303A — used for the pre-open safety check

print_usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^#//' | sed 's/^ //'
}

TIMEOUT=90
PORT_PATTERN="$DEFAULT_PORT_PATTERN"
BAUD=115200
ASSUME_YES=0
ONCE=0
RECONNECT_WAIT=30
OUT_DIR=""
NO_REDACT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT_PATTERN="$2"; shift 2 ;;
    --baud) BAUD="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --reconnect-wait) RECONNECT_WAIT="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --no-redact) NO_REDACT=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *)
      echo "serial-listen.sh: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if [ "$PORT_PATTERN" = "<PORT_GLOB>" ]; then
  echo "serial-listen.sh: no --port given and DEFAULT_PORT_PATTERN is still a placeholder." >&2
  echo "  Pass --port PATTERN (e.g. --port '/dev/cu.usbmodem*') or edit DEFAULT_PORT_PATTERN." >&2
  exit 2
fi

VID_DEC=""
if [ "$DEFAULT_VID" != "<VID>" ]; then
  # Validate the format explicitly first: `printf '%d' "0x<garbage>"` does
  # NOT reliably fail closed (on this platform's printf it silently yields
  # "0" instead of erroring) — that would otherwise disable the safety
  # check below by pretending it passed with a bogus vendor ID of 0.
  case "$DEFAULT_VID" in
    ''|*[!0-9A-Fa-f]*)
      echo "serial-listen.sh: DEFAULT_VID must be hex digits only (e.g. 303A), got: $DEFAULT_VID" >&2
      exit 2 ;;
  esac
  VID_DEC="$(printf '%d' "0x$DEFAULT_VID" 2>/dev/null)"
fi

[ -n "$OUT_DIR" ] || OUT_DIR="./captures/serial"
mkdir -p "$OUT_DIR"

UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
STTY_FLAG="-f"
[ "$UNAME_S" = "Linux" ] && STTY_FLAG="-F"

# Redacts a serial-derived device node name (e.g. a macOS /dev/cu.usbmodem
# node whose suffix embeds a USB serial descriptor) before it is echoed to
# stdout in status lines below. The REDACT_PERL pass further down applies
# the same rule (plus everything else) to the capture files themselves;
# this is the display-only half of it, defined early so it's in scope
# before the capture loop's first status line.
redact_display() {
  printf '%s' "$1" | perl -pe 's/\b(usbmodem|usbserial|ttyACM|ttyUSB)[0-9A-Za-z]{4,}/$1<REDACTED>/g'
}

TS="$(date +%Y%m%d-%H%M%S)"
BOOT_LOG="$OUT_DIR/${TS}-boot-log.txt"
CLEAN_LOG="$OUT_DIR/${TS}-boot-log-clean.txt"
USB_EVENTS_LOG="$OUT_DIR/${TS}-usb-events.txt"

echo "serial-listen.sh starting"
echo "  port pattern:  $(redact_display "$PORT_PATTERN")"
echo "  baud:          $BAUD"
echo "  timeout:       ${TIMEOUT}s"
if [ "$ONCE" -eq 1 ]; then
  echo "  mode:          --once (stop at first port disappearance)"
else
  echo "  mode:          follow (default) — reconnect-wait ${RECONNECT_WAIT}s per re-enumeration"
fi
echo "  boot log:      $BOOT_LOG"
echo "  usb events:    $USB_EVENTS_LOG"
echo "  (read-only — this script never writes to the serial port)"
echo ""

# --- background OS-log stream (macOS only; skipped gracefully elsewhere) ---
HAVE_LOG_STREAM=0
if [ -x /usr/bin/log ]; then
  HAVE_LOG_STREAM=1
  pred='eventMessage CONTAINS[c] "usbmodem" OR eventMessage CONTAINS[c] "terminateDevice"'
  if [ -n "$VID_DEC" ]; then
    pred='eventMessage CONTAINS[c] "'"$DEFAULT_VID"'" OR '"$pred"
  fi
  /usr/bin/log stream --style compact --predicate "$pred" > "$USB_EVENTS_LOG" 2>&1 &
  LOG_PID=$!
else
  LOG_PID=""
fi

READER_PID=""
INTERRUPTED=0
trap 'INTERRUPTED=1' INT

cleanup() {
  if [ -n "$READER_PID" ] && kill -0 "$READER_PID" 2>/dev/null; then
    kill "$READER_PID" 2>/dev/null
    wait "$READER_PID" 2>/dev/null
  fi
  exec 3<&- 2>/dev/null
  if [ -n "$LOG_PID" ] && kill -0 "$LOG_PID" 2>/dev/null; then
    kill "$LOG_PID" 2>/dev/null
    wait "$LOG_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

script_start=$SECONDS

# match_port sets PORT to the first existing path matching $PORT_PATTERN (a
# literal path also works, e.g. a fixed device path or a test FIFO).
# Unquoted on purpose so the shell glob-expands it.
match_port() {
  PORT=""
  if [ -e "$PORT_PATTERN" ]; then
    PORT="$PORT_PATTERN"
    return 0
  fi
  for p in $PORT_PATTERN; do
    if [ -e "$p" ]; then
      PORT="$p"
      return 0
    fi
  done
  return 1
}

# wait_for_port: polls every 0.05s for a match. Always bounded by the
# overall $TIMEOUT from $script_start; if $1 is non-empty, additionally
# bounded by that many more seconds from now (the reconnect-wait cap in
# follow mode). Sets $PORT and returns 0 on success, 1 on giving up.
wait_for_port() {
  extra="$1"
  local_deadline=""
  if [ -n "$extra" ]; then
    local_deadline=$(( SECONDS + extra ))
  fi
  while [ "$INTERRUPTED" -eq 0 ]; do
    now=$SECONDS
    if [ $(( now - script_start )) -ge "$TIMEOUT" ]; then
      return 1
    fi
    if [ -n "$local_deadline" ] && [ "$now" -ge "$local_deadline" ]; then
      return 1
    fi
    if match_port; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

# --- vendor-ID presence check: ioreg first, lsusb fallback, skip if neither -
check_vid_present() {
  if [ -z "$VID_DEC" ]; then
    echo 1   # no VID configured (DEFAULT_VID left as placeholder) — don't block
    return
  fi
  if command -v ioreg >/dev/null 2>&1; then
    ioreg -p IOUSB -l -w 0 2>/dev/null | grep -c "idVendor\" = $VID_DEC"
  elif command -v lsusb >/dev/null 2>&1; then
    lsusb 2>/dev/null | grep -ic "ID $DEFAULT_VID:"
  else
    echo 1
  fi
}

: > "$BOOT_LOG"

SESSION=0
TIMED_OUT=0

while [ "$INTERRUPTED" -eq 0 ]; do
  if [ "$SESSION" -eq 0 ]; then
    wait_for_port ""
    rc=$?
  else
    echo "$(date '+%H:%M:%S') port disappeared, waiting for re-enumeration... (up to ${RECONNECT_WAIT}s)"
    wait_for_port "$RECONNECT_WAIT"
    rc=$?
  fi

  if [ "$rc" -ne 0 ] || [ -z "$PORT" ]; then
    if [ "$SESSION" -eq 0 ]; then
      echo "VERDICT: port never appeared"
      exit 0
    else
      echo "$(date '+%H:%M:%S') gave up waiting for re-enumeration (reconnect-wait ${RECONNECT_WAIT}s or overall timeout reached)"
    fi
    break
  fi

  SESSION=$(( SESSION + 1 ))
  echo "$(date '+%H:%M:%S') port found: $(redact_display "$PORT") (session $SESSION)"

  # --- identity + busy checks BEFORE opening anything (every session) -----
  # Neither of these opens the device node: the vendor-ID check queries the
  # USB registry (read-only), and `lsof` inspects open-file tables.
  vid_count="$(check_vid_present)"
  if [ "$vid_count" -eq 0 ] 2>/dev/null; then
    echo "refusing to open $(redact_display "$PORT"): no vendor 0x$DEFAULT_VID USB device is currently enumerated" >&2
    echo "(this does not prove $(redact_display "$PORT") itself is that device -- registry-to-node mapping" >&2
    echo " isn't reliably greppable per-node from the shell -- but it rules out an unrelated," >&2
    echo " non-matching CDC node satisfying a loose glob)" >&2
    exit 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    busy_pid="$(lsof -t -- "$PORT" 2>/dev/null | head -n 1)"
    if [ -n "$busy_pid" ]; then
      echo "refusing to open $(redact_display "$PORT"): already held by pid $busy_pid" >&2
      echo "if that is an in-progress flashing session, DO NOT proceed." >&2
      exit 1
    fi
  fi

  if [ "$SESSION" -eq 1 ]; then
    if [ "$ASSUME_YES" -eq 0 ]; then
      echo "About to open: $(redact_display "$PORT")"
      echo "  A matching USB device is enumerated, and no other process currently"
      echo "  holds this node open."
      if [ "$ONCE" -eq 0 ]; then
        echo "  Follow mode: if the port later disappears and a matching node"
        echo "  reappears (device reset / re-enumeration), it will be reopened"
        echo "  automatically — this confirmation is only asked once, for the"
        echo "  first open of the run."
      fi
      printf 'Proceed? [y/N] '
      if [ -t 0 ]; then
        read -r reply
      else
        reply=""
      fi
      case "$reply" in
        y|Y|yes|YES|Yes) : ;;
        *) echo "aborted"; exit 1 ;;
      esac
    fi
  else
    echo "$(date '+%H:%M:%S') re-opening $(redact_display "$PORT") automatically (subsequent reopens of the same node path do not prompt)"
  fi

  # --- open read-only and start the (backgrounded) reader ------------------
  # Read-only open BEFORE stty, exactly as documented above: `<`, never `>`
  # or `<>`.
  exec 3<"$PORT"

  if [ -c "$PORT" ]; then
    # real serial device: raw mode, no echo, no software flow control.
    # Baud is required stty syntax but irrelevant for a USB-CDC ACM port.
    # clocal: don't block waiting for a carrier-detect signal a CDC device
    # won't assert.
    stty $STTY_FLAG "$PORT" raw -echo -ixon -ixoff "$BAUD" clocal 2>/dev/null
  else
    echo "  (not a character device — skipping stty, e.g. FIFO test path)"
  fi

  if [ "$SESSION" -gt 1 ]; then
    echo "===== RE-OPENED $PORT at $(date '+%H:%M:%S') (session $SESSION) =====" >> "$BOOT_LOG"
  fi

  cat <&3 >> "$BOOT_LOG" 2>/dev/null &
  READER_PID=$!

  echo "$(date '+%H:%M:%S') capturing... (reader pid $READER_PID, session $SESSION)"

  # --- wait for the node to disappear, or overall timeout, or Ctrl-C -------
  while [ "$INTERRUPTED" -eq 0 ]; do
    now=$SECONDS
    if [ $(( now - script_start )) -ge "$TIMEOUT" ]; then
      echo "$(date '+%H:%M:%S') timeout (${TIMEOUT}s) reached; stopping capture"
      TIMED_OUT=1
      break
    fi
    if [ ! -e "$PORT" ]; then
      echo "$(date '+%H:%M:%S') port disappeared: $(redact_display "$PORT")"
      break
    fi
    sleep 0.1
  done

  if [ "$INTERRUPTED" -eq 1 ]; then
    echo "$(date '+%H:%M:%S') interrupted; stopping capture"
  fi

  # stop the reader now (cleanup-on-EXIT will also do this, but settle the
  # file before the next session or post-processing runs)
  if [ -n "$READER_PID" ] && kill -0 "$READER_PID" 2>/dev/null; then
    kill "$READER_PID" 2>/dev/null
    wait "$READER_PID" 2>/dev/null
  fi
  exec 3<&- 2>/dev/null

  [ "$INTERRUPTED" -eq 1 ] && break
  [ "$TIMED_OUT" -eq 1 ] && break
  [ "$ONCE" -eq 1 ] && break
  # follow mode, port disappeared naturally, time remains: loop back and
  # wait (up to --reconnect-wait) for a matching node to reappear.
done

# --- post-process: strip ANSI colour escapes (covers ALL sessions, since ---
# BOOT_LOG was only truncated once, before the loop, and every session
# appended to it) -------------------------------------------------------------
perl -pe 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//g' "$BOOT_LOG" > "$CLEAN_LOG" 2>/dev/null

# --- redaction pass -----------------------------------------------------
# Add/edit patterns HERE — this array is the single place they live. Every
# entry is a complete perl s/// statement (with a leading "$n +=" so the
# final count is accurate); values stop before a quote, comma, newline, or
# ANSI escape so a quoted or comma-terminated field is bounded correctly,
# and \x27/\x22 are used instead of literal quote characters so each entry
# stays a plain single-quoted bash string.
REDACTION_RULES=(
  '$n += s/((?:Loaded\s+last\s+(?:connected\s+)?SSID|SSID|ssid)\s*[:=]\s*["\x27]?)([^\r\n\x1b"\x27,]+)/$1<SSID-REDACTED>/gi;'
  '$n += s/(Connecting\s+to\s+)([^\r\n\x1b"\x27,]+)/$1<SSID-REDACTED>/gi;'
  '$n += s/(\bAP:\s*)([^\r\n\x1b"\x27,]+)/$1<SSID-REDACTED>/gi;'
  '$n += s/((?:password|passphrase|passwd|psk|token)\s*[:=]\s*["\x27]?)([^\r\n\x1b"\x27,]+)/$1<REDACTED>/gi;'
  '$n += s/\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){2}):(?:[0-9A-Fa-f]{2}:){2}[0-9A-Fa-f]{2}\b/$1:xx:xx:xx/g;'
  '$n += s/\b([0-9A-Fa-f]{12})\b/<MAC-REDACTED>/g;'
  '$n += s/\b(?:usbmodem|usbserial|ttyACM|ttyUSB)[0-9A-Za-z]{4,}\b/<PORT-SERIAL-REDACTED>/g;'
  '$n += s/\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b/<IP-REDACTED>/g;'
  '$n += s/\b[0-9A-Za-z-]+\.local\b/<HOSTNAME-REDACTED>/g;'
)

build_redact_program() {
  echo 'my $n = 0;'
  i=0
  while [ "$i" -lt "${#REDACTION_RULES[@]}" ]; do
    echo "${REDACTION_RULES[$i]}"
    i=$(( i + 1 ))
  done
  echo 'print STDERR "$n";'
}

redact_log() {
  f="$1"
  if [ ! -f "$f" ]; then
    echo 0
    return
  fi
  prog="$(build_redact_program)"
  out="$(perl -0777 -pi -e "$prog" "$f" 2>&1 1>/dev/null)"
  case "$out" in
    ''|*[!0-9]*) out=0 ;;
  esac
  echo "$out"
}

if [ "$NO_REDACT" -eq 1 ]; then
  echo "redaction pass: SKIPPED (--no-redact) — grep this capture by hand before committing it"
  total_redactions=0
else
  raw_redactions="$(redact_log "$BOOT_LOG")"
  clean_redactions="$(redact_log "$CLEAN_LOG")"
  total_redactions=$(( raw_redactions + clean_redactions ))
  echo "redaction pass: ${total_redactions} substitutions"
fi

bytes="$(wc -c < "$CLEAN_LOG" 2>/dev/null | tr -d ' ')"
lines="$(wc -l < "$CLEAN_LOG" 2>/dev/null | tr -d ' ')"
[ -z "$bytes" ] && bytes=0
[ -z "$lines" ] && lines=0

echo ""
echo "===================================="
echo "Sessions:       $SESSION"
echo "Bytes captured: $bytes"
echo "Lines captured: $lines"
echo ""
echo "--- first 5 lines ---"
head -n 5 "$CLEAN_LOG" 2>/dev/null
echo ""
echo "--- last 15 lines ---"
tail -n 15 "$CLEAN_LOG" 2>/dev/null
echo ""

# Starter marker list for an ESP-IDF-style boot log; edit for your firmware
# family's own banner/tag vocabulary (see the framed-serial-protocol and
# firmware-image-analysis skills for more on what these markers mean).
MARKERS=(
  "Starting" "button" "Button" "console" "Reset check" "SD card"
  "Disk mode" "boot" "rst:" "ESP-ROM" "wifi" "ble" "partition" "RE-OPENED"
)
echo "--- marker grep ---"
i=0
while [ "$i" -lt "${#MARKERS[@]}" ]; do
  m="${MARKERS[$i]}"
  hits="$(grep -n -F -- "$m" "$CLEAN_LOG" 2>/dev/null)"
  if [ -n "$hits" ]; then
    echo "[$m]"
    printf '%s\n' "$hits"
  fi
  i=$(( i + 1 ))
done

echo ""
echo "Raw log:    $BOOT_LOG"
echo "Clean log:  $CLEAN_LOG"
if [ "$HAVE_LOG_STREAM" -eq 1 ]; then
  echo "USB events: $USB_EVENTS_LOG"
fi
echo ""

if [ "$SESSION" -eq 0 ]; then
  echo "VERDICT: port never appeared"
elif [ "$bytes" -eq 0 ]; then
  echo "VERDICT: no data received across $SESSION session(s) (port opened but silent)"
else
  echo "VERDICT: captured $lines lines across $SESSION session(s)"
fi
