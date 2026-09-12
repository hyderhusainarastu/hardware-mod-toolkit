#!/usr/bin/env bash
#
# usb-watch.sh — passive, read-only USB attach/detach observation for an
# embedded device you are reverse-engineering.
#
# WHAT THIS IS FOR
#   Run this in ONE terminal, then physically plug <DEVICE> into the host
#   (or press whatever button/combo is under test) in real time. It reports,
#   in plain words:
#     - whether a USB device matching --vid ever enumerates on the bus,
#     - whether a matching device node (--port-glob) gets published for it,
#       and
#     - how long the device stays attached before it disconnects (if it
#       does).
#   At the end it prints a plain-language VERDICT summarizing what happened,
#   based on how long the device stayed attached and whether a device node
#   ever showed up. This is the FIRST step before writing any capture code —
#   know whether a console/serial mode exists at all, how long it lives, and
#   under what trigger, before you build something to read from it.
#
# USAGE
#   ./usb-watch.sh --vid 303A --port-glob '/dev/cu.usbmodem*'
#   ./usb-watch.sh --vid 303A --port-glob '/dev/cu.usbmodem*' --timeout 30
#   ./usb-watch.sh --vid 303A --port-glob '/dev/cu.usbmodem*' --out captures/usb
#
#   Run it, THEN plug in the device. Watch the printed lines. Press Ctrl-C
#   when done (or let --timeout expire).
#
# FLAGS
#   --timeout N       stop after N seconds (default: run until Ctrl-C)
#   --vid HEX         USB vendor ID to watch for, 4 hex digits, no "0x"
#                      prefix (e.g. 303A). No default — either pass this or
#                      edit DEFAULT_VID below for a fixed <DEVICE> workflow.
#   --port-glob GLOB  device-node glob to poll (e.g. '/dev/cu.usbmodem*' on
#                      macOS, '/dev/ttyACM*' or '/dev/ttyUSB*' on Linux). No
#                      default — either pass this or edit DEFAULT_PORT_GLOB.
#   --out DIR         output directory for captures (default: ./captures/usb)
#   -h, --help        print this header and exit
#
# OUTPUT (under --out, default ./captures/usb)
#   <timestamp>-usb-watch-log.txt     background OS-log stream capture
#   <timestamp>-usb-watch-ioreg.txt   one-time IORegistry snapshot, taken at
#                                      the first moment attach is detected
#   Live status lines (ATTACHED / SERIAL NODE / DETACHED / VERDICT) print to
#   this terminal as they happen.
#
# VERDICT SHAPES
#   (A) Device never seen        — no matching VID ever appeared on the bus.
#   (B) Attached, then gone,      — enumerated and vanished within a few
#       no serial node               seconds, no device node ever published.
#                                     Typical of a mode that claims the USB
#                                     bus for something other than a console
#                                     (mass storage, HID, etc).
#   (C) Attached with a serial    — a console/debug mode was reached; this is
#       node, stayed attached        the state to run a capture tool against.
#   (D) Other                    — attach/detach cycles, a node that came and
#                                     went, or anything that doesn't cleanly
#                                     match B or C. Read the raw log capture.
#
# SAFETY NOTES
#   - READ-ONLY with respect to the device. This script never opens a device
#     node, never runs a flashing tool (no esptool / dfu-util / avrdude /
#     etc.), and never sends a single byte. It only lists device nodes
#     (ls-style glob match), queries the USB registry (ioreg), and reads the
#     OS's unified log (/usr/bin/log stream).
#   - /usr/bin/log is called by its ABSOLUTE path deliberately: `log` is
#     shadowed by a function/builtin in some shell configs (zsh in
#     particular), and a bare `log` can silently do the wrong thing or
#     nothing at all.
#   - Physical actions on the device (plugging it in, pressing buttons) are
#     performed by a human, one at a time — this script cannot cause a
#     button-combo reset or recovery-mode entry by itself. If your device
#     has a known destructive button combo (e.g. a hold-both-buttons-10s
#     reset/recovery pattern), that is a reminder for the human at the
#     keyboard, not something this script does or checks for.
#   - Ctrl-C stops the watch at any time; the background log-stream process
#     is always cleaned up on exit (normal, timeout, or Ctrl-C).
#
# PORTABILITY (this script is written for macOS; Linux equivalents noted)
#   - `/usr/bin/log stream ...`   -> Linux: `journalctl -f -k` or `dmesg -w`
#   - `ioreg -p IOUSB -l -w 0`    -> Linux: `udevadm monitor --udev
#                                     --subsystem-match=usb` or
#                                     `lsusb -d <VID>:<PID>`
#   - `/dev/cu.usbmodem*` node    -> Linux: `/dev/ttyACM*` or `/dev/ttyUSB*`
#   This script best-effort falls back to `lsusb` for the VID check when
#   `ioreg` is unavailable, but the background log stream and IORegistry
#   snapshot are macOS-only; on Linux, swap those two lines for the
#   `journalctl`/`udevadm` equivalents above and the rest works unchanged.
#
# REQUIRES: bash, ls-style glob expansion. macOS: ioreg, /usr/bin/log. No
# installs, no sudo, no serial port ever opened, no flashing tool ever run.

