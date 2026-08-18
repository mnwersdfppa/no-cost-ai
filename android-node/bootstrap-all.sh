#!/usr/bin/env bash
set -euo pipefail

SRC="${PHONE_ABSORBER_SOURCE:-$HOME/.openclaw/source/phone-absorber}"
REPO="${PHONE_ABSORBER_REPO:-https://github.com/mnwersdfppa/no-cost-ai.git}"
COMMIT="${PHONE_ABSORBER_COMMIT:-}"
ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"

if [[ ! "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "BLOCKED=IMMUTABLE_PHONE_ABSORBER_COMMIT_REQUIRED"
  echo "NEXT=set PHONE_ABSORBER_COMMIT to the reviewed 40-character Git commit"
  exit 11
fi

mkdir -p "$(dirname "$SRC")"
if [[ -d "$SRC/.git" ]]; then
  if [[ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]]; then
    echo "BLOCKED=PHONE_ABSORBER_SOURCE_HAS_LOCAL_CHANGES"
    exit 12
  fi
  git -C "$SRC" remote set-url origin "$REPO"
else
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init --quiet
  git -C "$SRC" remote add origin "$REPO"
fi

git -C "$SRC" fetch --quiet --depth 1 origin "$COMMIT"
git -C "$SRC" checkout --quiet --detach --force FETCH_HEAD
ACTUAL_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$COMMIT" ]]; then
  echo "BLOCKED=PHONE_ABSORBER_COMMIT_VERIFICATION_FAILED"
  echo "EXPECTED=$COMMIT"
  echo "ACTUAL=$ACTUAL_COMMIT"
  exit 13
fi

cd "$SRC/android-node"
chmod 700 ./*.sh phone-codex-cli-backend/phone-codex-cli-backend.sh

set +e
BRIDGE_OUTPUT="$(INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}" AUTO_TYPE_TERMUX="${AUTO_TYPE_TERMUX:-0}" ./install-pi-bridge-secure.sh 2>&1)"
BRIDGE_STATUS=$?
set -e
printf '%s\n' "$BRIDGE_OUTPUT"

if [[ $BRIDGE_STATUS -ne 0 ]]; then
  if grep -qE 'BLOCKED=(NO_ANDROID_DEVICE|ADB_UNAUTHORIZED)' <<<"$BRIDGE_OUTPUT"; then
    ./pair-openclaw-node.sh || true
    printf '%s\n' \
      'RESULT=OFFICIAL_MOBILE_NODE_PREPARED' \
      'USB_RUNTIME=NOT_READY' \
      'JAILBREAK_ROOT=NOT_REQUIRED' \
      "SOURCE_COMMIT=$ACTUAL_COMMIT" \
      'NEXT=pair the official OpenClaw Android or iOS app with the printed setup code'
    exit 0
  fi
  echo "RESULT=BLOCKED"
  exit "$BRIDGE_STATUS"
fi

if ! openclaw plugins inspect phone-codex-cli --runtime >/dev/null 2>&1; then
  openclaw plugins install -l "$ROOT/phone-codex-cli-backend"
fi
openclaw plugins enable phone-codex-cli || true
openclaw plugins inspect phone-codex-cli --runtime || true

./pair-openclaw-node.sh || true

printf '%s\n' \
  'RESULT=STAGE_1_PREPARED' \
  'JAILBREAK_ROOT=NOT_REQUIRED' \
  "SOURCE_COMMIT=$ACTUAL_COMMIT" \
  'NEXT_PHONE_COMMAND=bash /sdcard/Download/openclaw-phone-bootstrap.sh' \
  "NEXT_PI_COMMAND=RUN_LLM_TEST=1 $SRC/android-node/verify-phone-bridge-secure.sh" \
  "ROLLBACK_COMMAND=$SRC/android-node/rollback-pi-phone-absorber-secure.sh"
