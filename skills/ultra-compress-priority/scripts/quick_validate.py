#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

base = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]).resolve()
required = [
    base / "SKILL.md",
    base / "references" / "priority_matrix.yaml",
    base / "scripts" / "score.py",
]
missing = [str(path.relative_to(base)) for path in required if not path.exists()]
if missing:
    raise SystemExit("MISSING=" + ",".join(missing))
text = (base / "SKILL.md").read_text(encoding="utf-8")
for needle in ["name: ultra-compress-priority", "description:", "paid OpenAI API automatic fallback is OFF", "Telegram bot remains the single poller"]:
    if needle not in text:
        raise SystemExit("SKILL_MARKER_MISSING=" + needle)
proc = subprocess.run(
    [sys.executable, str(base / "scripts" / "score.py"), "매일 반복 작업을 무료 모델로 자동화해줘"],
    text=True,
    capture_output=True,
    check=False,
)
if proc.returncode != 0:
    raise SystemExit("SCORER_FAILED=" + proc.stderr[:300])
data = json.loads(proc.stdout)
for key in ["score", "rank", "route", "capsule"]:
    if key not in data:
        raise SystemExit("SCORER_KEY_MISSING=" + key)
print("VALID=1")
print(data["capsule"])
