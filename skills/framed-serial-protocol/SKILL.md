---
name: framed-serial-protocol
description: "Design and implement a framed request/response protocol over a serial or CDC link between a host and an embedded device: frame layout with CRC, sequence numbers, ACK/NACK with informational error codes, resync, timeouts, a mock transport for tests, and exclusive port ownership. Use when building host tooling that talks to custom firmware, or when debugging desynchronisation, duplicate frames, or port contention."
---

# framed-serial-protocol

A byte stream has no message boundaries of its own. Everything in this skill exists to answer one
question honestly: **what does the receiver do with the next byte when it has no idea what it
means?** A protocol that only has an answer for the happy path is not finished — it is untested.

Two rules below were not designed in up front. They were extracted from a real incident where a
protocol that was *specified* correctly on paper still crashed a production host, because the code
implementing it did not agree with the spec at every layer. Read §4 and §5 first if you read
nothing else.

Placeholders used throughout: `<DEVICE>`, `<PRODUCT_STRING>`, `<PORT_GLOB>`, `<REPO>`.

The full spec template lives at `${CLAUDE_PLUGIN_ROOT}/templates/protocol-spec.md` (plugin install)
or `templates/protocol-spec.md` (repo checkout) — this skill explains *why* each section of that
template is shaped the way it is; fill the template in for your own device rather than duplicating
its structure here.

## 1. Frame layout

Fix these once, in a spec document, before writing a line of code:

- A **magic** (2 bytes is enough — e.g. `'M','D'`) that anchors resync. It must not be a byte
  sequence that occurs constantly in ordinary payloads.
- **VERSION** (1 byte). A receiver that sees an unknown version rejects the frame and resyncs — it
  does not guess, and it does not try to parse a frame shaped by a version it doesn't speak.
- **TYPE** (1 byte), **FLAGS** (1 byte, bitmap — reserved bits sent `0`, ignored on receipt so a
  future flag doesn't break an old receiver), **SEQ** (u16 LE, wraps), **LEN** (u16 LE, payload
  length, with a hard maximum below any plausible single-allocation size).
