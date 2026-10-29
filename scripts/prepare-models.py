"""Собирает архивы моделей для релиза models-v1 из оригинальных источников.

  gigaam-base   ← istupakov/gigaam-multilingual-ctc-onnx        (int8, ONNX-экспорт ai-sage/GigaAM-Multilingual)
  gigaam-large  ← istupakov/gigaam-multilingual-large-ctc-onnx  (int8)
  punct-int8    ← 1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase (fp32 → динамическая квантизация int8)
  silero-vad    ← onnx-community/silero-vad (через onnx-asr)

Во всех моделях веса вынесены в отдельный файл *.onnx.data. ONNX Runtime отображает такой
файл в память (mmap) вместо копирования — потребление памяти падает в 1.2–4.6 раза.

Нужны пакеты: onnx, onnxruntime, huggingface_hub, onnx-asr.
Запуск:  python scripts/prepare-models.py dist/models
"""

import hashlib
import shutil
import sys
import tempfile
from pathlib import Path

import onnx
import onnx_asr
from huggingface_hub import hf_hub_download, snapshot_download
from onnxruntime.quantization import QuantType, quantize_dynamic


def externalize(src: Path, dst: Path):
    model = onnx.load(str(src))
    onnx.save_model(model, str(dst), save_as_external_data=True, all_tensors_to_one_file=True,
                    location=dst.name + ".data", size_threshold=1024)


def gigaam(repo: str, folder: Path):
    snap = Path(snapshot_download(repo, allow_patterns=["*.int8.onnx", "*.txt", "config.json"]))
    folder.mkdir(parents=True)
    for f in snap.iterdir():
        if f.name.endswith(".int8.onnx"):
            externalize(f, folder / f.name)
        else:
            shutil.copy(f, folder / f.name)


def punctuation(folder: Path):
    repo = "1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase"
    folder.mkdir(parents=True)
    for name in ["sp.model", "config.yaml"]:
        shutil.copy(hf_hub_download(repo, name), folder / name)
    with tempfile.TemporaryDirectory() as tmp:
        quantized = Path(tmp) / "model.onnx"
        quantize_dynamic(hf_hub_download(repo, "model.onnx"), str(quantized), weight_type=QuantType.QInt8)
        externalize(quantized, folder / "model.onnx")


def main(out: Path):
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        gigaam("istupakov/gigaam-multilingual-ctc-onnx", work / "gigaam-base")
        gigaam("istupakov/gigaam-multilingual-large-ctc-onnx", work / "gigaam-large")
        punctuation(work / "punct-int8")
        onnx_asr.load_vad("silero", work / "silero-vad")

        for folder in sorted(work.iterdir()):
            archive = Path(shutil.make_archive(str(out / folder.name), "zip", work, folder.name))
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            print(f"{archive.name:20s} {archive.stat().st_size / 1e6:8.1f} MB  sha256 {digest}")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "dist/models"))
