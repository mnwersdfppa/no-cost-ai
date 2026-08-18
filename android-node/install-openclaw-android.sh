#!/usr/bin/env bash
set -euo pipefail

REPO="openclaw/openclaw"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/openclaw-android"
mkdir -p "$CACHE"
chmod 700 "$CACHE"

for cmd in gh sha256sum adb; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "BLOCKED=MISSING_COMMAND:$cmd"; exit 60; }
done

SERIAL="${ANDROID_SERIAL:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
[[ -n "$SERIAL" ]] || { echo "BLOCKED=NO_ANDROID_DEVICE"; exit 61; }
TAG="${OPENCLAW_ANDROID_TAG:-$(gh release view --repo "$REPO" --json tagName --jq .tagName)}"
WORK="$CACHE/$TAG"
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

gh release download "$TAG" --repo "$REPO" \
  --pattern OpenClaw-Android.apk \
  --pattern OpenClaw-Android-SHA256SUMS.txt
sha256sum --check OpenClaw-Android-SHA256SUMS.txt

if gh attestation verify --help >/dev/null 2>&1; then
  gh attestation verify OpenClaw-Android.apk \
    --repo "$REPO" \
    --signer-workflow openclaw/openclaw/.github/workflows/android-release.yml \
    --source-ref "refs/tags/$TAG" \
    --deny-self-hosted-runners
fi

if adb -s "$SERIAL" install -r OpenClaw-Android.apk; then
  echo "RESULT=OPENCLAW_ANDROID_INSTALLED"
  echo "TAG=$TAG"
else
  echo "BLOCKED=ANDROID_INSTALL_FAILED"
  echo "NOTE=Do not auto-uninstall. Existing Play/GitHub signing channels may differ."
  exit 62
fi
