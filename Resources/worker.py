"""Ait — движок распознавания речи.

Приложение запускает этот процесс и общается с ним строками JSON через stdin/stdout:
  → {"id": 1, "cmd": "load", "model": "base"|"large", "punct": true}
  → {"id": 2, "cmd": "transcribe", "path": "/tmp/x.wav", "model": "base", "punct": false}
  ← {"id": 2, "event": "text", "text": "...", "seconds": 0.21}
Модели лежат в ~/Library/Application Support/Ait/models.
"""

import json
import os
import re
import sys
import time
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import numpy as np
import soundfile as sf

HOME = Path(os.environ.get("AIT_HOME", Path.home() / "Library/Application Support/Ait"))
MODELS = HOME / "models"
CPU = ["CPUExecutionProvider"]
GIGAAM = {
    "base": ("gigaam-multilingual-ctc", "gigaam-base"),
    "large": ("gigaam-multilingual-large-ctc", "gigaam-large"),
}
VAD_AFTER_SECONDS = 20  # длинные записи режем по паузам, модель берёт до ~20–30 с за раз


class Punctuator:
    """Пунктуация и заглавные буквы: xlm-roberta_punctuation_fullstop_truecase (47 языков, int8)."""

    OVERLAP = 16

    def __init__(self, folder: Path):
        import onnxruntime as ort
        import yaml
        from sentencepiece import SentencePieceProcessor

        cfg = yaml.safe_load((folder / "config.yaml").read_text())
        self.sp = SentencePieceProcessor(str(folder / "sp.model"))
        self.session = ort.InferenceSession(str(folder / "model.onnx"), providers=CPU)
        self.window = cfg["max_length"] - 2
        self.pre_labels = cfg["pre_labels"]
        self.post_labels = cfg["post_labels"]
        self.null = cfg.get("null_token", "<NULL>")

    def __call__(self, text: str) -> str:
        ids = self.sp.EncodeAsIds(text)
        windows, start = [], 0
        while start < len(ids):
            begin = start - (self.OVERLAP if windows else 0)
            windows.append(ids[begin:begin + self.window])
            start = begin + self.window

        tokens = []  # (piece, pre, post, cap)
        for n, window in enumerate(windows):
            batch = np.array([[self.sp.bos_id(), *window, self.sp.eos_id()]], dtype=np.int64)
            pre, post, cap, _ = self.session.run(None, {"input_ids": batch})
            first = self.OVERLAP // 2 if n > 0 else 0
            last = len(window) - (self.OVERLAP // 2 if n < len(windows) - 1 else 0)
            for k in range(first, last):
                tokens.append((self.sp.IdToPiece(window[k]), self.pre_labels[pre[0, k + 1]],
                               self.post_labels[post[0, k + 1]], cap[0, k + 1]))

        out = []
        for piece, pre, post, cap in tokens:
            if piece.startswith("▁") and out:
                out.append(" ")
            first = 1 if piece.startswith("▁") else 0
            for i in range(first, len(piece)):
                if i == first and pre != self.null:
                    out.append(pre)
                out.append(piece[i].upper() if i < len(cap) and cap[i] else piece[i])
                if post == "<ACRONYM>":
                    out.append(".")
                elif i == len(piece) - 1 and post != self.null:
                    out.append(post)
        text = "".join(out)
        text = re.sub(r"(?<=[^.!?…]\s)Я\b", "я", text)  # «я» посреди предложения
        return re.sub(r"[,;:]+$", "", text)


class Engine:
    def __init__(self):
        self.size = None
        self.asr = None
        self.punct = None
        self.vad = None

    def load_asr(self, size: str):
        if self.size != size:
            import onnx_asr
            name, folder = GIGAAM[size]
            self.asr = None  # освобождаем прежнюю модель до загрузки новой
            self.asr = onnx_asr.load_model(name, MODELS / folder, quantization="int8", providers=CPU)
            self.size = size
        return self.asr

    def load_punct(self) -> Punctuator:
        if self.punct is None:
            self.punct = Punctuator(MODELS / "punct-int8")
        return self.punct

    def load_vad(self):
        if self.vad is None:
            import onnx_asr
            self.vad = onnx_asr.load_vad("silero", MODELS / "silero-vad", providers=CPU)
        return self.vad

    def transcribe(self, path: str, size: str, punct: bool) -> str:
        audio, sr = sf.read(path, dtype="float32")
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        asr = self.load_asr(size)
        if len(audio) / sr > VAD_AFTER_SECONDS:
            segments = asr.with_vad(self.load_vad()).recognize(audio, sample_rate=sr)
            text = " ".join(s.text.strip() for s in segments if s.text.strip())
        else:
            text = asr.recognize(audio, sample_rate=sr).strip()
        if punct and text:
            text = self.load_punct()(text)
        return text


def send(**msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    engine = Engine()
    send(event="ready")
    for line in sys.stdin:
        if not line.strip():
            continue
        req = {}
        try:
            req = json.loads(line)
            started = time.time()
            if req["cmd"] == "load":
                engine.load_asr(req["model"])
                if req.get("punct"):
                    engine.load_punct()
                send(id=req.get("id"), event="loaded", seconds=round(time.time() - started, 2))
            elif req["cmd"] == "transcribe":
                text = engine.transcribe(req["path"], req["model"], req.get("punct", False))
                send(id=req.get("id"), event="text", text=text, seconds=round(time.time() - started, 2))
            elif req["cmd"] == "quit":
                break
        except Exception as e:  # ошибку отдаём приложению, процесс продолжает работать
            send(id=req.get("id"), event="error", message=f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
