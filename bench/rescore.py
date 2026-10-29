"""Заново прогоняет все сохранённые записи через текущий набор моделей.

Старые результаты сохраняются в results-<время>.jsonl, новые пишутся в results.jsonl.
Запуск:  .venv/bin/python rescore.py
"""

import json
import shutil
from datetime import datetime

import soundfile as sf

import server

records = [json.loads(line) for line in server.RESULTS.read_text(encoding="utf-8").splitlines() if line.strip()]
backup = server.RESULTS.with_name(f"results-{datetime.now():%Y%m%d-%H%M%S}.jsonl")
shutil.copy(server.RESULTS, backup)

server.load_models()
with server.RESULTS.open("w", encoding="utf-8") as f:
    for rec in records:
        data, _ = sf.read(server.REC_DIR / rec["file"], dtype="float32")
        rec["results"] = server.process(data, rec["reference"], rec["language"])
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(f"--- {rec['file']} ({rec['duration']} s)")
        for r in rec["results"]:
            print(f"  {r['model']:32s} {r['seconds']:5.2f}s | {r['text'][:150]}")

print(f"\nstarted from backup {backup.name}")
