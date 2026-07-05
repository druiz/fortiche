#!/usr/bin/env python3
"""Convert the raw free-exercise-db dataset into the bundled package resource.

Usage: Scripts/import_exercises.py
Reads  ThirdParty/free-exercise-db/exercises.json (checked in, public domain)
Writes FortichePack/Sources/FortichePack/ExerciseLibrary/Resources/exercises.json

Validates the fields FortichePack's LibraryExercise decoder relies on, and
minifies. Re-run after updating the ThirdParty dataset.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "ThirdParty/free-exercise-db/exercises.json"
DST = ROOT / "FortichePack/Sources/FortichePack/ExerciseLibrary/Resources/exercises.json"

REQUIRED = ["id", "name", "primaryMuscles", "secondaryMuscles", "instructions", "images"]
OPTIONAL = ["force", "level", "mechanic", "equipment", "category"]


def main() -> int:
    exercises = json.loads(SRC.read_text())
    seen_ids = set()
    out = []
    for e in exercises:
        for field in REQUIRED:
            if field not in e:
                raise SystemExit(f"exercise {e.get('id', '?')!r} missing required field {field!r}")
        if e["id"] in seen_ids:
            raise SystemExit(f"duplicate exercise id {e['id']!r}")
        seen_ids.add(e["id"])
        out.append({k: e[k] for k in REQUIRED + OPTIONAL if k in e})

    DST.parent.mkdir(parents=True, exist_ok=True)
    DST.write_text(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
    print(f"wrote {len(out)} exercises -> {DST.relative_to(ROOT)} ({DST.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
