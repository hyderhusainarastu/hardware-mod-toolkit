# Marker greps for an embedded boot log

Run these against the ANSI-stripped clean capture (`grep -n -F -- "<marker>" clean.txt`) once a
capture finishes. Each line found is a candidate fact worth pulling into your findings doc — a
banner string, a reset reason, a mode transition. Treat a marker hit as a lead to read in context,
not a fact on its own; the same string can mean different things across firmware builds.

A `serial-listen.sh`-style capture script should run this whole list automatically and print any
matches after the byte/line-count summary, so you see the signal without re-reading the whole log
by hand.

## Boot identity

- `<PRODUCT_STRING>` / the device's actual boot banner text — confirms which firmware image is
  running and often carries a version number in the same line.
- `ESP-ROM`, `Pico`, or your target's boot-ROM banner equivalent — the very first thing printed,
  before any application code runs; useful for confirming you captured from the true beginning of
  boot versus joining a session already in progress.
- `rst:` (ESP-IDF's reset-reason line) or your platform's equivalent (`Reset reason:`,
  `WDT_RESET`, `BOR_RESET`) — power-on vs. watchdog vs. software vs. brownout vs. deep-sleep-wake.
  This is often the fastest way to distinguish "the device rebooted because of X" without any other
  instrumentation.

## Boot-mode branching

- `button`, `Button` — case both ways; firmware log lines are inconsistent about capitalization and
  a case-sensitive grep will silently miss half of them.
- `console` — a console/debug mode being entered or a console driver being installed.
- `Disk mode`, `disk mode` — a mass-storage / bootloader-style mode announcement.
- `breadcrumb` — an ad hoc marker some firmware authors leave at decision points; worth grepping
  for even if you don't expect it, since it costs nothing and occasionally is exactly the trace you
  need.
- `Reset check` — an explicit boot-time check for a reset-triggered mode (recovery, factory-reset
  gesture, escape hatch).

## Partition / update state

- `partition` — partition-table reads, slot selection.
- `boot` (broad — expect noise, but catches "booting slot", "boot count", etc. that don't match a
  narrower pattern).
- `Updates` / `update` / `escape hatch` — an update-mode entry point or an interrupt-the-update
  gesture being checked.

## Peripherals and buses

- `SD card` — SD/MMC card detect and mount lines; also look for capacity-limiting or card-type
  messages (SDSC/SDHC/SDXC) which can tell you the real card capacity class even when the reported
  byte count is ambiguous.
- `display`, your panel driver's component name (e.g. a controller family or vendor string) — LCD/
  OLED controller init.
- `USB`, `HID` — USB stack bring-up, host vs. device role selection.
- `gclcd`, or your target's specific driver/component names — grep for component names you already
  know from a firmware static-analysis pass; a component that's *linked* into the image often logs
  something recognizable at init even if you never found its full API surface by reading source.

## Radios

- `wifi`, `ble` — case-insensitive is usually right here; radio init and association/pairing
  attempts. Cross-reference against the redaction pass (§4 of the main skill) since these lines are
  exactly where an SSID or MAC is most likely to appear.

## Capture-tooling markers (not from the device — from the capture script itself)

- `RE-OPENED` — the follow-mode session-boundary marker described in the main skill's §3. Grepping
  for it tells you at a glance how many times the port disappeared and reappeared during one run,
  without re-reading the whole file.

## Building your own list

Start from whatever you already know about the target from static analysis (linked components,
strings extracted from a firmware image) or from the vendor's own public documentation, and add to
this list as you find new markers worth watching for. A marker list is cheap to extend and costs
nothing to over-include — an unmatched marker just doesn't print a line.
