# Starter error-code table — fatal vs. informational

Copy this table into your own `protocol-spec.md`, keep the two right-hand columns, and extend it as
you add message types. **The point of the two right-hand columns is that they must be cross-checked
against the actual code, not just filled in and forgotten** — see SKILL.md §4 for the incident this
table exists to prevent.

| Code | Name | Meaning | Classification | What the caller must do |
|---|---|---|---|---|
| `0x01` | `E_BAD_CRC` | CRC32 mismatch | Fatal | Frame was corrupted in transit; the sender should decide whether to retry (new SEQ or same, per your §6 policy) |
| `0x02` | `E_BAD_VERSION` | Unsupported protocol version | Fatal | Version mismatch — not recoverable by retrying the same frame |
| `0x03` | `E_UNKNOWN_TYPE` | Unrecognised message type | Fatal | Receiver doesn't implement this type; link stays open, this request failed |
| `0x04` | `E_BAD_LENGTH` | Length out of range, or wrong for this type | Fatal | Malformed request; fix the caller, don't retry unchanged |
| `0x05` | `E_BAD_PARAM` | A field is out of its legal range | Fatal | Detail field should carry the offending field's offset |
| `0x06` | `E_OUT_OF_RANGE` | Geometry/size entirely outside what the device can do | Fatal | Caller's request doesn't fit this device — not a transient condition |
| `0x07` | `E_BUSY` | Receiver is mid-transaction or otherwise occupied | Fatal (but retryable) | Caller may retry after a short backoff — this is not the same as a wire-level "gap," it's a real "not now" |
| `0x08` | `E_NO_MEM` | Allocation failed | Fatal (but retryable) | Caller may retry smaller, or after freeing something on the device side |
| `0x09` | `E_SEQ_GAP` | **Informational.** Receiver noticed missed sequence numbers from this peer, but is processing this frame normally anyway | **Informational — NOT this request's reply** | Transport layer logs/counts it and **keeps waiting** for the real ACK/typed reply that follows — see SKILL.md §4. Never surface this to application code as if it were the answer. |
| `0x0A` | `E_STATE` | Command illegal in the receiver's current state | Fatal | e.g. a mid-stream chunk with no transaction open — caller's sequencing assumption was wrong |
| `0x0B` | `E_FRAME_CRC` | A reassembled multi-chunk payload's own end-to-end CRC didn't match | Fatal | Distinct from the per-frame wire CRC (`E_BAD_CRC`) — this is a higher-level integrity check on reassembled data |
| `0x0C` | `E_INCOMPLETE` | A multi-chunk transfer had holes when finalized | Fatal | Caller must re-send the whole logical message, not just the missing chunks, unless you've built chunk-level retransmission |
| `0x0D` | `E_UNSUPPORTED` | The requested capability isn't present on this build | Fatal | Caller should have checked the capability bitmap first (SKILL.md §8) before sending this |
| `0x0E` | `E_NOT_FOUND` | Referenced resource doesn't exist | Fatal | — |
| `0x0F` | `E_NOT_PERMITTED` | Refused on safety/policy grounds | Fatal | Not a bug to retry around — the device is correctly refusing |
| `0x10` | `E_TIMEOUT` | The receiver's own internal operation timed out | Fatal | Distinct from the *caller's* request timeout (SKILL.md §6) — this is the device reporting its own internal timeout as the reason for the failure |
| `0x11` | `E_INTERNAL` | Unclassified device-side failure | Fatal | Should always be accompanied by an out-of-band log line on the device side; a caller seeing many of these has found a real device bug |

## How to use this table when you add a new error code

1. Pick fatal or informational **before** you assign the numeric code, not after.
2. If informational: write down, right there in the table row, exactly what "processes the frame
   normally" means for this specific condition, and confirm the transport layer's response-matching
   logic special-cases this code by name (SKILL.md §4's "keep waiting" behaviour doesn't happen for
   free — it has to be coded per informational code).
3. If fatal but retryable (busy, out of memory): say so in the table, and say what a caller should
   change before retrying (wait, send less data, free something) — "retryable" without guidance is
   just "fatal" with extra steps.
4. Add a unit test that scripts a fake transport into returning this exact code and asserts the
   caller does the documented thing — a table entry that's never exercised by a test is a claim, not
   a guarantee.
5. If this is the *only* informational code you have, resist the urge to build a generic "codes
   above 0x80 are informational" numbering convention instead of an explicit per-code check — a
   convention like that silently reclassifies every future code unless someone remembers the rule
   when picking the next number. An explicit table (or an explicit set literal in code:
   `INFORMATIONAL_CODES = {E_SEQ_GAP}`) doesn't have that failure mode.
