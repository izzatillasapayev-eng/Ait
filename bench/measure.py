"""Замер памяти и скорости каждого компонента в отдельном чистом процессе.

Память = phys_footprint процесса (включает и видеопамять Metal) после загрузки модели
и распознавания, минус footprint после импорта библиотек. То есть это вклад самой модели.
Подготовка: models/punct-int8 — из scripts/prepare-models.py (папка punct-int8 из архива),
models/whisper-mlx-8bit|4bit — config.json + model.safetensors (как weights.safetensors) из mlx-community.
Запуск:  .venv/bin/python measure.py
"""

import json
import os
import re
import subprocess
import sys
import time
import warnings

warnings.filterwarnings("ignore")

import glob

# две записи из bench/recordings (у автора: русская 6.4 с и казахская 7.0 с)
AUDIO = sorted(glob.glob("recordings/*.wav"))[:2]
TEXTS = ["привет как дела что ты читаешь", "сен не деп тұрсың қотаыңды айырып жіереін ба"]

COMPONENTS = {
    "gigaam_large_int8_cpu": "GigaAM Large int8 (CPU)",
    "gigaam_large_int8_coreml": "GigaAM Large int8 (CoreML, как в стенде)",
    "gigaam_base_int8_cpu": "GigaAM обычная int8 (CPU)",
    "punct_fp32": "Пунктуация fp32",
    "punct_int8": "Пунктуация int8",
    "whisper_torch_fp16": "Whisper turbo fp16 (PyTorch, как в стенде)",
    "whisper_mlx_fp16": "Whisper turbo fp16 (MLX)",
    "whisper_mlx_8bit": "Whisper turbo 8-bit (MLX)",
    "whisper_mlx_4bit": "Whisper turbo 4-bit (MLX)",
}


def footprint_mb() -> float:
    out = subprocess.run(["footprint", "-p", str(os.getpid())], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", out)
    value, unit = float(m.group(1)), m.group(2)
    return value * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[unit]


def run_component(key: str) -> dict:
    import numpy as np
    import soundfile as sf

    audio = [sf.read(p, dtype="float32")[0] for p in AUDIO]

    if key.startswith("gigaam"):
        import onnx_asr
        name = "gigaam-multilingual-large-ctc" if "large" in key else "gigaam-multilingual-ctc"
        providers = ["CPUExecutionProvider"] if key.endswith("cpu") else None
        base = footprint_mb()
        t = time.time()
        kwargs = {"quantization": "int8"}
        if providers:
            kwargs["providers"] = providers
        m = onnx_asr.load_model(name, **kwargs)
        load_s = time.time() - t
        run = lambda a: m.recognize(a, sample_rate=16000)
        inputs = audio
    elif key.startswith("punct"):
        from punctuators.models import PunctCapSegModelONNX
        from punctuators.models.punc_cap_seg_model import PunctCapSegConfigONNX
        base = footprint_mb()
        t = time.time()
        if key == "punct_fp32":
            m = PunctCapSegModelONNX.from_pretrained("1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase", ort_providers=["CPUExecutionProvider"])
        else:
            m = PunctCapSegModelONNX(PunctCapSegConfigONNX(directory="models/punct-int8"), ort_providers=["CPUExecutionProvider"])
        load_s = time.time() - t
        run = lambda s: m.infer(texts=[s], apply_sbd=False)[0]
        inputs = TEXTS
    elif key == "whisper_torch_fp16":
        import torch
        from transformers import WhisperForConditionalGeneration, WhisperProcessor
        base = footprint_mb()
        t = time.time()
        p = WhisperProcessor.from_pretrained("openai/whisper-large-v3-turbo")
        wm = WhisperForConditionalGeneration.from_pretrained("openai/whisper-large-v3-turbo", dtype=torch.float16).to("mps").eval()
        load_s = time.time() - t

        def run(a):
            f = p(a, sampling_rate=16000, return_tensors="pt").input_features.to("mps", dtype=torch.float16)
            with torch.inference_mode():
                return p.batch_decode(wm.generate(f, task="transcribe"), skip_special_tokens=True)[0]
        inputs = audio
    else:
        import mlx_whisper
        repo = {"whisper_mlx_fp16": "mlx-community/whisper-large-v3-turbo",
                "whisper_mlx_8bit": "models/whisper-mlx-8bit",
                "whisper_mlx_4bit": "models/whisper-mlx-4bit"}[key]
        base = footprint_mb()
        t = time.time()
        mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=repo)  # загрузка
        load_s = time.time() - t
        run = lambda a: mlx_whisper.transcribe(a, path_or_hf_repo=repo)["text"].strip()
        inputs = audio

    run(inputs[0])  # прогрев
    times, outputs = [], []
    for x in inputs:
        t = time.time()
        outputs.append(run(x))
        times.append(time.time() - t)
    peak = footprint_mb() - base
    # освобождаем кэш буферов фреймворка — остаётся то, что модель держит постоянно
    if key.startswith("whisper_mlx"):
        import mlx.core as mx
        mx.clear_cache()
    elif key == "whisper_torch_fp16":
        import torch
        torch.mps.empty_cache()
    import gc
    gc.collect()
    return {
        "key": key,
        "peak_mb": round(peak),
        "ram_mb": round(footprint_mb() - base),
        "load_s": round(load_s, 1),
        "infer_s": round(sum(times) / len(times), 2),
        "outputs": outputs,
    }


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--one":
        print("RESULT " + json.dumps(run_component(sys.argv[2]), ensure_ascii=False), flush=True)
        sys.exit()

    # без аргументов — все компоненты; иначе префиксы, например: measure.py gigaam punct
    keys = [k for k in COMPONENTS if len(sys.argv) < 2 or any(k.startswith(p) for p in sys.argv[1:])]
    rows = []
    if os.path.exists("measurements.json"):
        rows = [r for r in json.load(open("measurements.json", encoding="utf-8")) if r["key"] not in keys]
    for key in keys:
        out = subprocess.run([sys.executable, __file__, "--one", key], capture_output=True, text=True)
        line = next((l for l in out.stdout.splitlines() if l.startswith("RESULT ")), None)
        if not line:
            print(f"{key}: FAILED\n{out.stderr[-1500:]}", flush=True)
            continue
        r = json.loads(line[7:])
        rows.append(r)
        print(f"{COMPONENTS[key]:45s} RAM {r['ram_mb']:5d} MB (peak {r['peak_mb']:5d}) | load {r['load_s']:4.1f}s | infer {r['infer_s']:.2f}s | {r['outputs']}", flush=True)
    with open("measurements.json", "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)
