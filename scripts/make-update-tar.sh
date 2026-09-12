#!/usr/bin/env bash
#
# make-update-tar.sh — build a stock-format update package for a device
#                       that installs whatever archive it finds at a fixed
#                       path, from a vendor stock release you supply.
#
# WHAT THIS IS FOR
#   Many devices ship an updater that installs *any* archive satisfying its
#   acceptance rules (see the `stock-updater-packaging` skill for how to
#   derive those rules) — it does not know or care whether the bytes came
#   from the vendor. This script builds that archive on the host, from
#   either your own custom image plus stock companion members, or purely
#   from a stock release (for a REHEARSAL — proving the packaging pipeline
#   is byte-correct before it is ever trusted with a non-stock image).
#
#   This script is 100% host-only. It never touches a serial device, never
#   runs a flashing tool against a --port, never writes to removable media,
#   and never asks you to plug anything in. It only reads local files and
#   writes files under the directory passed to --out.
#
#   It ships ZERO vendor bytes: --stock-from is a REQUIRED flag pointing at
#   a stock release archive YOU already obtained separately. There is no
#   default path this script guesses at, and no bundled copy anywhere in
#   this toolkit. If you don't have one yet, get it from the vendor before
#   running this script for real — see docs/PITFALLS.md.
#
# BEFORE YOU EDIT ANYTHING: fill in PRIMARY_MEMBER_NAME below
#   This script needs to know the EXACT, case-sensitive member name your
#   device's updater looks up for the image you're building (see the
#   `stock-updater-packaging` skill's Q2/Q4). Set it once, near the top of
#   this file, for your project:
#
#     readonly PRIMARY_MEMBER_NAME="<PRIMARY_MEMBER_NAME>"
#
#   e.g. readonly PRIMARY_MEMBER_NAME="firmware.bin" — the script refuses
#   to run with the un-edited placeholder still in place.
#
# USAGE
#   make-update-tar.sh --image <your-build.bin> --stock-from <stock.tar> --out <dir>
#   make-update-tar.sh --rehearse --stock-from <stock.tar> --out <dir>
#       Re-packs the stock release's own members through the exact same
#       staging/tar/verify pipeline and asserts the result is
#       member-identical (same bytes, per member) to the stock archive.
#       If this doesn't come out identical, the pipeline itself is not
#       trustworthy for anything else — fix it before building anything
#       real with it. See the `stock-updater-packaging` skill §4.
#
# OPTIONS
#   --image PATH          Your build for the PRIMARY_MEMBER_NAME member
#                          (edit that constant above first). Required
#                          unless --rehearse.
#   --member NAME=PATH     Provide/override one additional member by its
#                          exact archive name. Repeatable. Any member not
#                          covered by --image or --member defaults to the
#                          stock archive's own content for that name.
#   --omit NAME             Remove a member from the output entirely
#                          (a member the updater treats as optional — see
#                          the `stock-updater-packaging` skill §3 on
#                          staging a first install without the one
#                          unrecoverable member). Repeatable.
#   --i-know-this-is-not-stock
#                          Required alongside a --member (or --image, if
#                          PRIMARY_MEMBER_NAME is itself unrecoverable)
#                          whose content differs from the stock archive's
#                          own copy of a name listed in UNRECOVERABLE_MEMBERS
#                          below. Without it, packaging a non-stock
#                          replacement for one of those names is a hard
#                          error, not a warning. Omitting such a member
#                          with --omit needs no acknowledgement — that is
#                          always the safer direction.
#   --stock-from PATH      REQUIRED. A vendor release archive to source
#                          default member content from and to compare
#                          against. Verified against a sibling SHA256SUMS
#                          file next to it unless --skip-stock-verify is
#                          given.
#   --skip-stock-verify     Skip verifying --stock-from against a sibling
#                          SHA256SUMS entry (needed for a deliberately
#                          unlisted archive, e.g. a not-yet-released build).
#   --rehearse             Ignore --image/--member/--omit; instead repack
#                          --stock-from's own members, unchanged, through
#                          this pipeline and assert the result is
#                          member-identical to the source. See USAGE above.
#   --out DIR              Output directory. Required. Created if missing.
#                          Written: DIR/<archive-name> (same basename as
#                          --stock-from — see OUTPUT ARCHIVE FORMAT),
#                          DIR/SHA256SUMS, DIR/MEMBER-SHA256SUMS,
#                          DIR/MANIFEST.txt.
#   --stamp STRING         Timestamp string to record in MANIFEST.txt.
#                          Default: `date` at run time.
#   -h, --help              Show this help and exit.
#
# OUTPUT ARCHIVE FORMAT
#   The output archive is named identically to --stock-from's own
#   basename (the updater generally expects one specific filename — reuse
#   the stock one rather than guessing at a rename) and is written with
#   `tar --format ustar`, bare member names, no "./" prefix, no PAX/GNU
#   extended headers. Verified three ways: `tar -tvf`, the python3
#   `tarfile` module, and a raw per-header byte walk checking the POSIX
#   `ustar\0` / `00` magic+version fields directly — a real installer's
#   embedded tar parser is usually much stricter than `tarfile`, so belt
#   and suspenders here has caught real mistakes.
#   Member ORDER defaults to the stock archive's own order. If your
#   updater looks members up by NAME rather than position (confirm this
#   from its own code — see the `stock-updater-packaging` skill Q4), a
#   reordering is safe; this script does not depend on matching the
#   vendor's byte layout, only the vendor's member NAMES.
#
# VALIDATION
#   If esptool is installed, the PRIMARY_MEMBER_NAME member is checked
#   with `python3 -m esptool image_info --version 2` (a local, read-only
#   static parse — no --port, no device contact). This is Espressif/
#   ESP-IDF specific; if esptool is not installed, or the file is not
#   recognized as an ESP-IDF app image, this step is SKIPPED with a
#   warning rather than failing — adapt validate_primary_image() below to
#   your own toolchain's equivalent local, offline image checker.
#   Every other member gets only a non-empty-file check, plus (for a
#   member that is itself a tar, like a Lua/asset bundle) a readable-tar
#   check. This is not a validator of any member's *content* — it exists
#   to catch a truncated or wrong-chip file, not to guarantee correctness.
#
# SAFETY
#   Read-only w.r.t. everything except the files this script itself writes
#   under --out (and a host-side scratch directory it cleans up on exit).
#   Never touches /dev/cu.*, /dev/tty.*, a flashing tool's --port, or any
#   removable media. Building the archive is NOT the same as installing it
#   on the device — that is a separate, separately-gated on-device step.
#
# REQUIRES: bash, python3, tar, shasum or sha256sum. esptool is optional
# (only used for --image's best-effort validation, see VALIDATION above).

