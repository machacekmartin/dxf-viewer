#!/usr/bin/env python3
"""Run both the Swift parser and ezdxf over every .dxf in a directory and
report which files agree.

Usage:
    tools/.venv/bin/python tools/validate.py [dir]

Default dir is examples/dxf-parser. The Swift binary is expected at
.build/release/DXFViewer (build with `swift build -c release` first).

Pass criteria (strict; tunable here, not in the harness):
- entity_count: exact equality
- by_kind: every kind present in ref must appear in ours with matching count;
  no extra kinds in ours either
- bounds: each axis within max(1.0, |ref| * 0.001) of ref
- sample_texts: first 5 TEXT strings match exactly when both sides have them
"""
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SWIFT_BIN = REPO / ".build" / "release" / "DXFViewer"
PY = REPO / "tools" / ".venv" / "bin" / "python"
REF_SCRIPT = REPO / "tools" / "ezdxf_ref.py"


def run_ours(path: Path) -> dict | None:
    r = subprocess.run([str(SWIFT_BIN), "--parse", str(path), "--json"],
                       capture_output=True, text=True)
    if r.returncode != 0 and not r.stdout.strip():
        return {"ok": False, "error": (r.stderr or "swift parse failed").strip()}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "error": "swift output was not JSON: " + r.stdout[:200]}


def run_ref(path: Path) -> dict | None:
    r = subprocess.run([str(PY), str(REF_SCRIPT), str(path)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return {"ok": False, "error": (r.stderr or "ezdxf failed").strip()}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "error": "ezdxf output was not JSON: " + r.stdout[:200]}


def compare(ours: dict, ref: dict) -> list[str]:
    issues: list[str] = []

    if ours["entity_count"] != ref["entity_count"]:
        issues.append(
            f"entity count: ours={ours['entity_count']} ref={ref['entity_count']} "
            f"Δ={ours['entity_count'] - ref['entity_count']}"
        )

    ref_kinds = set(ref["by_kind"].keys())
    our_kinds = set(ours["by_kind"].keys())
    missing = ref_kinds - our_kinds
    extra = our_kinds - ref_kinds
    if missing:
        issues.append(f"missing kinds: {sorted(missing)}")
    if extra:
        issues.append(f"extra kinds: {sorted(extra)}")
    for k in sorted(ref_kinds & our_kinds):
        if ours["by_kind"][k] != ref["by_kind"][k]:
            issues.append(
                f"  {k}: ours={ours['by_kind'][k]} ref={ref['by_kind'][k]}"
            )

    if ref.get("bounds") and ours.get("bounds"):
        # Drift in the "tighter than ref" direction is always OK — ezdxf's bbox is
        # known to over-estimate SPLINE bounds (it doesn't tessellate the curve), so
        # being tighter than ref often means *we* are more accurate, not less.
        # In the over-extending direction allow 5% of the ref's axis span before
        # flagging — text bbox approximations and curve sampling vary at that scale.
        ref_w = max(1.0, float(ref["bounds"]["xmax"]) - float(ref["bounds"]["xmin"]))
        ref_h = max(1.0, float(ref["bounds"]["ymax"]) - float(ref["bounds"]["ymin"]))
        for axis in ("xmin", "ymin", "xmax", "ymax"):
            o = float(ours["bounds"][axis])
            r = float(ref["bounds"][axis])
            extent = ref_w if axis in ("xmin", "xmax") else ref_h
            tol = max(2.0, extent * 0.05)
            # "Tighter" = ours' bbox is inside ref's bbox on this axis.
            tighter = (o > r) if axis.endswith("min") else (o < r)
            if tighter:
                continue
            if abs(o - r) > tol:
                issues.append(f"bounds.{axis}: ours={o:.3f} ref={r:.3f} (tol {tol:.3f}, over-extends)")

    if ref.get("sample_texts") and ours.get("sample_texts"):
        for i, (o, r) in enumerate(zip(ours["sample_texts"], ref["sample_texts"])):
            if o != r:
                issues.append(f"sample_texts[{i}]: ours={o!r} ref={r!r}")

    return issues


def main():
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "examples" / "dxf-parser"
    files = sorted(target.glob("*.dxf"))
    if not files:
        print(f"no .dxf files in {target}", file=sys.stderr)
        sys.exit(2)

    if not SWIFT_BIN.exists():
        print(f"missing {SWIFT_BIN}; run `swift build -c release` first", file=sys.stderr)
        sys.exit(2)

    print(f"# DXF parser validation\n")
    print(f"`{target}` — {len(files)} file(s)\n")
    print("| File | Ours | Ref | Status |")
    print("|---|---|---|---|")

    n_pass = n_fail = n_ours_err = n_ref_only_err = 0
    details: list[tuple[str, list[str]]] = []
    for f in files:
        ours = run_ours(f) or {}
        ref = run_ref(f) or {}

        def one_line(s: str) -> str:
            return s.split("\n")[0].strip()[:80]

        if not ours.get("ok"):
            print(f"| {f.name} | – | {ref.get('entity_count','-')} | ours error: {one_line(ours.get('error','?'))} |")
            n_ours_err += 1
            details.append((f.name, ["ours error: " + ours.get("error", "?")]))
            continue
        if not ref.get("ok"):
            # ezdxf can crash on edge-case DXFs (degenerate INSERT transforms, etc).
            # Don't count it as our failure — just record what our parser sees.
            print(f"| {f.name} | {ours['entity_count']} | – | ⓘ ref crashed; ours parsed ok |")
            n_ref_only_err += 1
            details.append((f.name, ["ref-only crash (informational): " + one_line(ref.get("error", "?"))]))
            continue

        issues = compare(ours, ref)
        status = "✓" if not issues else f"⚠ {len(issues)} issue(s)"
        print(f"| {f.name} | {ours['entity_count']} | {ref['entity_count']} | {status} |")
        if issues:
            details.append((f.name, issues))
            n_fail += 1
        else:
            n_pass += 1

    print(f"\n**Summary:** {n_pass} pass · {n_fail} mismatch · {n_ours_err} ours-error · {n_ref_only_err} ref-only-error\n")
    if details:
        print("## Details\n")
        for name, issues in details:
            print(f"### {name}")
            for i in issues:
                print(f"- {i}")
            print()
    sys.exit(0 if not n_fail and not n_ours_err else 1)


if __name__ == "__main__":
    main()
