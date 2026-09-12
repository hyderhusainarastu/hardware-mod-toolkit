---
name: serial-and-usb-recon
description: Passively observe a USB device enumerating and capture its boot/console log without ever writing a byte to it, then redact SSIDs, MACs and serial numbers before the capture is committed. Use when identifying an unknown USB device, capturing a boot log from a short-lived serial node, or preparing captures for a repository.
---

# serial-and-usb-recon

Passive, read-only USB/serial reconnaissance on an unknown or partially-understood embedded
device, plus the redaction discipline that has to be in place *before* the first capture, not
after. Two lessons drove this skill, both paid for in a real project:

1. **A device's serial node can be short-lived.** One worked example enumerated a USB-Serial/JTAG
   node for **exactly ~4.2 seconds** at boot before an internal PHY hand-over dropped it. Plugging
   in and running an interactive terminal (`screen`, `minicom`, `cu`) by hand never caught the boot
   log — by the time a human typed the command, the node was already gone. The fix is a poller that
   waits for the node, opens it strictly read-only, captures until it disappears, and follows
   re-enumeration across as many sessions as it takes.
2. **Boot logs leak secrets by default.** Console/boot output from a Wi-Fi-capable device routinely
   contains the SSID it last associated with, its own MAC address, and a USB serial-number string
   baked into the enumerated device-node name itself. In the worked example, an SSID was committed
   to git before redaction was added — and the string still lives in that repository's history,
   because redacting a file after a commit does not remove it from history. Automatic redaction
   plus a manual grep gate has to run on *every* capture, from the very first one.

Use this skill together with `scripts/usb-watch.sh` and `scripts/serial-listen.sh` (invoke as
`${CLAUDE_PLUGIN_ROOT}/scripts/usb-watch.sh` under a plugin install, or `scripts/usb-watch.sh` from
a repo checkout) — this document explains what they do and why, plus the parts you'll need to
adapt (baud rate, marker strings, vendor ID) for `<DEVICE>`.

Placeholders used below: `<DEVICE>`, `<VENDOR>`, `<VID>`, `<PID>`, `<PORT_GLOB>`, `<BAUD>`,
`<PRODUCT_STRING>`.

## 1. Observe before you open

Before any serial port is touched, characterize the USB behaviour with a **read-only** watcher —
one that never opens `/dev/cu.*` (macOS) or `/dev/ttyACM*`/`/dev/ttyUSB*` (Linux), and only:

- streams the OS log for enumeration-related lines (macOS: `/usr/bin/log stream` — call the
  **absolute path**, because `log` is shadowed by a builtin/function in some zsh configs and a bare
  `log` silently does the wrong thing; Linux: `journalctl -f -k` or `dmesg -w`),
- polls the device-node glob (`ls <PORT_GLOB>` / `ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null`),
- polls the enumeration registry (macOS: `ioreg -p IOUSB -l -w 0`; Linux: `lsusb -d <VID>:<PID>` or
  watch `udevadm monitor --udev`) on a short interval (0.2 s is fine — fast enough to catch a
  multi-second window, cheap enough to run forever).

Run it, *then* plug the device in (or press the button/combo under test), and read off one of four
verdict shapes:

- **(A) Device never seen** — no `<VID>` match appeared on the bus at all. Wrong port state, wrong
  cable (power-only cables exist and look identical to data cables), or wrong mode entirely.
- **(B) Attached, then died quickly, no serial node** — the device enumerated and vanished within a
  few seconds without ever publishing a serial node. This is what a "silent"/normal operating mode
  looks like if it claims the USB bus for something other than a CDC console (e.g. it becomes a
  mass-storage device, or a USB-HID host, and the console never gets the PHY).
- **(C) Attached with a serial node, stayed attached** — a console/debug mode was reached. This is
  the state `serial-listen.sh` (§2) should be run against.
- **(D) Other** — cycles of attach/detach, a serial node that came and went, multiple devices. Worth
  a closer read of the raw log capture before assuming anything.

Minimal read-only poll loop (portable shape; `scripts/usb-watch.sh` is the maintained, full version
with timestamps, an `ioreg` snapshot on first attach, and a plain-language verdict):

```sh
while true; do
  vid_seen=$(ioreg -p IOUSB -l -w 0 2>/dev/null | grep -c 'idVendor" = <VID_DECIMAL>')
  node="$(ls <PORT_GLOB> 2>/dev/null | head -n 1)"
  # ...compare against previous state, print ATTACHED / SERIAL NODE / DETACHED on change...
  sleep 0.2
done
```

Never open the node in this pass. The point of this step is to know, before you write a line of
capture code, whether a serial console exists at all, how long it lives, and under what trigger —
so you don't waste time debugging a capture script against a port that was never really there.

## 2. Capture read-only — the exact pattern that matters

