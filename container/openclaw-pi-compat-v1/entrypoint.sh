#!/bin/sh
set -eu

mode="${OPENCLAW_COMPAT_MODE:-oneshot}"

case "$mode" in
  oneshot)
    exec python3 /app/openclaw_compat.py --once
    ;;
  daemon)
    exec python3 /app/openclaw_compat.py --daemon
    ;;
  self-test)
    exec python3 /app/openclaw_compat.py --self-test
    ;;
  *)
    printf 'ERROR=unsupported_OPENCLAW_COMPAT_MODE\n' >&2
    exit 64
    ;;
esac
