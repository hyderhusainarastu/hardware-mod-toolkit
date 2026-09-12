# Tool invocations, per pass

Generic, vendor-neutral command lines for each pass in `SKILL.md`, with what each output field
means. Written against the common Unix toolchain (`file`, `strings`, `grep`, `xxd`, `shasum`,
`tar`, `cmp`, `python3`) plus `esptool.py` where the target is an ESP-IDF-family SoC — substitute
your target's own image-info tool where the platform differs (a Nordic/Zephyr build, an STM32
bootloader, a Pico SDK `.uf2`, …). Every command below runs on **host files only** — none opens a
serial port, and none takes a device-path argument. That is deliberate: this whole skill is the
zero-hardware-touch half of reverse engineering.

## Provenance

```
shasum -a 256 <archive>
tar -tvf <archive>                       # member list, sizes, mtimes, uid/gid, permissions
cmp <archive-copy-A> <archive-copy-B>    # byte-identical? (confirms two sources agree)
```

`tar -tvf`'s uid/gid/uname/gname columns are informational packaging-environment fingerprints —
useful for noticing "this member was produced by a different tool/build step than that one," never
load-bearing for a security or acceptance claim.

## File type, size, header, segment map

```
file <image.bin>
ls -la <image.bin>
python3 -m esptool image_info --version 2 <image.bin>      # ESP-IDF app image; local file only
```

Fields that matter out of an ESP-IDF-style `image_info`: entry point, segment count, per-segment
load address/length/file-offset/memory-region, header flash size/freq/mode, min/max chip revision,
WP pin, footer XOR checksum (valid/invalid), appended SHA-256 (valid/invalid), `secure_version`.

Cross-check with an independent raw parse — the header layout is short enough to hand-roll:

```python
import struct
with open("image.bin", "rb") as f:
    data = f.read()
magic, num_segments, flash_mode, flash_size_freq = struct.unpack_from("<BBBB", data, 0)
entry_point = struct.unpack_from("<I", data, 4)[0]
# magic must be 0xE9 for an ESP-IDF app image; walk `num_segments` {load_addr, length, data}
# records starting at offset 24 to get the segment map independently of esptool.
```

When the tool's output and your own parse agree on every field, both are trustworthy. When they
disagree, stop and reconcile before citing either.

## Signed / encrypted / anti-rollback

```
xxd -s $(( <appended_hash_end_offset> )) -l 64 <image.bin>   # anything after the hash?
python3 -c "print(len(open('<image.bin>','rb').read()))"     # total file length
strings -n 4 <image.bin> | grep -c '^[[:print:]]\{4,\}$'      # rough plaintext-density sanity check
```

Compute the expected end-of-content offset by hand (segment table end + footer checksum byte +
appended-hash length) and compare it to the file's actual length. Equal ⇒ no trailing signature
block. A file with thousands of readable ASCII lines from `strings` is plaintext; an encrypted
image returns almost nothing from the same command over the same byte range.

## Strings and log-format mining

```
strings -n 4 -t x <image.bin> | less                 # -t x: prefix each hit with its file offset
strings -n 8 <image.bin> | grep -E '\(%l?u\) %s:'    # ESP_LOG-shaped format strings -> tags
strings -n 4 <image.bin> | grep -inE '<keyword>'     # targeted, case-insensitive first pass
strings -n 4 <image.bin> | grep -E '<keyword>'       # then case-sensitive, to get a clean count
```

`-t x` is the single highest-value flag here — every hit comes back with the offset you need for
citation, for free, instead of a second `grep -b` pass.

## Release-to-release diffing

```
strings -n 8 old.bin | sort -u > /tmp/old.strings
strings -n 8 new.bin | sort -u > /tmp/new.strings
comm -13 /tmp/old.strings /tmp/new.strings     # lines only in new  (added)
comm -23 /tmp/old.strings /tmp/new.strings     # lines only in old  (removed)
```

## Partition-table byte scan (no offsets known)

```
python3 - << 'PY'
data = open("full_flash_or_table.bin", "rb").read()
magic = b"\xaa\x50"      # ESP-IDF partition-table entry magic; substitute your platform's
i = data.find(magic)
while i != -1:
    print(hex(i))
    i = data.find(magic, i + 1)
PY
```

Every hit must then be decoded as a full entry (type/subtype/offset/size/label/flags) and checked
for a plausible, MD5-terminated table — a bare magic-byte match with no valid entry structure
around it is a false positive, not a partition table.

## Subsystem cross-reference (mutually exclusive presence/absence)

```
grep -icE '<subsystem-A-keyword-set>' image_1.bin      # expect a large count
grep -icE '<subsystem-A-keyword-set>' image_2.bin      # expect 0
grep -c    '<subsystem-B-keyword-set>' image_1.bin     # case-sensitive re-check, expect 0
```

Run the case-insensitive sweep first for a quick answer, then re-run case-sensitively before citing
a "0 hits" result as CONFIRMED — a case-insensitive match can pull in an unrelated hit from a
same-named symbol in a different stack.

## Exhaustive call-site count

Without a real disassembler, the closest host-only approximation for a relocatable call target is
counting how many times its resolved address (found once via the string→literal→load-instruction
chain in `SKILL.md` §5) appears as an immediate operand elsewhere in the code segment:

```
xxd <image.bin> | grep -c '<little-endian target address, as hex byte pairs>'
```

Treat this as a lower bound (some encodings won't byte-match textually) and confirm anything
decision-relevant with an actual disassembler pass at each candidate site.

## Container / updater format identification

```
tar -tvf <container>                          # member names, sizes, typeflags if your tar shows them
python3 -c "
import tarfile
t = tarfile.open('<container>')
for m in t.getmembers():
    print(m.name, m.size, m.type, m.mode)
"
```

If the firmware's own tar-handling code looks unusually small (tens of instructions, not hundreds),
suspect a header-only micro-library rather than a full-featured tar implementation, and go looking
for its upstream source — knowing the exact library tells you every constraint (accepted typeflags,
checksum algorithm, whether `prefix`/long-name/pax extensions are supported) without having to
rediscover each one by trial and error.

## Provenance appendix boilerplate

Every analysis document's appendix should state, verbatim or near it:

> All commands were run on host files only. No command took a device/port argument, opened a
> serial device, or contacted the `<DEVICE>`.
