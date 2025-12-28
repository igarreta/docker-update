#!/bin/bash
# validate-inventory.sh
# Quick validation of container inventory without performing updates
#
# This is a convenience wrapper around docker-update.sh --validate-only
#
# Usage:
#   ./validate-inventory.sh                    # Validate all containers
#   ./validate-inventory.sh --container name   # Validate specific container
#   ./validate-inventory.sh --stack /path      # Validate specific stack

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/docker-update.sh" --validate-only "$@"