set -euo pipefail

# =========================================================================
# EDIT THESE TWO CONSTANTS FOR YOUR PROJECT before running for real
# =========================================================================

# The exact, case-sensitive archive member name your device's updater
# looks up for the image built by --image. See the stock-updater-packaging
# skill's Q2 ("path and filename") / Q4 ("member set, by name or position").
readonly PRIMARY_MEMBER_NAME="<PRIMARY_MEMBER_NAME>"

# Member names with NO software recovery path on your device if a bad
# image is installed (a companion MCU flashed over a simple protocol with
# no readback/verify, an EEPROM with no backup partition, ...). See the
# stock-updater-packaging skill's Q10. Leave empty ( () ) if none apply, or
# if you haven't answered Q10 yet — in which case treat EVERY member as
# unrecoverable until you have. Example: UNRECOVERABLE_MEMBERS=("companion.bin")
UNRECOVERABLE_MEMBERS=()

# --- helpers -------------------------------------------------------------

SCRIPT_PATH="${BASH_SOURCE[0]}"

log()  { printf '%s\n' "$*"; }
hdr()  { printf '\n== %s ==\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    awk 'NR>1 && /^# ?/{sub(/^# ?/,""); print; next} NR>1 && !/^#/{exit}' "$SCRIPT_PATH"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}
size_of() { wc -c < "$1" | tr -d ' '; }

is_unrecoverable() {
    local name="$1" u
    for u in "${UNRECOVERABLE_MEMBERS[@]:-}"; do
        [[ -n "$u" && "$u" == "$name" ]] && return 0
    done
    return 1
}

WORKDIRS=()
cleanup() {
    local d
    for d in "${WORKDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
    done
}
trap cleanup EXIT

mktempdir() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/make-update-tar.XXXXXX")"
    WORKDIRS+=("$d")
    printf '%s\n' "$d"
}

