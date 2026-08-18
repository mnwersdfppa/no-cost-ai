#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo "NOTICE=rollback-pi-bridge.sh is a compatibility entrypoint."
exec "$SCRIPT_DIR/rollback-pi-phone-absorber.sh" "$@"
