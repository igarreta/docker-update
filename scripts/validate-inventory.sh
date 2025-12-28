#!/bin/bash
# validate-inventory.sh
# Quick validation of container inventory without performing updates
#
# This is a convenience wrapper around docker-update.sh --validate-only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/docker-update.sh" --validate-only "$@"