# --- argument parsing ------------------------------------------------------

IMAGE_ARG=""
STOCK_FROM=""
OUT_DIR=""
REHEARSE=0
STAMP=""
SKIP_STOCK_VERIFY=0
I_KNOW_NOT_STOCK=0
declare -a MEMBER_OVERRIDES=()   # each entry "NAME=PATH"
declare -a OMIT_NAMES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)        IMAGE_ARG="${2:?--image needs a path}"; shift 2 ;;
        --member)       MEMBER_OVERRIDES+=("${2:?--member needs NAME=PATH}"); shift 2 ;;
        --omit)         OMIT_NAMES+=("${2:?--omit needs a member NAME}"); shift 2 ;;
        --stock-from)   STOCK_FROM="${2:?--stock-from needs a path}"; shift 2 ;;
        --out)          OUT_DIR="${2:?--out needs a path}"; shift 2 ;;
        --stamp)        STAMP="${2:?--stamp needs a string}"; shift 2 ;;
        --rehearse)     REHEARSE=1; shift ;;
        --skip-stock-verify) SKIP_STOCK_VERIFY=1; shift ;;
        --i-know-this-is-not-stock) I_KNOW_NOT_STOCK=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unrecognized argument: $1 (see --help)" ;;
    esac
done

[[ "$PRIMARY_MEMBER_NAME" != "<PRIMARY_MEMBER_NAME>" ]] \
    || die "PRIMARY_MEMBER_NAME is still the un-edited placeholder <PRIMARY_MEMBER_NAME> near the top of this script — set it to your device's exact updater-required member name before running this for real (see the stock-updater-packaging skill Q2/Q4)."

[[ -n "$STOCK_FROM" ]] || die "--stock-from is required (this toolkit ships zero vendor bytes — supply your own stock release archive; see --help)"
[[ -f "$STOCK_FROM" ]] || die "--stock-from file not found: $STOCK_FROM"
[[ -n "$OUT_DIR" ]] || die "--out is required (see --help)"

if [[ "$REHEARSE" -eq 1 ]]; then
    [[ -z "$IMAGE_ARG" && "${#MEMBER_OVERRIDES[@]}" -eq 0 && "${#OMIT_NAMES[@]}" -eq 0 ]] \
        || die "--rehearse cannot be combined with --image/--member/--omit — it repacks --stock-from's own members only"
else
    [[ -n "$IMAGE_ARG" ]] || die "--image is required unless --rehearse is given (see --help)"
fi

[[ -n "$STAMP" ]] || STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- verify --stock-from itself -------------------------------------------

hdr "Stock source"
log "Using stock release archive: $STOCK_FROM"
STOCK_FROM_HASH="$(sha256_of "$STOCK_FROM")"
log "  sha256: $STOCK_FROM_HASH"

if [[ "$SKIP_STOCK_VERIFY" -eq 1 ]]; then
    log "  (--skip-stock-verify given: NOT checked against a sibling SHA256SUMS)"
