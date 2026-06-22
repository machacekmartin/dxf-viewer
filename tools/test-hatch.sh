#!/usr/bin/env bash
# Self-check for the HATCH multi-boundary + pattern parsing path.
# Asserts the floorplan fixture's hatch entities parse with the expected shape.
# Fails loud on regression.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/DXFViewer"
FIXTURE="$ROOT/examples/floorplan.dxf"

if [[ ! -x "$BIN" ]]; then
    echo "binary missing: $BIN — run swift build -c release first" >&2
    exit 1
fi

DUMP="$("$BIN" --parse "$FIXTURE" --dump)"

# Hatch #145 was the user-reported offender: 10 stray boundary pts before fix
# (4 + 4 boundary + 2 seed leak). Post-fix expectation: 8 pts, 2 paths, 1 pattern line.
LINE="$(printf '%s\n' "$DUMP" | awk -F'\t' '$1 == "145"')"
[[ -n "$LINE" ]] || { echo "entity 145 missing from dump"; exit 1; }

assert_contains() {
    local needle="$1"
    if ! printf '%s\n' "$LINE" | grep -qF -- "$needle"; then
        printf 'assertion failed: expected entity 145 to contain %q\n' "$needle" >&2
        printf 'got: %s\n' "$LINE" >&2
        exit 1
    fi
}

assert_contains "HATCH"
assert_contains "8 boundary pts"
assert_contains "2 paths"
assert_contains "1-line pattern"

# Total hatches in the file — outline-only-fallback regression guard.
HATCH_COUNT="$(printf '%s\n' "$DUMP" | awk -F'\t' '$2 == "HATCH"' | wc -l | tr -d ' ')"
[[ "$HATCH_COUNT" -ge 10 ]] || { echo "too few HATCH entities parsed ($HATCH_COUNT)"; exit 1; }

echo "OK — hatch parsing self-check passed ($HATCH_COUNT hatch entities, #145 has 8/2/pattern)"