Once §1 has shown a serial node exists and roughly how long it lives, capture it. The order of
operations here is the whole trick; get any step out of order and you either miss the boot log or
risk sending the device an unintended signal.

1. **Resolve the port.** Match `<PORT_GLOB>` (a literal path also works, for a fixed port or a test
   FIFO). If nothing matches within a bounded wait, say so and stop — don't hang forever.
2. **Verify the vendor ID before opening anything.** Query the registry again (same `ioreg`/`lsusb`
   check as §1) and refuse to proceed if no `<VID>` device is currently enumerated. This doesn't
   *prove* the resolved node belongs to that device (port-to-node mapping isn't always reliably
   greppable from the shell), but it rules out silently opening an unrelated CDC node that happens
   to match a loose glob.
3. **Refuse if the node is already open.** `lsof -t -- "$PORT"` — if another process (an in-progress
   `esptool`/flash session, a second capture script, a stray `screen`) already holds it, stop. Do
   not proceed.
4. **Confirm once, interactively**, unless the caller passed an explicit "yes" flag. Print what was
   resolved and what's about to happen before opening. In a follow-mode capture (§3), ask this only
   before the *first* open of a run — automatic reopens after a later re-enumeration don't re-prompt
   (steps 2–3 still run again before every reopen, though).
5. **Open strictly read-only, then configure the line, then read:**

   ```sh
   exec 3<"$PORT"                                    # `<`  — NEVER `>` and NEVER `<>`
   stty -f "$PORT" raw -echo -ixon -ixoff <BAUD> clocal   # macOS: `stty -f`; Linux: `stty -F`
   cat <&3 >> "$CAPTURE_FILE" &
   READER_PID=$!
   ```

   Order matters: the `exec 3<` read-only open happens *before* `stty` touches the port, and the
   reader is a plain `cat` from the already-read-only fd — never `screen`, `cu`, `minicom`, or
   anything that could also write. `clocal` matters too: without it, `stty`/the open can block
   waiting for a carrier-detect signal a USB-CDC device will never assert.

**On DTR/RTS.** Opening a USB-CDC serial port asserts DTR and RTS as a side effect of the `open()`
call itself, on every platform — this is not something the capture script chooses to do, and it
happens on every read-only open in this pattern too. Before you rely on "read-only" meaning
"harmless," find out what your target does with DTR/RTS:

- Some MCU dev-board USB-serial bridges (classic Arduino-style boards with a CP210x/CH340/FTDI
  bridge chip) use a DTR+RTS *sequence* to auto-reset into the bootloader — for those, opening the
  port **will** reset the board, every time, by design (the bridge chip's auto-reset circuit does
  it, not your script).
- The worked example's SoC (an ESP32-S3 using its native USB-Serial-JTAG peripheral) needs DTR and
  RTS driven *independently, in a specific sequence*, to pull its two strapping pins — a plain
  simultaneous open-time assertion of both together does not match that pattern and does not
  trigger bootloader/download mode. And even if an ordinary reset happened incidentally, that's
  non-destructive on this target: it just reboots and re-emits the boot log, which is exactly what
  the capture is trying to record anyway.

Know which of these your `<DEVICE>` is before you decide a read-only open is inconsequential —
"read-only" and "side-effect-free" are not the same claim.

## 3. Follow re-enumeration

A device that changes internal state — a PHY hand-over between an on-die debug-serial peripheral
and an application USB stack, a watchdog reset, a deliberate reboot, a replug — will make the node
disappear mid-capture. A single-shot `cat` exits right there and the rest of the boot sequence is
lost. Follow mode fixes this:

- Capture files are opened in **append** mode across the whole run (truncate once, up front; append
  from then on), so nothing is lost when a session boundary happens.
- On disappearance, log it, then re-run §2 steps 2–5 (skipping the interactive confirmation) with a
  bounded **reconnect-wait** deadline — give up after `N` seconds of no reappearance, not forever.
- Write a plain marker line into the capture at every reopen so the boundary is visible later in the
  text file, e.g.:

  ```
  ===== RE-OPENED <PORT> at 2026-09-02 22:21:50 (session 3) =====
  ```

- Bound the *entire run* — initial wait, every capture session, every reconnect wait — by one total
  timeout ceiling, so a script that's following reconnects forever can't become a script that hangs
  forever.
- Keep a `--once` escape hatch that restores plain single-session behaviour (stop at the first
  disappearance) — useful for a device you already know stays up, or for scripted tests.

The worked example needed exactly this: three captured attempts each enumerated cleanly, then were
dropped after ~4.24 s (a deterministic internal PHY hand-over, not noise — the jitter across three
trials was under a millisecond), and the only way to see what happened *after* that boundary — on a
different code path that stayed enumerated indefinitely — was a script built to keep waiting and
keep appending, not one that exited at the first disconnect.

## 4. Redaction is not optional