set -u

# --- edit these two for a fixed <DEVICE> workflow, or just pass --vid / -----
# --- --port-glob on the command line every time -----------------------------
DEFAULT_VID="<VID>"                  # e.g. 303A
DEFAULT_PORT_GLOB="<PORT_GLOB>"      # e.g. /dev/cu.usbmodem*

print_usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^#//' | sed 's/^ //'
}

TIMEOUT=""
VID="$DEFAULT_VID"
PORT_GLOB="$DEFAULT_PORT_GLOB"
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      TIMEOUT="$2"; shift 2 ;;
    --vid)
      VID="$2"; shift 2 ;;
    --port-glob)
      PORT_GLOB="$2"; shift 2 ;;
    --out)
      OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      print_usage; exit 0 ;;
    *)
      echo "usb-watch.sh: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if [ "$VID" = "<VID>" ]; then
  echo "usb-watch.sh: no --vid given and DEFAULT_VID is still a placeholder." >&2
  echo "  Pass --vid HEX (e.g. --vid 303A) or edit DEFAULT_VID at the top of this script." >&2
  exit 2
fi
if [ "$PORT_GLOB" = "<PORT_GLOB>" ]; then
  echo "usb-watch.sh: no --port-glob given and DEFAULT_PORT_GLOB is still a placeholder." >&2
  echo "  Pass --port-glob GLOB (e.g. --port-glob '/dev/cu.usbmodem*') or edit DEFAULT_PORT_GLOB." >&2
  exit 2
fi

# ioreg prints idVendor as decimal, not hex — convert --vid (hex) once.
# Validate the format explicitly first: `printf '%d' "0x<garbage>"` does NOT
# reliably fail closed (on this platform's printf it silently yields "0"
# instead of erroring), which would otherwise pass through as a bogus-but-
# accepted vendor ID of 0.
case "$VID" in
  ''|*[!0-9A-Fa-f]*)
    echo "usb-watch.sh: --vid must be hex digits only (e.g. 303A), got: $VID" >&2
    exit 2 ;;
esac
VID_DEC="$(printf '%d' "0x$VID" 2>/dev/null)"
if [ -z "$VID_DEC" ]; then
  echo "usb-watch.sh: could not parse --vid: $VID" >&2
  exit 2
fi

[ -n "$OUT_DIR" ] || OUT_DIR="./captures/usb"
mkdir -p "$OUT_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$OUT_DIR/${TS}-usb-watch-log.txt"
IOREG_FILE="$OUT_DIR/${TS}-usb-watch-ioreg.txt"

echo "usb-watch.sh starting"
echo "  vendor ID:   0x$VID ($VID_DEC decimal)"
echo "  port glob:   $PORT_GLOB"
echo "  out dir:     $OUT_DIR"
echo "  log capture: $LOG_FILE"
if [ -n "$TIMEOUT" ]; then
  echo "  timeout:     ${TIMEOUT}s"
else
  echo "  timeout:     none (Ctrl-C to stop)"
fi
echo "  Plug the device in now (or it's already in)."
echo ""

# --- vendor-ID presence check: ioreg first, lsusb fallback for Linux --------
check_vid_present() {
  if command -v ioreg >/dev/null 2>&1; then
    ioreg -p IOUSB -l -w 0 2>/dev/null | grep -c "idVendor\" = $VID_DEC"
  elif command -v lsusb >/dev/null 2>&1; then
    lsusb 2>/dev/null | grep -ic "ID $VID:"
  else
    echo 0
  fi
}

# --- background log stream (always via /usr/bin/log, never bare `log`) ------
HAVE_LOG_STREAM=0
if [ -x /usr/bin/log ]; then
  HAVE_LOG_STREAM=1
  /usr/bin/log stream --style compact --predicate \
    'eventMessage CONTAINS[c] "'"$VID"'" OR eventMessage CONTAINS[c] "usbmodem" OR eventMessage CONTAINS[c] "IOSerialBSDClient" OR eventMessage CONTAINS[c] "terminateDevice"' \
    > "$LOG_FILE" 2>&1 &
  LOG_PID=$!
else
  echo "  (no /usr/bin/log on this platform — skipping OS-log capture; see the" >&2
  echo "   PORTABILITY note in this script's header for the Linux equivalent)" >&2
  LOG_PID=""
fi

INTERRUPTED=0
trap 'INTERRUPTED=1' INT

