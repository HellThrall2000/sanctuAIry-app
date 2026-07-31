#!/usr/bin/env bash
# Push a .litertlm model to the connected device.
#
#   ./tool/push_model.sh                       # push every model in assets/.aistudio
#   ./tool/push_model.sh path/to/model.litertlm
#
# Models are ~2.6 GB and are gitignored, so they are never in the APK — the app
# locates them at runtime. See lib/services/model_profile.dart for how a filename
# maps to a profile: keep the downloaded name intact or the app will pick the
# wrong persona and sampler.
#
# Run from Git Bash. MSYS_NO_PATHCONV stops Git Bash rewriting /sdcard/... into a
# Windows path, which silently pushes to the wrong place.
set -euo pipefail
export MSYS_NO_PATHCONV=1

ADB="${ADB:-/c/AndroidSDK/platform-tools/adb.exe}"
PKG="${PKG:-com.example.sanctuary}"
DEST="/storage/emulated/0/Android/data/$PKG/files"
SRC_DIR="$(dirname "$0")/../assets/.aistudio"

if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "No device. Plug it in and enable USB debugging." >&2
  exit 1
fi

if [ $# -gt 0 ]; then
  models=("$@")
else
  shopt -s nullglob
  models=("$SRC_DIR"/*.litertlm)
  shopt -u nullglob
fi

if [ ${#models[@]} -eq 0 ]; then
  echo "No .litertlm files in $SRC_DIR" >&2
  exit 1
fi

# The app's own external files dir needs to exist before a push can land in it;
# it is created on first launch, so make it explicitly for a fresh install.
"$ADB" shell "mkdir -p $DEST" >/dev/null 2>&1 || true

for model in "${models[@]}"; do
  name="$(basename "$model")"
  size="$(stat -c %s "$model" 2>/dev/null || echo '?')"
  echo "Pushing $name ($size bytes) — this takes a few minutes over USB..."
  "$ADB" push "$model" "$DEST/$name"
done

echo
echo "On device:"
"$ADB" shell "ls -la $DEST"
echo
echo "Free space:"
"$ADB" shell df -h /sdcard | tail -1
