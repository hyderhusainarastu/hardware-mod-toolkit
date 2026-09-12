# Redaction patterns for USB/serial captures

Apply these to **both** the raw capture and the ANSI-stripped clean copy, in place, before either
file is ever staged for commit. They're written as Perl-compatible regexes (the pattern set below
is designed to run via `perl -0777 -pi -e '...' FILE`, which lets each substitution see the whole
file at once rather than line-by-line — needed for a couple of the value-class exclusions below).

Every "value class" here excludes CR/LF, an ANSI escape (`\x1b`), and quote/comma delimiters. That
matters for two reasons: it stops a match in the *raw* log from swallowing a trailing ANSI
color-reset code along with the value, and it lets a quoted or comma-terminated value (
`SSID='<name>',` or `Usage=<n>`) end at the right place instead of eating the rest of the line.

## 1. SSID

```perl
s/((?:Loaded\s+last\s+(?:connected\s+)?SSID|SSID|ssid)\s*[:=]\s*'?)([^\r\n\x1b'",]+)/$1<SSID-REDACTED>/gi;
s/(Connecting\s+to\s+)([^\r\n\x1b'",]+)/$1<SSID-REDACTED>/gi;
s/(\bAP:\s*)([^\r\n\x1b'",]+)/$1<SSID-REDACTED>/gi;
```

Test strings (each should redact the value, keep the key):

```
I (1234) wifi: Loaded last connected SSID: MyHomeNetwork-5G
SSID='CorpGuest', Usage=65
Connecting to MyHomeNetwork-5G
AP: MyHomeNetwork-5G
```

## 2. Credentials / tokens

```perl
s/((?:password|passphrase|passwd|psk|token)\s*[:=]\s*"?)([^\r\n\x1b'",]+)/$1<REDACTED>/gi;
```

Test strings:

```
password: hunter2
psk="correcthorsebatterystaple"
auth_token=abc123def456
```

## 3. MAC addresses (full and bare-hex)

```perl
s/\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){2}):(?:[0-9A-Fa-f]{2}:){2}[0-9A-Fa-f]{2}\b/$1:xx:xx:xx/g;
```

This keeps the OUI (vendor) octets and masks the host-specific back half — enough to say "this is a
device from vendor X" without keeping the unique identifier. Test string:

```
STA MAC: 3c:71:bf:12:34:56
```

→ `STA MAC: 3c:71:bf:xx:xx:xx`

If you'd rather mask the whole address (no vendor info kept at all), broaden the pattern to match
all six octets and replace wholesale — do this instead if the OUI itself is sensitive (e.g. it
would identify an unreleased product's radio module).

## 4. USB serial number embedded in a device-node name

Some firmware derives its USB serial descriptor from a hardware identifier (MAC, chip ID) rather
than a random or fixed string. When it does, the **port path** — e.g.
`/dev/cu.usbmodemAABBCCDDEEFF01` on macOS — leaks that identifier, and it leaks it a second time in
every log/status line that names `$PORT`, independent of whatever's actually flowing through the
port. Redact the port-path display and the capture contents with the same rule:

```perl
s/\busbmodem[0-9A-Fa-f]{8,}/usbmodem<REDACTED>/g;
```

Test string:

```
port found: /dev/cu.usbmodem3C71BF123456 (session 1)
```

→ `port found: /dev/cu.usbmodem<REDACTED> (session 1)`

Adjust the node-name prefix (`usbmodem`, `ttyACM`, `ttyUSB`, ...) to match your platform's naming.
This rule exists independent of whether the identifier the serial number is derived from *changes*
between firmware versions — apply it defensively regardless of which firmware build produced the
capture, since you often don't know until after the fact whether a given build used a MAC-derived
serial or a generic one.

## Self-test

Save the test strings above (one per line) to a scratch file and confirm the pass fires and reports
a non-zero substitution count:

```sh
cat > /tmp/redact-test.txt <<'EOF'
I (1234) wifi: Loaded last connected SSID: MyHomeNetwork-5G
SSID='CorpGuest', Usage=65
Connecting to MyHomeNetwork-5G
AP: MyHomeNetwork-5G
password: hunter2
psk="correcthorsebatterystaple"
STA MAC: 3c:71:bf:12:34:56
port found: /dev/cu.usbmodem3C71BF123456 (session 1)
EOF

perl -0777 -pi -e '
my $n = 0;
$n += s/((?:Loaded\s+last\s+(?:connected\s+)?SSID|SSID|ssid)\s*[:=]\s*'"'"'?)([^\r\n\x1b'"'"'",]+)/$1<SSID-REDACTED>/gi;
$n += s/(Connecting\s+to\s+)([^\r\n\x1b'"'"'",]+)/$1<SSID-REDACTED>/gi;
$n += s/(\bAP:\s*)([^\r\n\x1b'"'"'",]+)/$1<SSID-REDACTED>/gi;
$n += s/((?:password|passphrase|passwd|psk|token)\s*[:=]\s*"?)([^\r\n\x1b'"'"'",]+)/$1<REDACTED>/gi;
$n += s/\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){2}):(?:[0-9A-Fa-f]{2}:){2}[0-9A-Fa-f]{2}\b/$1:xx:xx:xx/g;
$n += s/\busbmodem[0-9A-Fa-f]{8,}/usbmodem<REDACTED>/g;
print STDERR "substitutions: $n\n";
' /tmp/redact-test.txt

cat /tmp/redact-test.txt
rm /tmp/redact-test.txt
```

Expect `substitutions: 7` (or similar — one per matched line) printed to stderr, and every sensitive
value in the printed file replaced by a `<...-REDACTED>` placeholder while the surrounding log text
is untouched.

## Manual gate before `git add`

Regardless of the automatic pass, grep the final files by hand before staging:

```sh
grep -rniE 'ssid|password|passphrase|psk|token|[0-9a-f]{2}(:[0-9a-f]{2}){5}' captures/ | grep -v REDACTED
```

Anything this prints is either a pattern the automatic pass missed (fix the pattern, re-run, and
re-check) or a false positive you can confirm by eye. Never run `git add -A` (or `git add
captures/`) without this check — stage the specific files you've verified.
