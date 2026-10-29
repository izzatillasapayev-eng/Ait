# Стенд для сравнения моделей

Инструменты, на которых выбирались модели и делались замеры из [README](../README.md#аналитика).
Приложению Ait они не нужны.

| Файл | Что делает |
|---|---|
| `server.py` + `index.html` | веб-страница на http://localhost:8765: держишь пробел, говоришь — запись распознают GigaAM-Multilingual Large, Kazakh Whisper turbo и Whisper large-v3-turbo, плюс три варианта пунктуации (модель, перенос знаков из Whisper, гибрид). Можно прочитать готовую фразу — тогда считается WER/CER |
| `rescore.py` | заново прогоняет все сохранённые записи через текущий набор моделей |
| `measure.py` | память (phys_footprint) и скорость каждого компонента, каждый в отдельном чистом процессе |

Записи сохраняются в `bench/recordings/`, результаты — в `bench/results.jsonl`. Обе папки
в `.gitignore`: голос и расшифровки остаются только на твоём Mac.

## Запуск

```bash
cd bench
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python server.py
```

Затем открой http://localhost:8765 в Safari или Chrome (нужен доступ к микрофону).
Первый запуск скачает с Hugging Face около 5 GB моделей.