Assume a boot/console log contains at least one of: a Wi-Fi SSID, a MAC address, a device serial
number, a token, a password. Redact automatically, at capture time, before the file is ever staged
for commit — and *also* grep it by hand before `git add`. Both steps matter: automatic redaction
because a human will forget on at least one capture; the manual grep gate because a regex list is
never complete against firmware you don't control the source of.

The full pattern set, with test strings and a self-test command, is in
`references/redaction-patterns.md`. The categories:

- **SSID** — after known log keys (`SSID:`, `ssid=`, `Connecting to `, `AP:`), stopping at a quote,
  comma, newline, or ANSI escape so it doesn't swallow a trailing color-reset code.
- **MAC addresses** — both colon-separated and bare-12-hex forms. Consider partial masking
  (`aa:bb:cc:xx:xx:xx`, OUI visible) over full masking if you want to keep "which vendor's radio"
  without keeping the unique host part.
- **USB serial-number strings embedded in the device node's own name.** This one is easy to miss:
  if firmware derives its USB serial descriptor from a hardware identifier (a MAC, a chip ID), the
  **port path itself** — `/dev/cu.usbmodemXXXXXXXX` — leaks it, and every log line that prints
  `$PORT` (status messages, error messages, this skill's own scripts) leaks it right along with the
  capture contents. Redact the port-path display *and* the capture files with the same rule.
- **Passwords / passphrases / PSK / tokens** — `password=`, `passphrase:`, `psk=`, `token:`, etc.
- Add IP addresses, hostnames, and anything else specific to `<DEVICE>`'s firmware as you discover
  it emits them — the pattern list is a floor, not a ceiling.

**Never `git add -A` a captures directory.** Stage capture files individually, after running the
redaction pass and a manual `grep -rEi` sweep for anything that looks like a network name, a
credential, or a hex string longer than a few bytes. If something slips through anyway: redacting
the file in a new commit does **not** remove it from git history — the string is still reachable in
every clone that already pulled that commit. The only real fixes after the fact are history rewrite
(disruptive, coordinate with anyone else who cloned) or treating the secret as burned and rotating
it. This is exactly what happened in the worked example: an SSID reached a commit before the
redaction pass existed, and it is still in that repository's history today. Have redaction in place
**before the first capture**, not after the first mistake.

## 5. What to read out of a boot log

Once you have a clean capture, the useful signal is usually:

- **Banner and version string** — often the only place a build/firmware version is stated in plain
  text.
- **Reset reason** — most SoC boot ROMs print why they reset (power-on, watchdog, software, brownout,
  deep-sleep wake, external pin). This is often the fastest way to confirm *why* a device rebooted
  without any other instrumentation.
- **Partition / slot / OTA selection** — which firmware slot or partition the bootloader picked, and
  why (useful for anything with an A/B or factory/OTA layout).
- **Peripheral init lines and bus addresses** — I2C/SPI device probes, addresses found, bus
  frequencies. This is often the *only* free source of "what's actually wired to what" outside of
  reading a schematic — a device that logs `Error reading <PART> status register` or `probing I2C
  addr 0x2C` is telling you what silicon it thinks is present, and where.
- **Warnings that look like defects but aren't.** Boot logs are noisy; a retried peripheral probe or
  a benign capacity-limiting message is easy to over-read as evidence of a hardware fault. Don't
  promote a log line to a hardware claim without checking whether it's routine.

## 6. Post-processing

After a capture (single-session or multi-session via follow mode) finishes:

1. **Strip ANSI color escapes** for a clean, greppable version alongside the raw file:
   `perl -pe 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//g' raw.txt > clean.txt`
2. **Print the first ~5 and last ~15 lines** — the banner is at the top, the most recent/relevant
   state is at the bottom.
3. **Grep a marker list** relevant to the firmware family under test (a starter list for ESP-IDF-
   style logs is in `references/log-markers.md`) and print any line that hits.
4. **Emit a one-line verdict** — lines/bytes captured, number of follow-mode sessions, or one of the
   negative outcomes (`port never appeared`, `port opened but silent — no data received`). A script
   that runs unattended should always end in one of these three shapes, not silence.

## Reference files

- `references/redaction-patterns.md` — the full regex pattern set (SSID, MAC, embedded USB serial,
  credentials), with test strings for each and a copy-pasteable self-test command.
- `references/log-markers.md` — the marker-grep list worth running against an embedded boot log,
  and why each one is there.

## Scripts

- `scripts/usb-watch.sh` — the §1 read-only USB observer (four-verdict-shape output, `--timeout`).
- `scripts/serial-listen.sh` — the §2/§3/§4/§6 capture tool: read-only open, follow mode across
  re-enumerations, built-in redaction pass, marker grep, one-line verdict (`--port`, `--timeout`,
  `--yes`, `--once`, `--reconnect-wait`).
