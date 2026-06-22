#!/usr/bin/env python3
"""Emit a fingerprint of a DXF file using ezdxf as ground truth.

Schema mirrors what `DXFViewer --parse <file> --json` produces so the validator
can diff them like-for-like.

INSERT entities are exploded recursively (matches what our Swift parser does
when it expands blocks into the entity stream). LWPOLYLINE collapses into
POLYLINE; MTEXT collapses into TEXT.
"""
import json
import sys
from pathlib import Path

import ezdxf
from ezdxf import bbox


def collect(entities):
    for e in entities:
        t = e.dxftype()
        if t == "INSERT":
            try:
                yield from collect(e.virtual_entities())
            except Exception:
                # virtual_entities can fail on malformed blocks; keep going.
                yield e
        else:
            yield e


def main():
    path = Path(sys.argv[1])
    file_name = path.name
    try:
        doc = ezdxf.readfile(str(path))
    except Exception as e:
        print(json.dumps({"file": file_name, "ok": False, "error": str(e)}))
        return

    msp = doc.modelspace()

    by_kind: dict[str, int] = {}
    by_layer: dict[str, int] = {}
    sample_texts: list[str] = []

    def text_of(e):
        # Our Swift parser runs stripDxfEscapes / stripMText on the raw text, so
        # %%u-style control codes and MTEXT formatting tags don't survive. Mirror
        # that here so the validator compares the user-visible string.
        if e.dxftype() == "MTEXT":
            try:
                return e.plain_text(split=False)
            except Exception:
                return ""
        raw = getattr(e.dxf, "text", "")
        # Strip common AutoCAD overrides: %%u (underline), %%o (overline),
        # %%d (degree), %%p (±), %%c (⌀), %%%(literal %).
        import re
        raw = re.sub(r"%%[uUoO]", "", raw)
        raw = raw.replace("%%d", "°").replace("%%p", "±").replace("%%c", "⌀").replace("%%%", "%")
        return raw

    for e in collect(msp):
        t = e.dxftype()
        # Normalize so labels match the Swift side. Our parser stores both
        # POLYLINE and LWPOLYLINE under .polyline, and both TEXT and MTEXT
        # under .text, so we collapse them here too.
        if t == "LWPOLYLINE":
            t = "POLYLINE"
        elif t == "MTEXT":
            t = "TEXT"
        by_kind[t] = by_kind.get(t, 0) + 1
        layer = getattr(e.dxf, "layer", "0")
        by_layer[layer] = by_layer.get(layer, 0) + 1
        if t == "TEXT" and len(sample_texts) < 5:
            sample_texts.append(text_of(e))

    bb = bbox.extents(msp)
    bounds = None
    if bb.has_data:
        bounds = {
            "xmin": float(bb.extmin.x),
            "ymin": float(bb.extmin.y),
            "xmax": float(bb.extmax.x),
            "ymax": float(bb.extmax.y),
        }

    insunits = int(doc.header.get("$INSUNITS", 0))

    print(json.dumps({
        "file": file_name,
        "ok": True,
        "entity_count": sum(by_kind.values()),
        "by_kind": by_kind,
        "by_layer": by_layer,
        "bounds": bounds,
        "insunits": insunits,
        "sample_texts": sample_texts,
    }, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
