# Frame worked example, and a test-vector file format

This shows one complete frame encoded byte-for-byte against the layout in `SKILL.md` §1, using the
worked example's own field values — swap in `<DEVICE>`'s real magic/type codes and this becomes your
own worked example. Keep a version of this table in your own `protocol-spec.md`; it is the fastest
way for a new implementer to sanity-check their encoder against yours without running any code.

## Frame layout recap

```
+--------+--------+--------+--------+--------+-----------------+-----------------+
| MAGIC0 | MAGIC1 |VERSION |  TYPE  | FLAGS  |     SEQ (LE)    |     LEN (LE)    |
+--------+--------+--------+--------+--------+-----------------+-----------------+
|                          PAYLOAD  (LEN bytes)                                  |
+---------------------------------------------------------------------------------+
|                          CRC32 (LE, u32) over HEADER || PAYLOAD                 |
+---------------------------------------------------------------------------------+
```

Header is 9 bytes (magic·2 + version·1 + type·1 + flags·1 + seq·2 + len·2). A frame is
`9 + LEN + 4` bytes on the wire.

## Worked example: a "draw text" command

Request: draw the string `"DEMO"` at pixel `(4, 8)` using font `1`, no style bits, requesting an
ACK, on sequence `5`.

```
Field      Bytes                    Meaning
---------  -----------------------  ----------------------------------------
MAGIC      4D 44                    'M','D'
VERSION    01                       v1
TYPE       11                       DRAW_TEXT (example type code 0x11)
FLAGS      01                       ACK_REQ bit set
SEQ        05 00                    5  (u16 LE)
LEN        0C 00                    12 (u16 LE) — this message's payload length
  x        04 00                    4
  y        08 00                    8
  font_id  01                       font 1
  style    00                       no style bits
  text_len 04 00                    4 bytes of text follow
  text     44 45 4D 4F              "DEMO"
CRC32      B4 74 41 21              0x214174B4 (u32 LE)
```

Complete frame, 25 bytes:

```
4D 44 01 11 01 05 00 0C 00 04 00 08 00 01 00 04 00 44 45 4D 4F B4 74 41 21
```

The CRC input is the 9 header bytes `4D 44 01 11 01 05 00 0C 00` followed by the 12 payload bytes —
21 bytes total:

```python
import zlib
crc = zlib.crc32(bytes.fromhex("4D4401110105000C000400080001000400") + b"DEMO") & 0xFFFFFFFF
assert crc == 0x214174B4
```

The device's reply — an `ACK`, echoing sequence 5:

```
4D 44 01 09 02 05 00 00 00 <crc32>
             ^  ^  ^
             |  |  +-- SEQ 5, echoed from the request (a reply does not
             |  |       consume a new sequence number of its own — see
             |  |       SKILL.md §3)
             |  +----- FLAGS = IS_REPLY (0x02)
             +-------- TYPE = ACK (example type code 0x09)
```

## Reference generator

Build a small encoder like this in the host language you'll generate test vectors from — this one
is Python, matching the CRC definition above:

```python
import zlib, struct

MAGIC, VERSION = b"BK", 1

def build_frame(msg_type, flags, seq, payload=b""):
    header = MAGIC + bytes([VERSION, msg_type, flags]) + struct.pack("<HH", seq, len(payload))
    body = header + payload
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return body + struct.pack("<I", crc)
```

## Test-vector file format

Generate a shared JSON file — from whichever implementation you trust most (a from-scratch C
reference implementation cross-checked against the spec by hand is a reasonable choice) — and load
it from every other implementation's test suite. One entry per vector:

```json
[
  {
    "name": "PING",
    "type": 7,
    "flags": 0,
    "seq": 1,
    "payload_hex": "",
    "crc32": 1741512832,
    "frame_hex": "4d44010700010000008060cd67"
  },
  {
    "name": "DRAW_TEXT",
    "type": 17,
    "flags": 1,
    "seq": 5,
    "payload_hex": "040008000100040044454d4f",
    "crc32": 557937844,
    "frame_hex": "4d4401110105000c00040008000100040044454d4fb4744121"
  }
]
```

Fields: `name` (human label), `type`/`flags`/`seq` (header fields used to build it), `payload_hex`
(the payload, hex-encoded, empty string for a zero-length payload), `crc32` (decimal, for an
assertion that doesn't require the reader to parse hex), `frame_hex` (the complete wire frame,
hex-encoded, for a single round-trip assertion).

Every implementation's test suite should do two things against this file:

1. **Encode** `(type, flags, seq, payload)` and assert the result equals `frame_hex`.
2. **Decode** `frame_hex` through the incremental byte-stream parser (fed one byte at a time, to
   also exercise the state machine) and assert the fields and CRC match.

A protocol is not "implemented on both sides" until this file makes both sides prove it — a design
document that both implementations merely *read* is not the same claim as a test that both
implementations *pass*.
