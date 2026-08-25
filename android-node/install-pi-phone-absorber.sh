#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo "NOTICE=install-pi-phone-absorber.sh is a compatibility entrypoint."
echo "TARGET=bootstrap-all.sh"
exec "$SCRIPT_DIR/bootstrap-all.sh" "$@"
