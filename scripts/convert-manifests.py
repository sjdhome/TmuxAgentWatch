#!/usr/bin/env python3
"""Convert herdr's detection manifests (TOML) to one JSON file.

The manifests are maintained in herdr (Apache-2.0; see NOTICE) and read from
a sibling checkout. This app bundles them as JSON so no TOML parser is
needed at runtime.

Usage:
  python3 scripts/convert-manifests.py [SOURCE_DIR] [OUT_FILE]

Defaults:
  SOURCE_DIR = ../herdr/src/detect/manifests
  OUT_FILE   = TmuxAgentWatch/Resources/manifests.json
"""

import json
import re
import sys
import tomllib
from pathlib import Path

GATE_KEYS = ("contains", "regex", "line_regex", "all", "any", "not")

# Rust's regex crate accepts \u{FE0E}; NSRegularExpression (ICU) only knows
# \x{FE0E}. Rewrite the escape unless its backslash is itself escaped.
_U_ESCAPE = re.compile(r"(?<!\\)((?:\\\\)*)\\u\{([0-9a-fA-F]{1,6})\}")


def icu_pattern(pattern: str) -> str:
    return _U_ESCAPE.sub(lambda m: m.group(1) + "\\x{" + m.group(2) + "}", pattern)


def convert_gate(raw: dict) -> dict:
    unknown = set(raw) - set(GATE_KEYS)
    if unknown:
        raise SystemExit(f"unknown gate keys: {sorted(unknown)}")
    gate = {}
    if raw.get("contains"):
        gate["contains"] = raw["contains"]
    for key in ("regex", "line_regex"):
        if raw.get(key):
            gate[key] = [icu_pattern(pattern) for pattern in raw[key]]
    for key in ("all", "any", "not"):
        if raw.get(key):
            gate[key] = [convert_gate(nested) for nested in raw[key]]
    return gate


RULE_KEYS = GATE_KEYS + (
    "id",
    "state",
    "priority",
    "region",
    "skip_state_update",
    "visible_idle",
    "visible_blocker",
    "visible_working",
)


def convert_rule(raw: dict) -> dict:
    unknown = set(raw) - set(RULE_KEYS)
    if unknown:
        raise SystemExit(f"rule {raw.get('id')!r}: unknown keys {sorted(unknown)}")
    rule = {
        "id": raw["id"],
        "state": raw["state"],
        "priority": raw.get("priority", 0),
        "region": raw.get("region", "whole_recent"),
    }
    for key in ("skip_state_update", "visible_idle", "visible_blocker", "visible_working"):
        if raw.get(key):
            rule[key] = True
    gate = convert_gate({key: raw[key] for key in GATE_KEYS if key in raw})
    rule.update(gate)
    return rule


def convert_manifest(path: Path) -> dict:
    raw = tomllib.loads(path.read_text())
    manifest = {
        "id": raw["id"],
        "min_engine_version": raw.get("min_engine_version", 0),
        "rules": [convert_rule(rule) for rule in raw.get("rules", [])],
    }
    return manifest


def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else repo.parent / "herdr/src/detect/manifests"
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else repo / "TmuxAgentWatch/Resources/manifests.json"

    tomls = sorted(source.glob("*.toml"))
    if not tomls:
        raise SystemExit(f"no manifests found in {source}")

    manifests = [convert_manifest(path) for path in tomls]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifests, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {len(manifests)} manifests to {out}")


if __name__ == "__main__":
    main()
