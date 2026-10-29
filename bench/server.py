"""Стенд для сравнения моделей распознавания речи (русский + казахский).

Запуск:  .venv/bin/python server.py   →  http://localhost:8765
Каждая запись сохраняется в recordings/, результаты — в results.jsonl.
"""

import difflib
import io
import json
import os
import re
import subprocess
import time
import warnings
from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import onnx_asr
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import FileResponse
from punctuators.models import PunctCapSegModelONNX
from transformers import WhisperForConditionalGeneration, WhisperProcessor

warnings.filterwarnings("ignore", message=".*CUDAExecutionProvider.*")

ROOT = Path(__file__).parent
REC_DIR = ROOT / "recordings"
RESULTS = ROOT / "results.jsonl"
REC_DIR.mkdir(exist_ok=True)

SR = 16000
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"


def rss_mb() -> float:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(os.getpid())], capture_output=True, text=True)
    return int(out.stdout.strip()) / 1024


class Whisper:
    def __init__(self, repo: str):
        self.processor = WhisperProcessor.from_pretrained(repo)
        self.model = WhisperForConditionalGeneration.from_pretrained(repo, dtype=torch.float16).to(DEVICE).eval()

    def __call__(self, audio: np.ndarray, language: str | None) -> str:
        feats = self.processor(audio, sampling_rate=SR, return_tensors="pt").input_features
        feats = feats.to(DEVICE, dtype=torch.float16)
        kwargs = {"task": "transcribe"}
        if language:
            kwargs["language"] = language
        with torch.inference_mode():
            ids = self.model.generate(feats, **kwargs)
        return self.processor.batch_decode(ids, skip_special_tokens=True)[0].strip()


class GigaAM:
    def __init__(self):
        self.model = onnx_asr.load_model("gigaam-multilingual-large-ctc", quantization="int8")

    def __call__(self, audio: np.ndarray, language: str | None) -> str:
        return self.model.recognize(audio, sample_rate=SR).strip()


class Punctuator:
    """Пунктуация и заглавные буквы для текста без них (47 языков, в т.ч. ru и kk)."""

    def __init__(self):
        self.model = PunctCapSegModelONNX.from_pretrained("1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase")

    def __call__(self, text: str) -> str:
        if not text:
            return text
        text = self.model.infer(texts=[text], apply_sbd=False)[0]
        text = re.sub(r"(?<=[^.!?…]\s)Я\b", "я", text)  # «я» посреди предложения
        return re.sub(r"[,;:]+$", "", text)


def split_punct(token: str) -> tuple[str, str]:
    """'дела?' -> ('дела', '?')"""
    m = re.match(r"^(.*?)([.,!?;:…]*)$", token)
    return m.group(1), m.group(2)


def norm_word(word: str) -> str:
    return re.sub(r"[^\w]", "", word.lower().replace("ё", "е"))


def transfer_punctuation(plain: str, punctuated: str) -> str:
    """Переносит знаки препинания и заглавные буквы из текста Whisper на слова GigaAM."""
    dst = plain.split()
    if not dst:
        return plain
    src = [split_punct(t) for t in punctuated.split()]
    out = list(dst)
    sm = difflib.SequenceMatcher(a=[norm_word(w) for w in dst], b=[norm_word(w) for w, _ in src], autojunk=False)

    def apply(i: int, j: int, case: bool = True, punct: bool = True):
        word, mark = src[j]
        if case and word[:1].isupper():
            out[i] = out[i][:1].upper() + out[i][1:]
        if punct:
            out[i] += mark

    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal" or (tag == "replace" and i2 - i1 == j2 - j1):
            for i, j in zip(range(i1, i2), range(j1, j2)):
                apply(i, j)
        elif tag == "replace":
            apply(i1, j1, punct=False)
            apply(i2 - 1, j2 - 1, case=False)

    text = " ".join(out)
    return text[:1].upper() + text[1:]


def whisper_agrees(plain: str, punctuated: str) -> bool:
    """Whisper услышал почти те же слова и поставил знаки — значит, его пунктуации можно верить."""
    a = [norm_word(w) for w in plain.split()]
    b = [norm_word(w) for w in punctuated.split()]
    ratio = difflib.SequenceMatcher(a=a, b=b, autojunk=False).ratio()
    return ratio >= 0.6 and bool(re.search(r"[.,!?]", punctuated))


