#!/usr/bin/env bash
# Облегчённые APK под тип процессора — чтобы Telegram-бот мог прислать файл (лимит бота 50 МБ).
# Берёт подписанный универсальный APK, убирает библиотеки других архитектур и подписывает
# ТЕМ ЖЕ ключом. versionCode не меняется, поэтому обновления «облегчённый ⇄ полный» ставятся поверх.
#
#   slim_apk.sh <app-release.apk> <папка-вывода> <keystore.jks>
#   Пароли: KS_PASS, KEY_ALIAS, KEY_PASS (из секретов CI).
set -euo pipefail
SRC="$1"; OUT="$2"; KS="$3"
mkdir -p "$OUT"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
[ -x "$BT/apksigner" ] || { echo "apksigner не найден в $SDK"; exit 1; }
for abi in arm64-v8a armeabi-v7a; do
  tmp="$OUT/tmp-$abi.apk"; final="$OUT/app-$abi-release.apk"
  cp "$SRC" "$tmp"
  for other in $(unzip -Z1 "$tmp" | awk -F/ '/^lib\//{print $2}' | sort -u); do
    [ "$other" = "$abi" ] || zip -q -d "$tmp" "lib/$other/*"
  done
  # старая подпись v1 больше не соответствует содержимому — apksigner создаст новую
  zip -q -d "$tmp" 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.EC' 'META-INF/*.DSA' 'META-INF/MANIFEST.MF' >/dev/null 2>&1 || true
  rm -f "$final"
  "$BT/zipalign" -p -f 4 "$tmp" "$final"
  "$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$KS_PASS" --ks-key-alias "$KEY_ALIAS" --key-pass "pass:$KEY_PASS" "$final"
  "$BT/apksigner" verify "$final"
  rm -f "$tmp"
  size=$(stat -c %s "$final")
  echo "$abi: $((size / 1048576)) МБ"
  [ "$size" -lt $((49 * 1048576)) ] || echo "::warning::$abi APK больше 49 МБ — бот не сможет прислать его сам"
done