- **PAYLOAD** (`LEN` bytes, type-specific — the frame layer does not know or care what's in it).
- **CRC32**, LE, computed over an *exactly specified span*. Say explicitly whether the magic and
  version are inside the CRC or not — a worked example below is the reference implementation's own
  header (9 bytes: magic·2 + version·1 + type·1 + flags·1 + seq·2 + len·2) plus payload, CRC field
  itself excluded.

**Pin the CRC to a named, standard implementation and prove it, don't just cite it.** State the
exact algorithm (poly, init, reflection, final XOR) in the spec, then in the *same document* give a
Python one-liner that computes it (`zlib.crc32` implements IEEE 802.3 / zlib CRC-32 exactly:
reflected poly `0xEDB88320`, init `0xFFFFFFFF`, input/output reflected, final XOR `0xFFFFFFFF`) and
a matching call for whatever the firmware side actually uses (ESP-IDF: `esp_rom_crc.h`'s
`esp_crc32_le(0xFFFFFFFF, buf, len) ^ 0xFFFFFFFF`). Then generate a shared table of test vectors
(§12-style) from one implementation and assert the other reproduces every value byte-for-byte in a
unit test — see `references/frame-worked-example.md` for the exact vector format and a worked
example. "The host library and the firmware agree on CRC" is a claim a test proves, not a design
document asserts.

Publish the size arithmetic once you've picked the payload cap, so nobody has to recompute it:
frame size = header + payload + CRC (e.g. `9 + LEN + 4`); min frame = header + 0 + CRC; max frame =
header + max-payload + CRC.

## 2. The decoder is a state machine, not a length-prefixed read

Do not write `read(9)` then `read(length)` and call it a parser. A serial link truncates at
arbitrary points, may start mid-frame (the host attaches to a device that's already running), and
delivers bytes in whatever chunk sizes the OS feels like. The decoder must be fed bytes — one at a
time or in arbitrary chunks, with an identical result either way — and never block waiting for more
than are actually available.

States: **HUNT** (scan for the magic, discard everything before it) → **HEADER** (accumulate the
fixed header, reject on bad version or over-length) → **PAYLOAD** (accumulate `LEN` bytes) → **CRC**
(accumulate the CRC field, verify, dispatch or reject) → back to **HUNT** either way.

A magic byte sequence appearing *inside* a payload is not a bug to guard against with escaping —
HUNT is only entered when the receiver is not already inside a frame, and a frame's extent is fixed
by its own `LEN`. A stray magic can only be latched onto after a corruption has already happened,
and the CRC check that follows rejects it. Don't add byte-stuffing/escaping to work around a
problem the state machine + CRC combination doesn't have; it only adds a second thing that can be
implemented wrong.

**The decoder deliberately does not know what payload length is correct for a given message type.**
"Length is wrong for this type" is a dispatch-layer concern (checked after a structurally valid
frame is already decoded), not a framing-layer one — keep that boundary. This also means a
generic "bad length" error code has two different reasons behind it (over the wire cap vs. wrong for
this specific type) and both should be distinguishable if you want good diagnostics.

Track a `resync_events` counter on both sides and log it. A rising count is the *first* visible
symptom of a transport-level bug (a badly wired handshake, a driver dropping bytes, DTR/RTS
mishandling) — it will show up before anything else does, so surface it somewhere a human will
actually see it (a status field, a periodic log line), not just as an internal counter nobody reads.

## 3. Sequence numbers

- **One counter per originator**, `u16`, wrapping through zero, incremented per frame that
  originates from that side. Host and device each own an independent counter — they are not shared,
  and a reply does not need one of its own: **a reply echoes the request's SEQ instead of consuming
  a new value from the responder's counter.** State this explicitly, because it's the detail most
  likely to get "fixed" incorrectly by someone who assumes every outbound frame burns a sequence
  number.
- **What resets the expectation:** the handshake does. When a host (re)connects and sends its
  hello/reset message, the device treats that as the start of a new session — it must forget
  whatever sequence state it had for the previous session's peer. Make this an explicit, named
  operation in the implementation (not just "it happens to work because the counter starts over") —
  a receiver that's about to re-issue a hello should call it before waiting for the reply, not rely
  on the far side inferring a reset from a value that merely looks small.
- **Duplicate detection**: keep a window of the last N (8 is a reasonable, cheap default) distinct
  sequence numbers seen from a peer. An idempotent message type (anything without side effects that
  depend on being applied exactly once — a query, a "set X" command, a draw command) whose SEQ is in
  that window is dropped without re-executing it, and its previous reply is re-sent if one was
  requested. A **non-idempotent, chunked/streaming** message type (a data chunk addressed by its own
  offset, for instance) must be exempted from that dedup — retransmitting a chunk is a legitimate
  recovery action, not a duplicate to be silently swallowed.
- **A forward jump far larger than any plausible retry gap is a new session, not damage.** Pick a
  threshold well above your normal timeout/retry envelope (the reference implementation uses 1024
  against a window of 8) and when a peer's SEQ jumps that far forward, clear the duplicate window
  and carry on rather than reporting a few hundred "missing" frames that were never sent. This
  covers a reconnect that, for whatever reason, didn't get an explicit session-reset call first.
- **What must NOT consume a sequence number:** anything the responder didn't originate as a fresh,
  trackable, request-shaped frame. If your device also emits unsolicited, fire-and-forget
  notifications (button presses, log lines, status pushes) that are never acknowledged and never
  retried, decide up front whether they share the sender's normal counter or need their own space,
  and write the answer down — don't leave it implicit. (The worked example's device emits events
  from its own normal counter, which works cleanly there specifically *because* replies already
  don't consume a counter value, so the only other device-originated traffic is events — if your
  device also originates non-reply, non-event frames, that reasoning doesn't automatically transfer
  and needs its own decision.)

## 4. Informational vs. fatal NACKs — the lesson that cost a production crash

**Classify every single error/NACK code as fatal or informational, in the spec, in a table, before
you write the client.** A fatal code means the request failed and the caller should treat it as an
error. An informational code means "something noteworthy happened, and the real answer is still
coming" — the receiver processed the request anyway and a normal reply follows.

The canonical informational case is a **sequence-gap notice**: the receiver noticed it missed some
number of frames from this peer, but per §3 it doesn't try to repair the gap — it just reports it
(for logging/telemetry) and then **processes the frame that arrived as if nothing were wrong**,
because there is no retransmission machinery forcing it to do otherwise. That means the peer that
sent the frame gets *two* things back: the gap notice, and the actual reply — and if your transport
naively treats "the first reply carrying this frame's sequence number" as *the* answer, it will hand
the gap notice to the caller instead of the real reply.

**This exact bug shipped and crashed a production dashboard loop.** The chain was:

1. A second process opened the same serial port (see §5 — this should have been impossible, but
   wasn't yet), sent its own hello, and reset the device's sequence-tracking state.
2. The first process's next frame landed far ahead of the device's freshly-reset expectation. The
   device correctly reported a sequence-gap notice — informational, by spec — and then correctly
   processed and replied to the frame anyway, exactly as the spec said it should.
3. The host's transport layer treated "first reply matching this SEQ" as the request's answer. The
   gap notice *is* such a reply. It got returned as if it were the response.
4. The code path that turns a NACK-shaped reply into an exception did so unconditionally — it had no
   idea this particular NACK code was supposed to be harmless.
5. The one call site that could have caught that exception and recovered gracefully only caught a
   narrower exception type than what was actually raised, so nothing did, and the process died.

**Every one of those five links was independently a small, locally-reasonable design choice.** No
single line "looks wrong" in isolation. That's exactly why a spec being correct on paper is not
enough: the fix has to exist at *every* layer that could otherwise disagree with it —

- The **transport's response-matching logic** must special-case every informational code by name:
  on seeing one, log/count it, then **keep waiting** (within the same request's timeout budget) for
  the real reply that the spec already promises follows it. Do not treat it as the answer.
- The **exception hierarchy** must make "this was a NACK" and "this was fatal" separable — either a
  distinct exception subclass per fatal-vs-informational, or (simpler) never surface an
  informational code as an exception at all, since the transport layer above already absorbed it.
- **Any `except SomeBroadType` around a send/request call site** needs to actually catch whatever
  exception type your NACK-to-exception path raises — a narrower catch than that is a silent gap
  that turns "log a warning and recover" into "the process dies," and it will not show up in
  testing unless the informational path is specifically exercised.

Put the classification table in the spec itself (`references/error-codes.md` here is a starter you
can extend) and cross-reference it from the transport's NACK-handling code and its docstring, so the
next person who adds an error code has to look at both.

## 5. Exclusive port ownership — the other half of the same incident

The second, compounding bug in the incident above: **nothing prevented a second process from
opening the same serial port.** A design doc had already declared the link "single-consumer, one
process at a time" in prose. Nothing in the code enforced it. A second CLI invocation opened the
port, sent its own hello, and silently reset the first connection's sequence state out from under
it — invisibly, with no error raised anywhere, because pyserial (and most serial libraries) default
to a *non-exclusive* open.

- **Open exclusively.** On POSIX, pass whatever your serial library's exclusive-lock option is
  (pyserial: `exclusive=True`, which takes a POSIX `flock` on the device node). A second process's
  open then fails loudly instead of succeeding silently.
- **Give that failure its own exception type** (a `PortBusy`, distinct from "no device found" and
  "wrong device") so callers can react correctly — typically: fall back to talking to the process
  that already owns the port via a small IPC file, rather than retrying the open.
- **Match the device by USB product string, never by device-node glob alone.** A device's own debug
  bridge, or an unrelated device, can enumerate on the exact same `<PORT_GLOB>` your firmware's node
  matches — and some devices expose more than one USB personality (an unrelated debug console for a
  few seconds at boot, in addition to the real link's node). Enumerate all matching nodes, then only
  ever open the one whose product string (or descriptor) equals `<PRODUCT_STRING>` — the string your
  own firmware sets and nothing else on the bench does. If a caller passes an explicit port path
  that doesn't match, refuse it by default; only proceed on an explicit opt-in flag, and log loudly
  that you did.
- **A long-running process that owns the port should be the single point of contact for one-shot
  commands, not a second peer.** If a background loop already holds the port open, a separate
  one-shot CLI invocation (a notification, a status query) should detect that (a lock file the loop
  writes/removes around its run is enough) and route the request through a small IPC file the loop
  polls once per cycle, rather than ever attempting a second `open()` on the port at all. Treat
  `PortBusy` itself as a fallback trigger for the same IPC path, in case the lock file is stale or
  missing — belt and suspenders, not either/or.

The lesson underneath both halves: **a resource a design doc calls "single-consumer" is not
actually single-consumer until something at the OS/library level enforces it.** Intent documented in
prose and intent enforced in code are different claims, and the gap between them is invisible until
a second caller exists — which, the moment a second CLI command or process that could plausibly
touch the same port exists, it already does.

## 6. Timeouts, retries, and what a retry does to the sequence number

State each of these numbers in the spec, not just in code:

- How long the requester waits for a reply before retrying, and how many retries before giving up
  and declaring the link dead.
- Whether a **retry reuses the same sequence number** or allocates a new one. Reusing it is usually
  correct (the receiver's duplicate window then naturally absorbs a reply that arrives *after* the
  requester already gave up and retried) — but say so explicitly, because "does a retry get a new
  SEQ" is exactly the kind of question that gets answered two different ways in two different
  implementations if nobody wrote it down. A silently wrong answer here shows up as a phantom
  sequence gap on the *next* legitimate frame.
- A separate, longer timeout for the initial handshake (it may need to wait through a device boot or
  a USB re-enumeration) versus the steady-state per-request timeout.
- A mid-frame stall timeout on the receiver side (bytes started arriving, then stopped) that
  discards the partial frame and resyncs, distinct from full-frame timeouts — and decide whether it
  NACKs at all (a mid-stream stall may simply mean the sender was unplugged; NACKing into the void
  accomplishes nothing).
- An idle-link timeout that triggers a liveness probe (a ping) before declaring the link dead, so a
  quiet-but-healthy link isn't mistaken for a dead one.

## 7. A mock transport, and a gate that makes a real port impossible in tests

Every test that touches this protocol should run against a fake serial object — something with
`.read(n)` / `.write(bytes)` / `.close()` and nothing else the tests need — never a real port. Two
concrete failure modes this avoids: tests that occasionally hang waiting on real hardware that isn't
attached in CI, and (worse) a test or an agent shell accidentally sending a real command to a
physical device it should never touch.

Add an explicit environment gate, checked at the point a real port would otherwise be opened: if the
gate variable is set and no fake-transport override was supplied, **refuse to open anything** and
raise a distinct exception naming the gate. This makes "never open a real serial port from this
shell" an enforced refusal instead of a convention someone has to remember — export the gate
variable in any dev/agent/CI shell, and pass the fake transport explicitly wherever tests actually
need to exercise the transport layer. This is the same "prose intent isn't enforcement" lesson from
§5, applied to test isolation instead of port ownership.

## 8. Version the protocol; prefer capability bits to version sniffing

Keep a version-history table in the spec: what changed, whether it was additive/non-breaking or a
breaking `VERSION` bump, and which firmware/host release first implemented it. A message type that
was specified in version N but not actually implemented until version N+2 is a real thing that
happens — record the gap, don't silently assume "specified" means "sent."

Prefer a **capability bitmap** (advertised in the handshake reply) over having callers sniff the
protocol version to decide whether a feature exists. `if version >= 3` breaks the moment a feature
gets backported to a maintenance release of an older major version, or a build ships with a feature
gated off by a compile-time flag; `if caps & CAP_FOO` doesn't care how the capability got there. A
host should always take capability-dependent behaviour (does this build support RTC-backed
timestamps? extended pixel depth? a specific compression scheme?) from the bitmap, never from
inferring it out of the version number.

## Checklist before calling a framed protocol done

- [ ] Frame layout, CRC span, and CRC algorithm are written down with a runnable reference
      implementation, not just prose.
- [ ] A shared test-vector file exists and both sides' implementations are asserted against it in a
      unit test (see `references/frame-worked-example.md`).
- [ ] The decoder is a HUNT/HEADER/PAYLOAD/CRC state machine fed arbitrary byte chunks, never a
      blocking length-prefixed read.
- [ ] Every error/NACK code is classified fatal-vs-informational in a table
      (`references/error-codes.md`), and the transport's response-matching logic, exception
      hierarchy, and call-site `except` clauses all agree with that table.
- [ ] The port is opened exclusively; a second-open failure has its own distinct exception; a
      long-running owner routes one-shot requests through IPC rather than a second open.
- [ ] Device matching uses a product string, never a device-node glob alone.
- [ ] Timeouts, retry counts, and what a retry does to the sequence number are all written down.
- [ ] Tests run against a mock transport only, gated by an environment variable that refuses a real
      open outright.
- [ ] A version-history table exists, and capability-dependent behaviour is read from a bitmap, not
      inferred from the version number.
