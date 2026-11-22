#!/usr/bin/env bash
# Localization checks (G18):
#   1. plutil -lint both Localizable.strings files.
#   2. No accented Vietnamese text in string literals under Sources/ColimaX
#      (comments are ignored; a line containing `check-strings:allow` is exempt, e.g. language names).
#   3. Every key used via String(localized:) or a SwiftUI initializer taking
#      LocalizedStringKey (Text, Button, Label, Toggle, ...) exists in vi.lproj.
#      Extraction is regex-based (best effort); missing keys are printed and fail the script.
#
#   scripts/check-strings.sh                 # check all of Sources/ColimaX
#   scripts/check-strings.sh FILE.swift ...  # check only the given files
#   VI_STRINGS=a.strings:b.strings scripts/check-strings.sh   # use other translation files
#   SHOW_UNUSED=1 scripts/check-strings.sh   # list vi.lproj keys the extractor did not find
set -euo pipefail
cd "$(dirname "$0")/.."

VI="Resources/vi.lproj/Localizable.strings"
EN="Resources/en.lproj/Localizable.strings"
STATUS=0
for f in "$VI" "$EN"; do
  if [ ! -f "$f" ]; then echo "Missing $f" >&2; STATUS=1; continue; fi
  plutil -lint "$f" >/dev/null || { echo "plutil -lint failed: $f" >&2; STATUS=1; }
done
[ $STATUS -eq 0 ] || exit $STATUS

python3 -I - "${VI_STRINGS:-$VI}" "${SHOW_UNUSED:-0}" "$@" <<'PY'
import os, re, subprocess, sys, json

strings_paths = sys.argv[1].split(":")
show_unused = sys.argv[2] == "1"
files = sys.argv[3:]
if not files:
    files = sorted(
        os.path.join(root, name)
        for root, _, names in os.walk("Sources/ColimaX")
        for name in names if name.endswith(".swift")
    )

VIET = re.compile(
    "[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ"
    "ÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ]"
)

def load_strings(path):
    proc = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if proc.returncode != 0:
        # A comment-only file (e.g. en.lproj) cannot be converted to JSON; treat it as empty.
        if subprocess.run(["plutil", "-lint", "-s", path]).returncode == 0:
            return {}
        sys.exit(f"Cannot read {path}: {proc.stderr.strip()}")
    return json.loads(proc.stdout)

translations = {}
for p in strings_paths:
    translations.update(load_strings(p))

SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|llu|ld|lu|lf|d|i|u|f|s)")
PH = "\x00"

def normalize_key(k):
    return SPEC.sub(PH, k)

known = {normalize_key(k) for k in translations}
used = set()

def scan(src):
    """Return (start, end, multiline, segments) for every string literal outside comments.
    segments: the literal text parts, with each interpolation replaced by None."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i); i = n if j < 0 else j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        raw = 0
        while i + raw < n and src[i + raw] == "#": raw += 1
        if i + raw < n and src[i + raw] == '"':
            start = i
            i += raw
            multi = src.startswith('"""', i)
            quote = '"""' if multi else '"'
            i += len(quote)
            close = quote + "#" * raw
            esc = "\\" + "#" * raw
            segs, buf = [], []
            while i < n and not src.startswith(close, i):
                if src.startswith(esc + "(", i):
                    segs.append("".join(buf)); buf = []; segs.append(None)
                    i += len(esc) + 1; depth = 1
                    while i < n and depth:
                        if src[i] == "(": depth += 1
                        elif src[i] == ")": depth -= 1
                        elif src[i] == '"':
                            # string literal nested inside an interpolation
                            k = i + 1
                            while k < n and src[k] != '"':
                                k += 2 if src[k] == "\\" else 1
                            i = k
                        i += 1
                    continue
                if src.startswith(esc, i) and raw == 0:
                    nxt = src[i + 1] if i + 1 < n else ""
                    buf.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0"}.get(nxt, nxt))
                    i += 2; continue
                buf.append(src[i]); i += 1
            segs.append("".join(buf))
            i += len(close)
            out.append((start, i, multi, segs))
            continue
        i += 1
    return out

CALL = (r"(?:\bText|\bButton|\bLabel|\bToggle|\bPicker|\bSection|\bTableColumn|\.help|\.navigationTitle|"
        r"\.navigationSubtitle|\bContentUnavailableView|\bTextField|\bSecureField|\bStepper|\bLabeledContent|"
        r"\bLink|\bMenu|\bCommandMenu|\bGroupBox|\bDisclosureGroup|\bLocalizedStringKey|\.confirmationDialog|\.alert|"
        r"\bString\(localized:|\bLocalizedStringResource|\bProgressView|\bSlider|\bDatePicker|\bShareLink)")
CONTEXT = re.compile(CALL + r"\(?\s*(?:[^()\"\n]*\?\s*(?:\"[^\"\n]*\"\s*:\s*)?)?$|\.searchable\([^()\"\n]*\bprompt:\s*$")

viet_hits, missing = [], []
for path in files:
    src = open(path, encoding="utf-8").read()
    lits = scan(src)
    # replace literals with "" so their contents cannot confuse the context regex
    masked, last = [], 0
    for start, end, multi, segs in lits:
        masked.append(src[last:start]); masked.append('""'); last = end
    masked.append(src[last:])
    masked_src = "".join(masked)
    shift = 0
    for start, end, multi, segs in lits:
        line = src.count("\n", 0, start) + 1
        text = "".join(s for s in segs if s is not None)
        line_text = src[src.rfind("\n", 0, start) + 1:src.find("\n", start) if src.find("\n", start) >= 0 else len(src)]
        if VIET.search(text) and "check-strings:allow" not in line_text:
            viet_hits.append(f"{path}:{line}: {src[start:end].splitlines()[0][:120]}")
        mstart = start - shift
        shift += (end - start) - 2
        if multi:
            continue
        before = masked_src[max(0, mstart - 120):mstart]
        if not CONTEXT.search(before):
            continue
        has_interp = any(s is None for s in segs)
        key = "".join(PH if s is None else (s.replace("%", "%%") if has_interp else s) for s in segs)
        if not key.strip() or not re.search(r"[A-Za-z]", key):
            continue
        used.add(key)
        if key not in known:
            missing.append(f"{path}:{line}: {key.replace(PH, '%@')!r}")

status = 0
if viet_hits:
    print(f"Vietnamese text left in string literals ({len(viet_hits)}):")
    print("\n".join("  " + h for h in viet_hits))
    status = 1
if missing:
    print(f"Keys missing from {':'.join(strings_paths)} ({len(missing)}):")
    print("\n".join("  " + m for m in missing))
    status = 1
for k, v in translations.items():
    if not v.strip():
        print(f"Empty translation for {k!r}"); status = 1
    if sorted(re.sub(r"\d+\$", "", x) for x in SPEC.findall(k)) != sorted(re.sub(r"\d+\$", "", x) for x in SPEC.findall(v)):
        print(f"Format specifiers differ: {k!r} -> {v!r}"); status = 1
if show_unused:
    unused = sorted(k for k in translations if normalize_key(k) not in used)
    print(f"Keys not found by the extractor ({len(unused)}; may be used via variables):")
    print("\n".join("  " + repr(k) for k in unused))
if status == 0:
    print(f"check-strings: OK ({len(files)} files, {len(used)} localized keys, {len(translations)} translations)")
sys.exit(status)
PY
