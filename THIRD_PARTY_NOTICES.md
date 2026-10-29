# Сторонние компоненты

Код Ait распространяется под лицензией MIT (см. [LICENSE](LICENSE)). Модели в релизе
[`models-v1`](https://github.com/izzatillasapayev-eng/Ait/releases/tag/models-v1) и библиотеки,
которые ставит `install-engine.sh`, принадлежат их авторам и распространяются под их лицензиями.

## Модели (лежат в релизе models-v1)

| Архив | Источник | Лицензия | Что изменено |
|---|---|---|---|
| `gigaam-base.zip` | [ai-sage/GigaAM-Multilingual](https://huggingface.co/ai-sage/GigaAM-Multilingual) (220M), ONNX-экспорт [istupakov/gigaam-multilingual-ctc-onnx](https://huggingface.co/istupakov/gigaam-multilingual-ctc-onnx) | MIT, © 2024 GigaChat Team; экспорт © 2025 Ilya Stupakov | веса int8 вынесены в отдельный файл `.onnx.data`, значения не менялись |
| `gigaam-large.zip` | [ai-sage/GigaAM-Multilingual](https://huggingface.co/ai-sage/GigaAM-Multilingual) (600M), ONNX-экспорт [istupakov/gigaam-multilingual-large-ctc-onnx](https://huggingface.co/istupakov/gigaam-multilingual-large-ctc-onnx) | MIT, © 2024 GigaChat Team; экспорт © 2025 Ilya Stupakov | то же |
| `punct-int8.zip` | [1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase](https://huggingface.co/1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase) | Apache-2.0 | динамическая квантизация fp32 → int8 (`onnxruntime.quantization.quantize_dynamic`), веса вынесены в `.onnx.data` |
| `silero-vad.zip` | [snakers4/silero-vad](https://github.com/snakers4/silero-vad) через [onnx-community/silero-vad](https://huggingface.co/onnx-community/silero-vad) | MIT, © 2020-present Silero Team | без изменений |

Архивы можно пересобрать из оригиналов скриптом [`scripts/prepare-models.py`](scripts/prepare-models.py);
результат побитово совпадает с файлами релиза.

Текст лицензии Apache-2.0: https://www.apache.org/licenses/LICENSE-2.0

## Программы, которые скачивает install-engine.sh

| Компонент | Лицензия |
|---|---|
| [uv](https://github.com/astral-sh/uv) (Astral) | MIT / Apache-2.0 |
| CPython 3.12 ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) | PSF License |
| [onnx-asr](https://github.com/istupakov/onnx-asr) | MIT, © 2025 Ilya Stupakov |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | MIT, © Microsoft |
| [NumPy](https://numpy.org) | BSD-3-Clause |
| [SentencePiece](https://github.com/google/sentencepiece) | Apache-2.0 |
| [python-soundfile](https://github.com/bastibe/python-soundfile) | BSD-3-Clause |
| [PyYAML](https://pyyaml.org) | MIT |

Код пунктуации в `Resources/worker.py` — переписанная без PyTorch логика из
[punctuators](https://github.com/1-800-BAD-CODE/punctuators) (Apache-2.0).
