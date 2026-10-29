#!/bin/zsh
# Собирает dist/Ait.zip для GitHub Releases.
#
#   AIT_SIGN_IDENTITY="Developer ID Application: Имя Фамилия (TEAMID)" scripts/package-release.sh
#
# Без нотаризации Apple: при первом запуске macOS попросит подтвердить открытие
# (Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»).
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
mkdir -p dist
rm -f dist/Ait.zip
ditto -c -k --sequesterRsrc --keepParent build/Ait.app dist/Ait.zip
echo "dist/Ait.zip  $(du -h dist/Ait.zip | cut -f1)  sha256 $(shasum -a 256 dist/Ait.zip | cut -d' ' -f1)"