else
    STOCK_FROM_DIR="$(cd "$(dirname "$STOCK_FROM")" && pwd)"
    STOCK_FROM_BASE="$(basename "$STOCK_FROM")"
    STOCK_SUMS_FILE="$STOCK_FROM_DIR/SHA256SUMS"
    if [[ -f "$STOCK_SUMS_FILE" ]]; then
        STOCK_EXPECTED_LINE="$(grep -E "  \\Q$STOCK_FROM_BASE\\E\$" "$STOCK_SUMS_FILE" || true)"
        if [[ -n "$STOCK_EXPECTED_LINE" ]]; then
            STOCK_EXPECTED_HASH="$(printf '%s\n' "$STOCK_EXPECTED_LINE" | awk '{print $1}')"
            [[ "$STOCK_EXPECTED_HASH" == "$STOCK_FROM_HASH" ]] \
                || die "--stock-from ($STOCK_FROM) sha256 ($STOCK_FROM_HASH) does not match $STOCK_SUMS_FILE ($STOCK_EXPECTED_HASH). Refusing to proceed with a possibly tampered/corrupted source. Pass --skip-stock-verify only if this mismatch is understood and deliberate."
            log "  verified against $STOCK_SUMS_FILE: OK"
        else
            log "  (no entry for $STOCK_FROM_BASE in $STOCK_SUMS_FILE — nothing to verify against; pass --skip-stock-verify to silence this note)"
        fi
    else
        log "  (no sibling SHA256SUMS next to --stock-from — nothing to verify against; pass --skip-stock-verify to silence this note)"
    fi
fi

STOCK_LISTING_RAW="$(tar -tf "$STOCK_FROM")"
declare -a STOCK_MEMBERS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && STOCK_MEMBERS+=("$line")
done <<< "$STOCK_LISTING_RAW"
[[ "${#STOCK_MEMBERS[@]}" -gt 0 ]] || die "--stock-from ($STOCK_FROM) is empty or not a readable tar archive"

STOCK_DIR="$(mktempdir)"
tar -x -f "$STOCK_FROM" -C "$STOCK_DIR" "${STOCK_MEMBERS[@]}"

# --- best-effort image validation (ESP-IDF/esptool specific) --------------
#
# Adapt this function to your own toolchain's local, offline image checker
# if you are not building for an ESP-IDF target. It must never contact a
# device — a static parse of the file only.
validate_primary_image() {
    local img="$1"
    [[ -f "$img" ]] || die "primary image not found: $img"
    local sz; sz="$(size_of "$img")"
    [[ "$sz" -gt 0 ]] || die "primary image $img is empty — refusing to package it"

    if ! command -v python3 >/dev/null 2>&1 || ! python3 -m esptool version >/dev/null 2>&1; then
        log "  (esptool not available — skipping ESP-IDF image_info check; only checked non-empty, $sz bytes)"
        return 0
    fi
    local info rc=0
    info="$(python3 -m esptool image_info --version 2 "$img" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        log "  (esptool image_info did not recognize $img as an ESP-IDF app image — skipping this check: $info)"
        return 0
    fi
    printf '%s\n' "$info" | grep -qE 'Checksum:.*\(valid\)' \
        || die "primary image $img failed esptool's checksum check. esptool said:
$info"
    printf '%s\n' "$info" | grep -qE 'Validation hash:.*\(valid\)' \
        || die "primary image $img failed esptool's validation-hash check. esptool said:
$info"
    printf '%s\n' "$info"
}

# --- minimal structural validation for a non-primary member ----------------
validate_generic_member() {
    local path="$1"
    [[ -f "$path" ]] || die "member source not found: $path"
    local sz; sz="$(size_of "$path")"
    [[ "$sz" -gt 0 ]] || die "member $path is empty — refusing to package it"
    if tar -tf "$path" >/dev/null 2>&1; then
        local listing; listing="$(tar -tf "$path" 2>&1)"
        [[ -n "$listing" ]] || die "member $path is a tar archive with no members — refusing to package it"
    fi
}

