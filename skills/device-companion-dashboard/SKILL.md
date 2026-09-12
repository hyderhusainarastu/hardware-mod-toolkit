---
name: device-companion-dashboard
description: "Build a host-side companion dashboard that renders to a small monochrome or few-level device panel: image and text rendering to 1 or 2 bpp, dirty-rectangle partial refresh, a YAML widget/layout config, user-switchable presets, and one-shot notifications that coexist with a running loop. Use when driving a small device display from a host, or when a panel update is too slow or visibly garbled."
---

# Device companion dashboard

Turning a device panel into a useful companion display is mostly two engineering problems: getting
readable output out of a 1-bit (or few-level) panel, and not re-sending the whole framebuffer every
cycle. The worked example (`<REPO>`, a 240x80 1bpp panel over a per-byte I2C link) measured a full
refresh at ~220 ms (2412 I2C transactions, ~91 µs each) and a realistic dirty band at roughly a
tenth of that — the difference between a usable dashboard and a flickering, laggy toy. The rules
below (page-snapped dirty rects, a bounding-box fallback chosen by an explicit cost model, a
periodic forced full refresh, a host-side shadow of what's actually on the glass) plus the
YAML-config/widget/preset shape are directly reusable on a different `<DEVICE>`.

## 1. The render pipeline

Fixed order: **fit → grayscale → quantize → pack.**

- **Fit**: scale the source image to fit `(<PANEL_WIDTH>, <PANEL_HEIGHT>)` preserving aspect ratio
  (Lanczos or similar), then letterbox onto a background-filled canvas of exactly the target size.
  Grayscale in, grayscale out — keep this step orthogonal to quantization.
- **Quantize** to `2**bpp` levels. Support at least two interchangeable methods and pick per widget:
  - **plain nearest-level threshold, no dithering** — the right default for *text*. Dithering
    blurs edges to fake intermediate tones; a glyph doesn't have intermediate tones, it has strokes,
    and blurring them is strictly worse at small sizes.
  - **ordered (Bayer 4x4) dither** — the right default for *photographic or moving* content. Its
    threshold pattern is identical every frame, so on a moving scene only the underlying image
    changes, not the dither noise itself (the worked example rejected Floyd–Steinberg for a
    screen-mirror/game-video widget for exactly this reason: independent per-frame error diffusion
    makes the noise pattern visibly "boil" frame to frame).
  - **Floyd–Steinberg error diffusion** — fine for a single still image widget, avoid it for
    anything that redraws the same content repeatedly at speed.
- **Level convention**: represent pixels internally as a flat array of levels in `[0, 2**bpp - 1]`
  with **level 0 always darkest**, regardless of final bpp. Quantizers then never need to know which
  bpp they're feeding — only the packer (step 2) needs to know the wire convention.

## 2. Pixel packing — pin these down explicitly, per `<DEVICE>`

Get these four facts from your controller's own datasheet or firmware source, never by guessing:

| bpp | pixels/byte | leftmost pixel | row stride | "dark" on the wire |
|---|---|---|---|---|
| 1 | 8 | most-significant bit | `ceil(width / 8)` bytes | typically bit **1** = pixel on |
| 2 | 4 | most-significant pair | `ceil(width*2 / 8)` bytes | typically level **0** (of 0..3) |

Pad every row to a whole byte independently — never let one row's leftover bits bleed into the
next row's first pixel. A stride or bit-order mismatch does not crash; it shows up as diagonal
tearing, mirrored content, or a shifted/garbled image, which is much slower to diagnose than a
crash. Write a unit test that packs a single known pattern (e.g. a checkerboard, or "all pixels
on") and asserts the exact byte sequence, before ever sending real content to hardware.

## 3. Dirty-rectangle partial refresh

Keep a host-side **shadow** — the levels array the host believes is currently on the glass — and
diff every new frame against it before deciding what to send.

1. **Snap to page granularity.** Most controllers address partial refreshes in fixed-height row
   bands (the worked example: 8-row pages), not pixel-exact rectangles. Expand any dirty region's
   `y`/`h` outward to whole page bands; leave `x`/`w` column-exact.
2. **Two candidate plans, pick the cheaper one by an explicit cost model**, not a fixed size
   threshold:
   - one `DirtyRect` per changed page band, each tight to that band's own changed columns; or
   - a single page-snapped bounding rect covering every changed pixel.
   Cost a plan as `sum(window_overhead + stride(rect.w, bpp) * rect.h)` over its rects —
   `window_overhead` is the fixed per-rect cost of reprogramming the controller's address window
   (measure it: it's a real, nonzero number of transactions on most I2C/SPI panel controllers).
   Send whichever total is lower. This naturally degrades to "just send the bounding box" once
   enough of the frame has changed, without a hand-tuned magic-number threshold.
3. **Force a full refresh periodically** (e.g. every 60th cycle) regardless of what the diff says.
   This bounds the damage of any missed update, dropped ACK, or shadow/reality drift you didn't
   anticipate — it should be a cheap insurance policy, not something you rely on for correctness.
4. **Only trust the shadow once the corresponding write is known to have landed.** If your
   transport can silently drop or truncate a write, update the shadow *after* confirmation
   (an ACK, or a successful synchronous call), not optimistically before sending — an untruthful
   shadow makes the diff wrong in a way that's invisible until content stops updating.
5. **Invalidate the shadow (force the next frame full) whenever you can't be sure what's on the
   glass**: after a transport reconnect, and after switching to a different layout/preset (§5) —
   diffing a new layout's first frame against the old layout's shadow can coincidentally match
   bytes and wrongly skip regions that need to be drawn.

## 4. Config and widgets

```yaml
display:
  width: <PANEL_WIDTH>     # informational default only -- see below
  height: <PANEL_HEIGHT>
  bpp: 1                    # 1 or 2

refresh_seconds: 60

layout:
  grid: { cols: 12, rows: 5 }

widgets:
  - type: clock
    at: [0, 0]              # [col, row], 0-indexed
    span: [12, 3]           # [width_cols, height_rows]
    options: { format: "%H:%M:%S" }
```

- **Never trust `display:` over the real device.** If your handshake reports actual panel geometry
  (it should), always render against that, not the config file's declared size — the same config
  then can't accidentally mis-target a device with a different real panel, and the same file works
  unmodified across two units.
- **Grid cells are fractions, not pixels.** Convert `at`/`span` to a pixel rect as
  `x0 = round(canvas_w * col / cols)` (and so on) — the same config then renders sensibly at any
  target resolution, not just the one `display:` happens to name.
- **Widget contract**: `render(ctx) -> image` of exactly the tile's pixel size. A widget must
  **never raise** for a normal "no data" or I/O-failure condition — draw a fallback ("--", "No
  events", …) instead. The compositor's own per-widget exception guard (small `[error]` tile,
  never blanking the whole dashboard) is a last resort, not a first line of defense: a widget that
  relies on it loses dirty-rect determinism on the cycle it fires.
- **Provider pattern** for any widget doing real I/O (subprocess, OS APIs, network): define a small
  provider interface with at least a `NullProvider` that does **no I/O** and returns a deterministic
  placeholder. This is what makes an offline preview tool and a fast, hardware-free test suite
  possible at all.
- **A cheap "should I actually redo my work this cycle" check is worth adding per widget, even
  though it's easy to skip.** The worked example didn't have one, and paid for it: a system-stats
  widget spawned a ~390 ms subprocess call unconditionally every render cycle; combined with a loop
  that slept a flat interval *after* each cycle's work (§7) rather than to an absolute clock tick,
  the real frame period drifted to ~1.4x the requested interval and a seconds-resolution clock
  widget visibly ticked in an uneven 2-1-2-1 pattern that looked like a bug but was pure aliasing
  between the drifted period and whole-second display resolution. Cache or throttle a widget's own
  expensive I/O independently of render cadence — "it renders instantly" and "it costs nothing to
  compute" are different claims.
- **Config path resolution**, a reasonable three-tier order to copy: (1) the given path, as-is,
  relative to cwd or absolute; (2) the same with an extension appended if missing, still
  cwd-relative; (3) that name's bare basename joined onto a bundled examples directory — any
  directory component the caller passed is dropped at this step, since it only ever means "look in
  the bundled set." An unresolvable path should be a clean error naming every candidate tried, not
  a traceback.
- **Overflow, uniformly**: single-line text that overflows horizontally gets ellipsized (binary
  search the longest prefix + "…" that still fits); multi-line content word-wraps and silently
  drops whatever doesn't fit vertically, rather than drawing past the tile's edge.

## 5. Presets

A *second*, parallel set of configs, distinct from one-off "run this exact layout" configs: an
ordered manifest — `{name, display_label, file}` per entry — that the device can switch between
live over the link. **List order is wire order.** Whatever index a device-reported
"selection changed" event carries gets looked up positionally against this exact list; reordering
the manifest silently reassigns what index means what to a device that's already out there, so
treat that reorder as a breaking change, not a cosmetic one.

- **Validate at load time, not at wire-encode time.** Cap the display label's byte length and the
  preset count to whatever the wire format actually allows (the worked example: ≤20 UTF-8
  bytes/name, ≤8 presets) and raise a clear error immediately for a manifest mistake — don't let it
  surface only as an opaque exception three layers down inside the encoder.
- **Three useful host modes**, worth supporting as distinct flags: run forever on one fixed config
  and never touch presets at all; start pinned to one named preset while still telling the device
  the full menu (and then *ignore* later device-driven selection changes — an explicit pin should
  not be silently overridden); or start on a default and freely follow whatever the device reports.
- **A preset switch — locally forced or device-driven — must force the next frame full**, exactly
  like a reconnect (§3.5): the shadow belongs to whatever was on screen before the switch.

## 6. Notifications that don't fight a running loop for the transport

If your link is single-consumer (one serial/USB connection, one process at a time — many are, and
some panel controllers get actively confused if two hosts both try to drive them), a one-shot
notification command cannot just open the transport itself whenever a long-lived dashboard loop
might already be running. The worked example hit this directly: two host processes briefly both
held the port open, the second one's handshake reset the device's session sequencing out from under
the first, and an unrelated bug turned the resulting protocol-level warning fatal. The fix that
generalizes:

1. **A long-lived loop writes a small lock file** (pid + start time) for the duration of its run,
   removed on clean exit. A stale lock (the writer died without cleaning up) reads as "not running"
   the moment its pid is no longer alive — so a crash never permanently strands the one-shot path.
2. **The one-shot command checks that lock *first*.** If a loop is running, it writes its request to
   a small JSON file the loop polls once per cycle — it does not attempt to open the transport at
   all in this, the common, case.
3. **Only if no loop is running does the one-shot command try a direct connection** — and even then,
   a "busy" failure (lock missing/stale but something else genuinely holds the transport) falls back
   to the same request file rather than retrying the open.

**Two distinct drawing paths, deliberately different:**

- **Standalone** (direct connection succeeded, nothing else running): draw with your own low-level
  primitives, hold for N seconds, then explicitly clear/restore to background. "Restore" here can
  only mean "back to blank," since no render pipeline's memory of prior content exists in this path.
- **Loop-mediated** (a loop already owns the transport): composite the banner directly onto the
  loop's own already-rendered frame each cycle, **before** that cycle's dirty-rect diff runs —
  never issue a separate draw call outside the composite. If you draw independently of the
  composite, the shadow (§3) goes false: the very next diff decides "this region didn't change"
  (because the composite it's diffing against didn't) and skips resending it, leaving the banner
  stuck on the physical screen forever instead of restoring. Baking it into the composite keeps the
  diff honest, so a later cycle naturally computes "this region changed back" as an ordinary dirty
  rect.
- Restore timing in the loop-mediated path is bounded by the loop's own cycle interval, not a
  separate timer — a request shorter than one refresh interval restores **late**, on the next cycle
  after expiry. Document this rather than silently accept it; it's a real, user-visible property.

## 7. Performance — measure and record these, don't assume them

- Full-refresh time in ms (worst case: a mostly-dark ↔ mostly-light full-panel transition).
- A realistic partial/dirty-band time in ms.
- Bytes sent per cycle in the steady-state (mostly static) case.
- Sustained cycles/second at your real interval, broken down into render+quantize time vs.
  data-provider I/O (subprocess/network calls) vs. transport time — so a future regression is
  attributable to a specific stage, not a vague "it got slower."
- If your controller offers a bulk-write mode as an alternative to one transaction per byte, treat
  any pre-existing performance number for it with suspicion until you've watched the actual panel
  while it's active — an old "optimistic" number with no one having watched the glass while it ran
  is worthless (a byte written with acknowledgment-checking disabled reports success even when
  nothing on the bus answered).
- **Wall-clock-align a running loop's sleep.** Sleep to an absolute next tick
  (`start_time + n * interval - now`), not a flat `sleep(interval)` tacked on after each cycle's own
  work — a flat post-work sleep makes the real period `interval + this cycle's cost`, and if that
  cost is an appreciable fraction of `interval`, a display reading at whole-unit resolution (a
  seconds clock, say) can visibly alias into an uneven tick pattern even though nothing about the
  underlying data is actually wrong. Log a warning whenever a cycle's real cost exceeds the
  interval, and resync to the next *future* tick (skipping any already-missed ones) rather than
  firing a burst of back-to-back catch-up cycles.

Keep this table over time (a `decision-record.md` entry — see
`${CLAUDE_PLUGIN_ROOT}/templates/decision-record.md`, or `templates/decision-record.md` in a repo
checkout — is a reasonable home) so a future regression shows up as a number that changed, not a
vibe that something feels laggier.

## 8. Testing

- **A fake/mock transport**, driven by a manual clock, so the loop's own logic (cycle cadence,
  reconnect handling, preset switching, notify overlay) is testable deterministically and instantly
  — no real device, no real wall-clock sleep.
- **An offline preview entry point**: the same renderer, no transport at all, writing a plain image
  file — makes visual regressions reviewable without hardware, and is the baseline every golden-image
  test below compares against.
- **A golden-image test per widget**: render it at a few realistic real row heights with a
  `NullProvider`, compare against a checked-in reference image. Add one test that asserts *every*
  registered widget type has at least one such case, so a newly added widget can't silently ship
  untested.
- Also test explicitly: a provider that raises never crashes `render()`; an unknown widget type (or
  a config that names one) renders a placeholder tile, not a stack trace or a blank composite.
- **A font-size legibility regression test is worth stealing directly**: render the same string at
  several font sizes through your *real* quantizer (not a mockup of it) and diff/eyeball the
  results. This is exactly how the worked example caught and proved the bug below — see
  `${CLAUDE_PLUGIN_ROOT}/templates/incident-report.md` (or `templates/incident-report.md`) for a
  shell to write this kind of finding up in.

## A lesson worth stealing: one inconsistent size cap, two garbled widgets

Two text widgets on the same 16px grid row as two other, unaffected text widgets rendered visibly
broken glyphs (a `P`'s bowl and a `U`'s stroke breaking apart, letters merging). Root cause, found
by re-rendering the exact same string at increasing font sizes through the real threshold quantizer:
two widgets capped their auto-fit font size at `row_height // 2` while the other two used the *full*
row height for the same box — an unexplained, undocumented halving with no comment justifying it.
Forced to roughly half the font size the box actually allowed, anti-aliased strokes thresholded to
hard 1-bit lost thin details that were never in danger at the size the box actually supported. The
fix was one line per widget (stop halving); the proof was rendering the same content at several
sizes through the *same real code path* and comparing. **Auto-fit text to the full available box,
never an arbitrary fraction of it without a documented reason — and when small text looks garbled,
suspect the font-size cap before the dither, the transport, or the panel.**
