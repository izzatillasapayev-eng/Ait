#!/bin/bash
# Ait — установка движка распознавания речи.
#
# Ставит Python-окружение и модели в ~/Library/Application Support/Ait и больше ничего
# на Mac не трогает: ни системный Python, ни Homebrew, ни PATH.
#
#   install-engine.sh                 обычная модель GigaAM + пунктуация + VAD (~470 MB загрузки)
#   install-engine.sh --model large   дополнительно GigaAM Large (~430 MB)
#   install-engine.sh --all           всё сразу
#
# Повторный запуск безопасен: уже установленное пропускается.
# Строки «AIT_PROGRESS <проценты> <текст>» читает приложение Ait, чтобы показать прогресс.
set -euo pipefail

AIT_HOME="${AIT_HOME:-$HOME/Library/Application Support/Ait}"
MODELS_URL="${AIT_MODELS_URL:-https://github.com/izzatillasapayev-eng/Ait/releases/download/models-v1}"

UV_VERSION="0.13.6"
UV_SHA256="60fbd5c8a1ed681845eea28d9d622fcde03c51e91a43465b64a1e17db1ed3472"
PYTHON_VERSION="3.12"
PACKAGES=(onnx-asr==0.12.0 onnxruntime==1.31.1 numpy==2.5.4 sentencepiece==0.2.2 soundfile==0.14.0 pyyaml==6.0.3)

# архив | sha256 | размер, MB | файл-признак установленной модели | название
MODELS=(
  "gigaam-base|845fc4207e1fc05ba88b1a83ca572f20b85522062361f7fad295bb51274ca0c9|163|multilingual_ctc.int8.onnx.data|GigaAM обычная"
  "punct-int8|3a31b46fce32fcbd78f1305cbb370a2f23467db7b7e6c5e2366811a8f0671433|216|model.onnx.data|пунктуация"
  "silero-vad|d98d60723a0a6f711e7340e14d2a0dd4e30425353dbce12a44cef59c4780a4be|2|silero_vad.onnx|VAD"
  "gigaam-large|dea66059ff1219d90eec55eab60a64b42121058d5033ce22af1a8815d3127cfe|432|multilingual_large_ctc.int8.onnx.data|GigaAM Large"
)

progress() { echo "AIT_PROGRESS $1 $2"; }
fail() { echo "AIT_ERROR $1"; echo "Ошибка: $1" >&2; exit 1; }

case "${1:-}" in
  "") WANT=(gigaam-base punct-int8 silero-vad) ;;
  --model) [[ "${2:-}" == "large" ]] || fail "неизвестная модель: ${2:-}"; WANT=(gigaam-large) ;;
  --all) WANT=(gigaam-base punct-int8 silero-vad gigaam-large) ;;
  *) fail "неизвестный параметр: $1" ;;
esac

[[ "$(uname -m)" == "arm64" ]] || fail "нужен Mac с Apple Silicon (M1 и новее)"
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || fail "нужна macOS 14 Sonoma или новее"

mkdir -p "$AIT_HOME/bin" "$AIT_HOME/models"
TMP="$(mktemp -d)"
cleanup() {
  local pids
  pids="$(jobs -p)"
  [[ -z "$pids" ]] || kill $pids 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Скачивает файл, печатая прогресс: download <url> <куда> <размер MB> <% от> <% до> <подпись>
download() {
  curl -fsSL --retry 3 -o "$2" "$1" &
  local pid=$! have pct
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    have=$(( $(stat -f %z "$2" 2>/dev/null || echo 0) / 1000000 ))
    pct=$(( $4 + ($5 - $4) * have / ($3 > 0 ? $3 : 1) ))
    (( pct > $5 )) && pct=$5
    progress "$pct" "$6 — $have из $3 MB"
  done
  wait "$pid" || fail "не удалось скачать $1 — проверь интернет и запусти установку ещё раз"
}

verify() {  # verify <файл> <sha256>
  echo "$2  $1" | shasum -a 256 -c --status || fail "контрольная сумма $(basename "$1") не совпала — файл повреждён"
}

# 1. uv — менеджер Python от Astral, ставится только в папку Ait
UV="$AIT_HOME/bin/uv"
if [[ "$("$UV" --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]]; then
  progress 2 "Скачиваю uv $UV_VERSION"
  download "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz" "$TMP/uv.tar.gz" 20 2 6 "Скачиваю uv"
  verify "$TMP/uv.tar.gz" "$UV_SHA256"
  tar -xzf "$TMP/uv.tar.gz" -C "$TMP"
  cp "$TMP/uv-aarch64-apple-darwin/uv" "$UV"
fi

# 2. Python и библиотеки распознавания (без PyTorch, ~130 MB)
export UV_PYTHON_INSTALL_DIR="$AIT_HOME/uv-python" UV_CACHE_DIR="$TMP/uv-cache"
export UV_PYTHON_PREFERENCE=only-managed UV_NO_CONFIG=1  # только нативный arm64-Python, не Homebrew
PY="$AIT_HOME/python/bin/python3"
if ! "$PY" -c "import onnx_asr, onnxruntime, sentencepiece, soundfile, yaml" 2>/dev/null; then
  progress 8 "Устанавливаю Python $PYTHON_VERSION"
  "$UV" venv --quiet --allow-existing --python "$PYTHON_VERSION" "$AIT_HOME/python"
  progress 18 "Устанавливаю библиотеки распознавания"
  "$UV" pip install --quiet --python "$PY" "${PACKAGES[@]}"
  "$PY" -c "import onnx_asr, onnxruntime, sentencepiece, soundfile, yaml" || fail "библиотеки не установились"
fi

# 3. Модели — с GitHub-релиза models-v1, каждая проверяется по sha256
total=0
for entry in "${MODELS[@]}"; do
  IFS='|' read -r name sha size file title <<< "$entry"
  [[ " ${WANT[*]} " == *" $name "* && ! -f "$AIT_HOME/models/$name/$file" ]] && total=$(( total + size ))
done
done_mb=0
for entry in "${MODELS[@]}"; do
  IFS='|' read -r name sha size file title <<< "$entry"
  [[ " ${WANT[*]} " == *" $name "* ]] || continue
  [[ -f "$AIT_HOME/models/$name/$file" ]] && continue
  from=$(( 30 + 68 * done_mb / total )); to=$(( 30 + 68 * (done_mb + size) / total ))
  download "$MODELS_URL/$name.zip" "$TMP/$name.zip" "$size" "$from" "$to" "Скачиваю модель: $title"
  verify "$TMP/$name.zip" "$sha"
  rm -rf "$TMP/unpacked" && mkdir "$TMP/unpacked"
  ditto -x -k "$TMP/$name.zip" "$TMP/unpacked"
  rm -rf "$AIT_HOME/models/$name"
  mv "$TMP/unpacked/$name" "$AIT_HOME/models/$name"
  rm -f "$TMP/$name.zip"
  done_mb=$(( done_mb + size ))
done

progress 100 "Движок установлен"
echo "Движок Ait установлен в: $AIT_HOME"