MODELS: dict[str, object] = {}
MODEL_RAM: dict[str, float] = {}
PUNCT: Punctuator | None = None

GIGAAM = "GigaAM-Multilingual Large"
WHISPER = "Whisper large-v3-turbo"


def load_models():
    global PUNCT
    specs = [
        (GIGAAM, GigaAM),
        ("Kazakh Whisper turbo", lambda: Whisper("shyngys879/kazakh-whisper-large-v3-turbo")),
        (WHISPER, lambda: Whisper("openai/whisper-large-v3-turbo")),
    ]
    silence = np.zeros(SR, dtype=np.float32)
    for name, factory in specs:
        before, t = rss_mb(), time.time()
        model = factory()
        model(silence, None)  # прогрев
        MODELS[name] = model
        MODEL_RAM[name] = rss_mb() - before
        print(f"loaded {name}: {time.time() - t:.1f}s, +{MODEL_RAM[name]:.0f} MB RSS", flush=True)
    t = time.time()
    PUNCT = Punctuator()
    PUNCT("прогрев")
    print(f"loaded punctuator: {time.time() - t:.1f}s", flush=True)


def process(data: np.ndarray, reference: str, language: str) -> list[dict]:
    lang = None if language == "auto" else language
    raw = {}
    for name, model in MODELS.items():
        t = time.time()
        raw[name] = (model(data, lang), time.time() - t)

    giga_text, giga_s = raw[GIGAAM]
    whisper_text, whisper_s = raw[WHISPER]
    t = time.time()
    punct_text = PUNCT(giga_text)
    punct_s = time.time() - t

    from_whisper = transfer_punctuation(giga_text, whisper_text)
    use_whisper = whisper_agrees(giga_text, whisper_text)

    rows = [
        (f"GigaAM + гибрид ({'знаки из Whisper' if use_whisper else 'модель пунктуации'})",
         from_whisper if use_whisper else punct_text, max(giga_s, whisper_s) + (0 if use_whisper else punct_s)),
        ("GigaAM + модель пунктуации", punct_text, giga_s + punct_s),
        ("GigaAM + пунктуация из Whisper", from_whisper, max(giga_s, whisper_s)),
        *((name, text, s) for name, (text, s) in raw.items()),
    ]
    return [{
        "model": name,
        "text": text,
        "seconds": round(s, 2),
        "wer": wer(reference, text) if reference else None,
        "cer": cer(reference, text) if reference else None,
    } for name, text, s in rows]


# ---------- метрики ----------

def normalize(text: str) -> list[str]:
    text = text.lower().replace("ё", "е")
    text = re.sub(r"[^\w\s]", " ", text)
    return text.split()


def edit_distance(a: list, b: list) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def wer(ref: str, hyp: str) -> float | None:
    r = normalize(ref)
    return round(100 * edit_distance(r, normalize(hyp)) / len(r), 1) if r else None


def cer(ref: str, hyp: str) -> float | None:
    r = list(" ".join(normalize(ref)))
    return round(100 * edit_distance(r, list(" ".join(normalize(hyp)))) / len(r), 1) if r else None


# ---------- API ----------

app = FastAPI()


@app.on_event("startup")
def startup():
    load_models()


@app.get("/")
def index():
    return FileResponse(ROOT / "index.html")


@app.get("/models")
def models():
    return [{"name": n, "ram_mb": round(MODEL_RAM.get(n, 0))} for n in MODELS]


@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...), reference: str = Form(""), language: str = Form("auto")):
    raw = await audio.read()
    data, sr = sf.read(io.BytesIO(raw), dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    assert sr == SR, f"expected {SR} Hz, got {sr}"

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    wav_path = REC_DIR / f"{stamp}.wav"
    sf.write(wav_path, data, SR)

    results = process(data, reference, language)

    record = {
        "time": stamp, "file": wav_path.name, "duration": round(len(data) / SR, 2),
        "language": language, "reference": reference, "results": results,
    }
    with RESULTS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    return record


@app.get("/history")
def history():
    if not RESULTS.exists():
        return []
    return [json.loads(line) for line in RESULTS.read_text(encoding="utf-8").splitlines() if line.strip()][::-1]


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8765)
