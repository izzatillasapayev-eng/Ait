#!/bin/bash
# Полностью удаляет Ait: приложение, движок с моделями, журнал, настройки и выданные разрешения.
set -uo pipefail

pkill -x Ait 2>/dev/null && sleep 1
rm -rf "/Applications/Ait.app" "$HOME/Library/Application Support/Ait" "$HOME/Library/Logs/Ait"
defaults delete com.izzatilla.ait 2>/dev/null
tccutil reset Microphone com.izzatilla.ait >/dev/null 2>&1
tccutil reset Accessibility com.izzatilla.ait >/dev/null 2>&1
echo "Ait удалён."