# --- resolve final member list and each one's source ------------------------
#
# NOTE ON PORTABILITY: this uses parallel INDEXED arrays (M_NAME/M_SRC/
# M_DESC/M_CUSTOM), not bash 4's associative arrays (`declare -A`) —
# macOS ships bash 3.2 by default, which does not have them. Look a name
# up with member_index(); it prints the array index or returns 1 if the
# name isn't in the final set yet.

declare -a M_NAME=() M_SRC=() M_DESC=() M_CUSTOM=()

add_member() {   # add_member NAME SRC DESC CUSTOM(0|1)
    M_NAME+=("$1"); M_SRC+=("$2"); M_DESC+=("$3"); M_CUSTOM+=("$4")
}
member_index() {
    local want="$1" i
    for (( i=0; i<${#M_NAME[@]}; i++ )); do
        if [[ "${M_NAME[$i]}" == "$want" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
    done
    return 1
}
member_override_path() {
    local want="$1" entry name path
    for entry in "${MEMBER_OVERRIDES[@]:-}"; do
        [[ -z "$entry" ]] && continue
        name="${entry%%=*}"
        path="${entry#*=}"
        if [[ "$name" == "$want" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}
is_omitted() {
    local want="$1" n
    for n in "${OMIT_NAMES[@]:-}"; do
        [[ -n "$n" && "$n" == "$want" ]] && return 0
    done
    return 1
}

if [[ "$REHEARSE" -eq 1 ]]; then
    MODE="rehearsal (repacks $STOCK_FROM's own members, unchanged)"
    for name in "${STOCK_MEMBERS[@]}"; do
        add_member "$name" "$STOCK_DIR/$name" "$STOCK_FROM (stock)" 0
    done
else
    for name in "${STOCK_MEMBERS[@]}"; do
        if is_omitted "$name"; then
            log "omitting member: $name (--omit)"
            continue
        fi
        if [[ "$name" == "$PRIMARY_MEMBER_NAME" ]]; then
            add_member "$name" "$IMAGE_ARG" "$IMAGE_ARG (custom, primary image)" 1
            continue
        fi
        if ov="$(member_override_path "$name")"; then
            add_member "$name" "$ov" "$ov (custom, --member)" 1
            continue
        fi
        add_member "$name" "$STOCK_DIR/$name" "$STOCK_FROM (defaulted to stock)" 0
    done

    # --image targeting a name not present in the stock archive: append it.
    if [[ -n "$IMAGE_ARG" ]] && ! member_index "$PRIMARY_MEMBER_NAME" >/dev/null; then
        add_member "$PRIMARY_MEMBER_NAME" "$IMAGE_ARG" "$IMAGE_ARG (custom, primary image, NOT present in stock archive)" 1
    fi

    # --member entries naming a member the stock archive doesn't have: append.
    for entry in "${MEMBER_OVERRIDES[@]:-}"; do
        [[ -z "$entry" ]] && continue
        name="${entry%%=*}"; path="${entry#*=}"
        if ! is_omitted "$name" && ! member_index "$name" >/dev/null; then
            add_member "$name" "$path" "$path (custom, --member, NOT present in stock archive)" 1
        fi
    done

    [[ "${#M_NAME[@]}" -gt 0 ]] || die "the final member set is empty — check your --omit list"
fi
FINAL_MEMBERS=("${M_NAME[@]}")

# --- unrecoverable-member gate ----------------------------------------------

for (( i=0; i<${#M_NAME[@]}; i++ )); do
    name="${M_NAME[$i]}"
    [[ "${M_CUSTOM[$i]}" -eq 1 ]] || continue
    is_unrecoverable "$name" || continue
    [[ -f "$STOCK_DIR/$name" ]] || continue   # newly-added member, no stock baseline to compare
    src_hash="$(sha256_of "${M_SRC[$i]}")"
    stock_hash="$(sha256_of "$STOCK_DIR/$name")"
    if [[ "$src_hash" != "$stock_hash" ]]; then
        if [[ "$I_KNOW_NOT_STOCK" -ne 1 ]]; then
            die "member '$name' is listed in UNRECOVERABLE_MEMBERS and your replacement
(${M_SRC[$i]}, sha256 $src_hash) is NOT byte-identical to the stock
member (sha256 $stock_hash) from $STOCK_FROM. This is, by your own
UNRECOVERABLE_MEMBERS setting, a write with no software recovery path if it
goes wrong. Refusing to package it without explicit acknowledgement.
  - To omit this member entirely (recommended for a first install), use
    --omit $name instead.
  - To knowingly package a non-stock replacement, re-run with
    --i-know-this-is-not-stock in addition to your --image/--member flag."
        fi
        log ""
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log "!! WARNING: '$name' is UNRECOVERABLE and DOES NOT MATCH stock content.      !!"
        log "!! Proceeding only because --i-know-this-is-not-stock was explicitly given. !!"
        log "!!   ours:  $src_hash"
        log "!!   stock: $stock_hash"
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log ""
    fi
done

# --- validate each member's content -----------------------------------------

hdr "Validating members"
PRIMARY_ESPTOOL_INFO=""
for (( i=0; i<${#M_NAME[@]}; i++ )); do
    name="${M_NAME[$i]}"
    log "member: $name"
    log "  source: ${M_DESC[$i]}"
    if [[ "$name" == "$PRIMARY_MEMBER_NAME" ]]; then
        PRIMARY_ESPTOOL_INFO="$(validate_primary_image "${M_SRC[$i]}")"
        printf '%s\n' "$PRIMARY_ESPTOOL_INFO" | sed 's/^/    /'
    else
        validate_generic_member "${M_SRC[$i]}"
        log "    OK ($(size_of "${M_SRC[$i]}") bytes)"
    fi
done

# --- stage the members under their exact required names ---------------------

STAGE_DIR="$(mktempdir)"
for (( i=0; i<${#M_NAME[@]}; i++ )); do
    cp "${M_SRC[$i]}" "$STAGE_DIR/${M_NAME[$i]}"
done

# --- build the archive -------------------------------------------------------

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
OUT_TAR="$OUT_DIR/$(basename "$STOCK_FROM")"

# COPYFILE_DISABLE keeps macOS from smuggling AppleDouble (._*) resource-fork
# entries into the archive, which would otherwise force PAX extended headers.
COPYFILE_DISABLE=1 tar --format ustar -cf "$OUT_TAR" -C "$STAGE_DIR" "${FINAL_MEMBERS[@]}"

hdr "Archive listing (tar -tvf)"
tar -tvf "$OUT_TAR"

# --- verify: pure USTAR, exact members, exact order, no extended headers ----

VERIFY_DIR="$(mktempdir)"
VERIFY_PY="$VERIFY_DIR/verify_tar.py"
cat > "$VERIFY_PY" <<'PYEOF'
import sys, tarfile

def fail(msg):
    print("VERIFY-FAIL: " + msg)
    sys.exit(1)

path = sys.argv[1]
expected = sys.argv[2:]

with open(path, 'rb') as f:
    data = f.read()

if len(data) % 512 != 0:
    fail("archive size is not a multiple of 512 bytes")

zero_block = b'\x00' * 512
offset = 0
seen_names = []
while offset < len(data):
    block = data[offset:offset + 512]
    if block == zero_block:
        offset += 512
        continue
    name = block[0:100].split(b'\x00', 1)[0].decode('ascii', 'replace')
    typeflag = block[156:157]
    magic = block[257:263]
    version = block[263:265]
    if magic != b'ustar\x00' or version != b'00':
        fail("header at offset %d for %r is not pure POSIX ustar (magic=%r version=%r)"
             % (offset, name, magic, version))
    if typeflag in (b'x', b'g', b'L', b'K'):
        fail("header at offset %d is a PAX/GNU extended header (typeflag=%r) -- not allowed"
             % (offset, typeflag))
    if typeflag not in (b'0', b'\x00'):
        fail("member %r has unexpected typeflag %r (only plain files allowed)" % (name, typeflag))
    if name.startswith('./'):
        fail("member name %r has a './' prefix" % name)
    size_field = block[124:136].split(b'\x00', 1)[0].strip()
    size = int(size_field, 8) if size_field else 0
    seen_names.append(name)
    offset += 512 + ((size + 511) // 512) * 512

if seen_names != expected:
    fail("raw header member order/names %r != expected %r" % (seen_names, expected))

with tarfile.open(path, 'r') as tf:
    members = tf.getmembers()
    names2 = [m.name for m in members]
    if names2 != expected:
        fail("tarfile member order/names %r != expected %r" % (names2, expected))
    for m in members:
        if not m.isfile():
            fail("member %s is not a regular file" % m.name)
        if m.pax_headers:
            fail("member %s carries PAX extended headers: %r" % (m.name, m.pax_headers))

print("VERIFY-OK: pure USTAR, %d members, names and order match: %s" % (len(seen_names), ", ".join(seen_names)))
PYEOF

hdr "Verifying archive format (raw ustar header walk + python3 tarfile)"
VERIFY_OUT="$(python3 "$VERIFY_PY" "$OUT_TAR" "${FINAL_MEMBERS[@]}")"
log "$VERIFY_OUT"
[[ "$VERIFY_OUT" == VERIFY-OK:* ]] || die "archive verification failed"

# Cross-check: content read back out of the tar matches what was staged in.
for m in "${FINAL_MEMBERS[@]}"; do
    tar -x -O -f "$OUT_TAR" "$m" > "$VERIFY_DIR/$m"
    h_staged="$(sha256_of "$STAGE_DIR/$m")"
    h_intar="$(sha256_of "$VERIFY_DIR/$m")"
    [[ "$h_staged" == "$h_intar" ]] \
        || die "member $m: staged content ($h_staged) != content read back from the tar ($h_intar)"
done
log "In-tar content hashes match staged input for all ${#FINAL_MEMBERS[@]} members."

# --- checksums, comparison table, and manifest ------------------------------
#
# Parallel arrays again (see note above `add_member`), indexed identically
# to M_NAME/M_SRC/M_DESC/M_CUSTOM.

declare -a H_OURS=() H_STOCK=() R_CMP=()
for (( i=0; i<${#M_NAME[@]}; i++ )); do
    name="${M_NAME[$i]}"
    H_OURS[$i]="$(sha256_of "$STAGE_DIR/$name")"
    if [[ -f "$STOCK_DIR/$name" ]]; then
        H_STOCK[$i]="$(sha256_of "$STOCK_DIR/$name")"
        if [[ "${H_OURS[$i]}" == "${H_STOCK[$i]}" ]]; then R_CMP[$i]="MATCH"; else R_CMP[$i]="DIFFER"; fi
    else
        H_STOCK[$i]="(not in stock archive)"
        R_CMP[$i]="NEW"
    fi
done

print_comparison_table() {
    printf '%-24s %10s %10s  %-8s\n' "MEMBER" "OUR-SIZE" "STK-SIZE" "RESULT"
    local j ssize
    for (( j=0; j<${#M_NAME[@]}; j++ )); do
        ssize="-"
        [[ -f "$STOCK_DIR/${M_NAME[$j]}" ]] && ssize="$(size_of "$STOCK_DIR/${M_NAME[$j]}")"
        printf '%-24s %10s %10s  %-8s\n' "${M_NAME[$j]}" "$(size_of "$STAGE_DIR/${M_NAME[$j]}")" "$ssize" "${R_CMP[$j]}"
    done
    for m in "${STOCK_MEMBERS[@]}"; do
        if is_omitted "$m"; then
            printf '%-24s %10s %10s  %-8s\n' "$m" "-" "$(size_of "$STOCK_DIR/$m")" "OMITTED"
        fi
    done
}

hdr "Comparison vs. stock ($STOCK_FROM)"
print_comparison_table

if [[ "$REHEARSE" -eq 1 ]]; then
    hdr "Rehearsal verification"
    all_match=1
    for (( i=0; i<${#M_NAME[@]}; i++ )); do
        [[ "${R_CMP[$i]}" == "MATCH" ]] || all_match=0
    done
    if [[ "$all_match" -eq 1 ]]; then
        log "REHEARSAL: PASS — all members are byte-identical to $STOCK_FROM."
        log "The packaging pipeline reproduces the stock archive's content exactly."
    else
        die "REHEARSAL: FAIL — a repack of the stock archive's own members did not come back byte-identical. The pipeline is not trustworthy until this is fixed."
    fi
fi

H_TAR="$(sha256_of "$OUT_TAR")"

{ echo "$H_TAR  $(basename "$OUT_TAR")"; } > "$OUT_DIR/SHA256SUMS"

{
    echo "# sha256 of each tar MEMBER's content (not separate files in this directory)."
    echo "# Verify with: tar -x -O -f $(basename "$OUT_TAR") <name> | shasum -a 256"
    for (( i=0; i<${#M_NAME[@]}; i++ )); do
        echo "${H_OURS[$i]}  ${M_NAME[$i]}"
    done
} > "$OUT_DIR/MEMBER-SHA256SUMS"

{
    echo "$(basename "$OUT_TAR") packaging manifest"
    echo "generated: $STAMP"
    echo "generated by: scripts/make-update-tar.sh"
    echo "mode: ${MODE:-custom (explicit --image and/or --member/--omit)}"
    echo "stock-from: $STOCK_FROM"
    echo "stock-from sha256: $STOCK_FROM_HASH"
    echo
    echo "tar: $(tar --version 2>&1 | head -1)"
    echo
    echo "== Members =="
    for (( i=0; i<${#M_NAME[@]}; i++ )); do
        echo "- ${M_NAME[$i]}"
        echo "    source: ${M_DESC[$i]}"
        echo "    size:   $(size_of "$STAGE_DIR/${M_NAME[$i]}") bytes"
        echo "    sha256: ${H_OURS[$i]}"
        echo "    vs stock: ${R_CMP[$i]}"
        if [[ "${R_CMP[$i]}" == "DIFFER" ]] && is_unrecoverable "${M_NAME[$i]}"; then
            echo "    !! UNRECOVERABLE and non-stock — packaged only via --i-know-this-is-not-stock."
        fi
    done
    for m in "${STOCK_MEMBERS[@]}"; do
        is_omitted "$m" && echo "- $m: OMITTED (--omit)"
    done
    echo
    echo "== Archive =="
    echo "path:   $OUT_TAR"
    echo "size:   $(size_of "$OUT_TAR") bytes"
    echo "sha256: $H_TAR"
    echo "format: ustar (verified: raw header magic + python3 tarfile)"
    echo "member order: ${FINAL_MEMBERS[*]}"
    echo
    if [[ -n "$PRIMARY_ESPTOOL_INFO" ]]; then
        echo "== esptool image_info on $PRIMARY_MEMBER_NAME =="
        printf '%s\n' "$PRIMARY_ESPTOOL_INFO"
        echo
    fi
    echo "== Comparison vs. stock =="
    print_comparison_table
    if [[ "$REHEARSE" -eq 1 ]]; then
        echo
        echo "REHEARSAL: ${all_match:+PASS}"
        [[ "$all_match" -eq 1 ]] || echo "REHEARSAL: FAIL"
    fi
} > "$OUT_DIR/MANIFEST.txt"

hdr "Wrote"
log "  $OUT_TAR"
log "  $OUT_DIR/SHA256SUMS"
log "  $OUT_DIR/MEMBER-SHA256SUMS"
log "  $OUT_DIR/MANIFEST.txt"

exit 0
