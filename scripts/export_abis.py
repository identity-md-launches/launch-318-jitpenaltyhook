#!/usr/bin/env python3
"""Export compiler ABI arrays from this repository's pinned Foundry configuration."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

for contract in ("JITP", "JITPenaltyHook"):
    result = subprocess.run(
        ["forge", "inspect", f"src/{contract}.sol:{contract}", "abi", "--json"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    )
    abi = json.loads(result.stdout)
    assert isinstance(abi, list)
    destination = ROOT / "docs" / "abi" / f"{contract}.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(abi, indent=2) + "\n")
    print(destination.relative_to(ROOT))
