#!/bin/zsh
# Собирает build/Ait.app из исходников.
#
#   scripts/build.sh              собрать
#   scripts/build.sh --install    собрать и поставить в /Applications (запущенный Ait перезапустится)
#
# Подпись: по умолчанию ad-hoc. Чтобы macOS не сбрасывала разрешения (микрофон,
# Универсальный доступ) после каждой пересборки, подписывай постоянным сертификатом:
#   AIT_SIGN_IDENTITY="Apple Development: Имя Фамилия (XXXXXXXXXX)" scripts/build.sh --install
# Список сертификатов: security find-identity -v -p codesigning
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${AIT_SIGN_IDENTITY:--}"
APP="build/Ait.app"
DEST="/Applications/Ait.app"

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Ait "$APP/Contents/MacOS/Ait"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/worker.py scripts/install-engine.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/install-engine.sh"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --sign "$IDENTITY" --timestamp "$APP"
fi
codesign --verify --strict "$APP"
echo "собрано: $APP ($(codesign -dvv "$APP" 2>&1 | grep -m1 Authority || echo 'ad-hoc'))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Ait 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  open "$DEST"
  echo "установлено и запущено: $DEST"
fi
