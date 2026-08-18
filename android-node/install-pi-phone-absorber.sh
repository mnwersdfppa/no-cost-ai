#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo "NOTICE=install-pi-phone-absorber.sh is now a compatibility entrypoint."
echo "TARGET=install-pi-bridge.sh"
exec "$SCRIPT_DIR/install-pi-bridge.sh" "$@"