cleanup() {
  if [ -n "$LOG_PID" ] && kill -0 "$LOG_PID" 2>/dev/null; then
    kill "$LOG_PID" 2>/dev/null
    wait "$LOG_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

# --- state -------------------------------------------------------------------
attached=0
serial=0
first_attach_seen=0
first_attach_time=0
attach_time=0
serial_ever=0
serial_node_path=""
ioreg_saved=0
last_attach_duration=0
attach_cycles=0
still_attached=0

script_start=$SECONDS

# match_port sets PORT to the first existing path matching $PORT_GLOB (a
# literal path also works, e.g. a fixed device path or a test file). Unquoted
# on purpose so the shell glob-expands it; on no match the loop body still
# runs once with the literal pattern text, which then fails the -e test.
match_port() {
  PORT=""
  if [ -e "$PORT_GLOB" ]; then
    PORT="$PORT_GLOB"
    return 0
  fi
  for p in $PORT_GLOB; do
    if [ -e "$p" ]; then
      PORT="$p"
      return 0
    fi
  done
  return 1
}

while [ "$INTERRUPTED" -eq 0 ]; do
  now=$SECONDS

  if [ -n "$TIMEOUT" ]; then
    elapsed_total=$(( now - script_start ))
    if [ "$elapsed_total" -ge "$TIMEOUT" ]; then
      break
    fi
  fi

  vid_count="$(check_vid_present)"
  match_port && node="$PORT" || node=""

  new_attached=0
  [ "$vid_count" -gt 0 ] 2>/dev/null && new_attached=1

  new_serial=0
  [ -n "$node" ] && new_serial=1

  if [ "$new_attached" -ne "$attached" ]; then
    if [ "$new_attached" -eq 1 ]; then
      attach_time=$now
      attach_cycles=$(( attach_cycles + 1 ))
      if [ "$first_attach_seen" -eq 0 ]; then
        first_attach_seen=1
        first_attach_time=$now
      fi
      rel=$(( now - first_attach_time ))
      echo "$(date '+%H:%M:%S') ATTACHED: vendor 0x$VID device present (t=+${rel}s)"

      if [ "$ioreg_saved" -eq 0 ] && command -v ioreg >/dev/null 2>&1; then
        ioreg -r -c IOUSBHostDevice -l -w 0 > "$IOREG_FILE" 2>/dev/null
        ioreg_saved=1
      fi
    else
      dur=$(( now - attach_time ))
      last_attach_duration=$dur
      echo "$(date '+%H:%M:%S') DETACHED after ${dur}s"
    fi
    attached=$new_attached
  fi

  if [ "$new_serial" -ne "$serial" ]; then
    if [ "$new_serial" -eq 1 ]; then
      serial_ever=1
      serial_node_path="$node"
      if [ "$first_attach_seen" -eq 1 ]; then
        rel=$(( now - first_attach_time ))
      else
        rel=0
      fi
      echo "$(date '+%H:%M:%S') SERIAL NODE: ${node} published (t=+${rel}s)"
    fi
    serial=$new_serial
  fi

  sleep 0.2
done

now_exit=$SECONDS
if [ "$attached" -eq 1 ]; then
  # still attached when the watch stopped (timeout/Ctrl-C) — report
  # "how long it stayed attached" as attached-so-far.
  last_attach_duration=$(( now_exit - attach_time ))
  still_attached=1
fi

echo ""
echo "===================================="
echo "VERDICT:"

if [ "$first_attach_seen" -eq 0 ]; then
  echo "(A) No vendor 0x$VID device seen"
else
  if [ "$serial_ever" -eq 0 ] && [ "$last_attach_duration" -lt 8 ]; then
    echo "(B) Device appeared but died after ~${last_attach_duration}s and no serial node: a non-console mode ran"
  elif [ "$serial_ever" -eq 1 ] && [ "$last_attach_duration" -ge 8 ]; then
    echo "(C) Device stayed attached >= 8s (measured ~${last_attach_duration}s) and a serial node published: console mode reached"
  else
    if [ "$serial_ever" -eq 1 ]; then serial_word="was"; else serial_word="was NOT"; fi
    if [ "$still_attached" -eq 1 ]; then attached_word="yes"; else attached_word="no"; fi
    echo "(D) Other: attached for ~${last_attach_duration}s, serial node ${serial_word} published, still attached at exit: ${attached_word}, attach/detach cycles observed: ${attach_cycles}"
  fi
fi

if [ -n "$serial_node_path" ]; then
  echo "Serial node observed: $serial_node_path"
else
  echo "Serial node observed: (none)"
fi

if [ "$HAVE_LOG_STREAM" -eq 1 ]; then
  echo "Log capture:    $LOG_FILE"
fi
if [ "$ioreg_saved" -eq 1 ]; then
  echo "ioreg snapshot: $IOREG_FILE"
fi
echo "Note: this script never opened a device node and sent nothing to the device."
