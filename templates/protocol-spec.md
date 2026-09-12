<!--
HOW TO USE THIS TEMPLATE
1. This is the skeleton for a custom framed link protocol between a host and a device you
   control the firmware of (companion-app <-> custom firmware, not a vendor protocol you're
   reverse-engineering — document THAT under recon-findings.md/hardware.md instead).
2. Fill sections in the order they're numbered — later sections assume earlier ones are
   settled (payload layouts assume the frame format and flags exist; semantics assume the
   message types exist).
3. §11 (worked example) and §12 (test vectors) are not optional decoration: write a program
   that generates the CRC/checksum values in your own spec and check them in as a small
   script, then paste its output here. A protocol spec whose own worked example doesn't
   checksum-verify is worse than no worked example.
4. §13 (version history) starts on day one with a "1 | <date> | Initial specification." row.
   State the compatibility rule (what kind of change bumps the version number vs. what's
   additive) BEFORE you make the first additive change, not after, or every future change is
   a judgment call made under time pressure.
5. Keep "what this protocol deliberately cannot do" (§1) as an explicit allow-list, not an
   afterthought — for a device you don't want to be able to brick over this link, naming the
   operations it CANNOT perform (raw memory access, arbitrary flash write, code execution) is
   itself a safety property worth stating up front.
-->

# <PROJECT> link protocol — v1

**Status:** <SPECIFIED (not yet implemented) / IMPLEMENTED, host-tested / IMPLEMENTED, on-device
verified> · <DATE>

This is the protocol spoken between the host companion app and this project's own firmware on
<DEVICE>. It is not the vendor's protocol (if the device has one, document it separately as
observed evidence, not as a spec you own).

## 1. Scope, and what this protocol deliberately cannot do

**It can:** <list the actual capabilities — draw/render, read status, control power/backlight,
report input events, reboot, switch back to a known-good firmware image>.

**It cannot, by design and by omission — there is no message type for any of it:**

- **No memory read. No memory write.** No message takes an address.
- **No flash read, no flash write, no partition write, no persistent-storage passthrough.**
  <name the one exception if you have one, e.g. "a message that asks the bootloader to boot a
  different pre-existing, firmware-selected slot" — and say explicitly that the host cannot
  name an arbitrary offset or partition.>
- **No raw register access, no bus passthrough (I2C/SPI/etc.), no GPIO poke.**
- **No code execution, no file upload, no filesystem access.**

<State the practical consequence: "a host that is compromised, confused, or hostile can do X and
Y, but cannot reach Z" — and state the rule for extending this boundary later, e.g. "any future
message type that would widen this must get its own decision record before implementation.">

## 2. Transport

| | |
|---|---|
| Primary | <e.g. USB CDC-ACM; host device node pattern> |
| Later/optional | <e.g. TCP over Wi-Fi, port N, identical framing> |
| Never | <name any interface that must NOT carry protocol bytes, e.g. a debug/log console — and why> |

<State whether framing is transport-agnostic and self-synchronizing (recommended): it should
assume an ordered byte stream that may be truncated at any point, may begin mid-frame (host
attaches to an already-running device), and preserves no message boundaries of its own.>

## 3. Frame format

```
+--------+--------+--------+--------+--------+--------+--------+--------+--------+
| MAGIC0 | MAGIC1 |VERSION |  TYPE  | FLAGS  |     SEQ (LE)    |     LEN (LE)    |
+--------+--------+--------+--------+--------+--------+--------+--------+--------+
|                     PAYLOAD  (LEN bytes, 0 <= LEN <= <MAX_LEN>)               |
+--------------------------------------------------------------------------------+
|                     CHECKSUM (LE, over HEADER || PAYLOAD)                      |
+--------------------------------------------------------------------------------+
```

| Field | Offset | Size | Notes |
|---|---|---|---|
| `MAGIC` | 0 | 2 | Constant 2-byte anchor. The resync anchor (§7.7). |
| `VERSION` | 2 | 1 | Protocol version. A receiver seeing an unknown value replies with the bad-version error and discards the frame. |
| `TYPE` | 3 | 1 | Message type, §5. |
| `FLAGS` | 4 | 1 | Bitmap, §4. Reserved bits **must** be sent 0 and **must** be ignored on receipt. |
| `SEQ` | 5 | 2 | Little-endian u16, wraps. Sender-scoped: host and device keep independent counters. |
| `LEN` | 7 | 2 | Little-endian u16, payload length. Hard maximum <MAX_LEN>; a frame declaring more is a protocol violation. |
| `PAYLOAD` | 9 | `LEN` | Type-specific, §6. State your byte order and coordinate-origin convention once, here, for the whole spec. |
| `CHECKSUM` | 9+`LEN` | <SIZE> | Defined exactly in §3.1. |

Header is **9 bytes**; state the resulting min/max total frame size.

### 3.1 Checksum — exact definition

<Name the exact algorithm (e.g. CRC32 IEEE 802.3/zlib: reflected poly 0xEDB88320, init
0xFFFFFFFF, final XOR 0xFFFFFFFF) and state precisely what range of bytes it covers (typically
header + payload, checksum field itself excluded). State the one-line equivalent in a common
language (e.g. Python's `zlib.crc32`) so an implementer can verify their own code against it —
this is also exactly what generates §12's test vectors.>

## 4. FLAGS

| Bit | Mask | Name | Meaning |
|---|---|---|---|
| 0 | `0x01` | `ACK_REQ` | Sender wants an explicit reply for this `SEQ`. |
| 1 | `0x02` | `IS_REPLY` | This frame answers an earlier frame; its `SEQ` echoes the request's `SEQ`. |
| 2 | `0x04` | `MORE` | Non-final fragment of a logical multi-frame message. |
| 3 | `0x08` | <e.g. `RLE`> | <payload is compressed — restrict which message types may set it> |
| 4 | `0x10` | `EVENT` | Unsolicited device-to-host notification. Never acknowledged, never retried. |
| 5–7 | `0xE0` | reserved | Send 0; ignore on receipt. Never reject a frame for a set reserved bit — that is what keeps a v1 receiver compatible with a later v1.x sender. |

## 5. Message types

Direction: **H→D** host to device, **D→H** device to host.

| Type | Name | Dir | Payload | Reply |
|---|---|---|---|---|
| `0x01` | `HELLO` | H→D | <version/capability negotiation fields> | `HELLO_ACK` |
| `0x07` | `PING` | H→D | none | `PONG` |
| `0x09` | `ACK` | D→H | none | — |
| `0x0?` | `NACK` | D→H | `code`, `detail` | — |
| `0x10` | `CLEAR` | H→D | <e.g. fill value> | ack |
| `0x11` | <e.g. `DRAW_TEXT`> | H→D | see §6.2 | ack |
| `0x2?` | <device-control messages> | H→D | see §6.4 | ack |
| `0x3?` | <device→host events> | D→H | see §6.5 | none (events) |

<Add rows for your actual message set. Keep type numbers grouped by category (session/control/
drawing/streaming/events) the way this skeleton groups them — it makes the eventual capability
bitmap in §6.6 easier to reason about.>

## 6. Payload layouts

### 6.1 Session (HELLO / HELLO_ACK / capability negotiation)
<field table: name, size, meaning>

### 6.2 <drawing / primary function> commands
<field table per message type>

### 6.3 <streaming / bulk-transfer path, if any>
<begin/data/end message trio, chunk size limits, reassembly rule>

### 6.4 Device control
<mode switches, power, brightness, reboot, "return to known-good firmware" if applicable>

### 6.5 Device→host events
<status, input/button events, log events — and their rate limits, see §8>

### 6.6 Capability bitmap
<a bitmap the device reports in HELLO_ACK so the host can detect optional features (compression,
extra bit depths, etc.) without a version bump>

## 7. Semantics

### 7.1 Buffering and refresh (or equivalent commit semantics)
<When does an action actually take visible/physical effect vs. just update internal state?
State the rule once, explicitly — this is exactly the kind of thing an incident report gets
written about if it's left implicit.>

### 7.2 Payload packing (if applicable — e.g. pixel packing)
<bit order, byte order, row/stride padding rule, stated once and referenced everywhere else>

### 7.3 Optional compression (if any)
<exact scheme; state that the uncompressed path must always work and compression is strictly an
optimization a receiver may refuse if it lacks the capability bit>

### 7.4 Acknowledgement
- <which flag requests an ack, what counts as satisfying it (a typed response counts)>
- <which message types are ALWAYS acknowledged regardless of the flag, and why — usually state
  transitions the sender must know took effect>
- <which message types are normally unacknowledged, and why — usually a streaming/bulk path>
- <events are never acknowledged>

### 7.5 Sequence numbers
- <independent per-direction counters, wrap behavior>
- <duplicate-detection window and what "idempotent" vs. "not idempotent" (e.g. chunk resend)
  message types do differently on a duplicate SEQ>
- <gap detection: is a gap an error, or just reported? State this explicitly — a gap-as-error
  design forces retransmission machinery you may not want in v1; a gap-as-report design (report
  it, then process the frame normally) is simpler and was cheaper in the source project's own
  experience>
- **If a gap/informational reply shares the request's own SEQ with the real reply**, state
  explicitly that a receiver must not treat the informational reply as satisfying the request —
  it must keep waiting, within the same timeout budget, for the real reply. (A real incident in
  the source project's own history was exactly this: a host that returned on the first
  SEQ-matching reply silently swallowed the real answer behind an informational gap notice.)

### 7.6 Timeouts
| Party | Situation | Timeout | Action |
|---|---|---|---|
| Host | awaiting an acked reply | <value> | <retry policy> |
| Host | awaiting the initial handshake reply | <value> | <retry policy, then give up and report> |
| Host | link idle | <value> | <keepalive ping policy> |
| Device | multi-frame transfer open, no continuation | <value> | <abort, free buffer, log> |
| Device | no host traffic at all | <value> | <fall back to the device's own local behavior> |
| Device | mid-frame byte-level stall | <value> | <discard partial frame, resync — no error reply; the sender may simply be gone> |

### 7.7 Resync
State the receiver as an explicit state machine that never trusts the stream:
1. **HUNT** — read until the magic bytes are seen; discard everything before.
2. **HEADER** — read the rest of the header; validate version and length; on failure, back to HUNT.
3. **PAYLOAD** — read `LEN` bytes plus the checksum, subject to the stall timeout.
4. **VERIFY** — checksum mismatch → error reply, back to HUNT; match → dispatch.
5. Return to HUNT after any dispatch or rejection.

State explicitly why the magic bytes appearing inside a payload is not a problem (HUNT is only
entered outside a frame; a frame's extent is fixed by LEN; a false-positive magic can only be
latched after corruption, and the checksum then rejects it).

## 8. Size limits

| Limit | Value | Why |
|---|---|---|
| Max payload | <value> | <memory/allocation rationale> |
| Max frame on the wire | <value> | header + max payload + checksum |
| Min frame | <value> | header + 0 payload + checksum |
| Max declared bulk-transfer size | <value> | <hard stop against a hostile/malformed allocation request> |
| Max concurrent multi-frame transactions | <usually 1> | |
| Event rate caps | <per event type> | |

## 9. Error codes

| Code | Name | Meaning |
|---|---|---|
| `0x01` | `E_BAD_CHECKSUM` | checksum mismatch |
| `0x02` | `E_BAD_VERSION` | unsupported VERSION |
| `0x03` | `E_UNKNOWN_TYPE` | unrecognised TYPE |
| `0x04` | `E_BAD_LENGTH` | LEN out of range or wrong for this type |
| `0x05` | `E_BAD_PARAM` | a field is out of its legal range |
| `0x06` | `E_OUT_OF_RANGE` | geometry/size beyond what the device supports |
| `0x07` | `E_BUSY` | a conflicting operation is already in progress |
| `0x08` | `E_NO_MEM` | allocation failed |
| `0x09` | `E_SEQ_GAP` | informational — see §7.5's note on not treating this as the reply |
| `0x0A` | `E_STATE` | command illegal in the current state |
| `0x0D` | `E_UNSUPPORTED` | capability not present |
| `0x0F` | `E_NOT_PERMITTED` | refused on safety grounds |
| `0x10` | `E_TIMEOUT` | peer's own transaction timed out |
| `0x11` | `E_INTERNAL` | device-side failure with no better code |

## 10. Persistence

<If the firmware stores any of its own state (settings, last mode) across reboots: name the
exact storage namespace it uses, and state explicitly that it is isolated from — and never reads
or writes — any vendor storage namespace that might hold credentials/pairing data/calibration.
State whether persistence is gated behind a build flag, and what the default is. If persistence
writes to the same physical partition a vendor uses for something irreplaceable, say so and
name the isolation mechanism (e.g. namespacing) precisely — this is a place where an implicit
assumption becomes a real incident.>

## 11. Worked example — one frame, byte for byte

<Pick your single most illustrative message type. Show the exact byte layout, field by field,
then the complete frame as a hex dump, then the checksum computed with a one-line reference
snippet the reader can run themselves. Show the corresponding reply frame too.>

```
Field      Bytes                    Meaning
---------  -----------------------  ----------------------------------------
MAGIC      <hex>                    magic bytes
VERSION    <hex>                    v1
TYPE       <hex>                    <message name>
FLAGS      <hex>                    <flags set>
SEQ        <hex>                    <N>  (u16 LE)
LEN        <hex>                    <N>  (u16 LE)
  <field>  <hex>                    <meaning>
  ...
CHECKSUM   <hex>                    <value>  (LE)
```

## 12. Test vectors

<Generate these with a short reference script and check the script into your repo (e.g.
scripts/gen-test-vectors.py) — the values below must be reproducible by anyone, not hand-typed.>

| # | Message | TYPE | FLAGS | SEQ | LEN | Payload (hex) | Checksum | Full frame (hex) |
|---|---|---|---|---|---|---|---|---|
| 1 | <e.g. PING> | | | | 0 | *(none)* | | |
| 2 | <e.g. HELLO> | | | | | | | |
| 3 | <your primary message type> | | | | | | | |

Reference generator (host-only, no device contact):

```python
import zlib, struct
MAGIC, VER = b'<MAGIC>', 1
def build(msg_type, flags, seq, payload=b''):
    hdr = MAGIC + bytes([VER, msg_type, flags]) + struct.pack('<HH', seq, len(payload))
    body = hdr + payload
    return body + struct.pack('<I', zlib.crc32(body) & 0xFFFFFFFF)
```

## 13. Version history

| Version | Date | Change |
|---|---|---|
| 1 | <DATE> | Initial specification. |

**Compatibility rule.** State it explicitly, before the first additive change is made: e.g.
"`VERSION` increments only on a breaking frame-layout change; new message types, new capability
bits, and new legal values for an existing field are additive within a major version — a
receiver must reject an unknown type/value gracefully (a typed error, not a dropped link) and
ignore reserved bits, rather than assuming compatibility it hasn't verified."
