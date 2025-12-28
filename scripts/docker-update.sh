#!/bin/bash
# ~/scripts/docker-update.sh
# Monthly Docker container update with inventory validation

set -e

# === CONFIGURATION ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INVENTORY_FILE="$HOME/etc/docker-inventory"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d-%H%M).log"
COMPOSE_BASE="/path/to/your/compose/files"  # Adjust this

# === COLOR OUTPUT ===
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === FUNCTIONS ===
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

warn() {
    log "${YELLOW}⚠ WARNING: $1${NC}"
}

error() {
    log "${RED}✗ ERROR: $1${NC}"
}

success() {
    log "${GREEN}✓ $1${NC}"
}

info() {
    log "${BLUE}ℹ $1${NC}"
}

# === HELPER FUNCTIONS ===
detect_stack_type() {
    local stack_path="$1"

    # Check if directory exists
    if [[ ! -d "$stack_path" ]]; then
        echo "pull"  # Default to pull if directory doesn't exist
        return
    fi

    # Check for Dockerfile
    if [[ -f "$stack_path/Dockerfile" ]]; then
        echo "build"
        return
    fi

    # Check docker-compose.yml for build: section
    local compose_file=""
    if [[ -f "$stack_path/docker-compose.yml" ]]; then
        compose_file="$stack_path/docker-compose.yml"
    elif [[ -f "$stack_path/docker-compose.yaml" ]]; then
        compose_file="$stack_path/docker-compose.yaml"
    elif [[ -f "$stack_path/compose.yml" ]]; then
        compose_file="$stack_path/compose.yml"
    elif [[ -f "$stack_path/compose.yaml" ]]; then
        compose_file="$stack_path/compose.yaml"
    fi

    if [[ -n "$compose_file" ]] && grep -q "^\s*build:" "$compose_file"; then
        echo "build"
        return
    fi

    # Default to pull
    echo "pull"
}

# === INITIALIZATION ===
mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$INVENTORY_FILE")"

# === INVENTORY FILE FORMAT ===
# Create if doesn't exist with example format
if [[ ! -f "$INVENTORY_FILE" ]]; then
    cat > "$INVENTORY_FILE" << 'EOF'
# Docker Container Inventory
# Format: container_name|stack_path|notes
# (type field is optional - auto-detected from Dockerfile/docker-compose.yml)
#
# Alternative format with explicit type:
# Format: container_name|stack_path|type|notes
# type: pull (pre-built image) or build (Dockerfile)
#
# Example:
# homeassistant|/opt/stacks/homeassistant|Home automation
# custom-app|/opt/stacks/custom-app|Custom built from Dockerfile
# nginx-proxy|/opt/stacks/proxy|pull|Reverse proxy (explicit type)
#
# Add your containers below:
EOF
    error "Inventory file created at $INVENTORY_FILE"
    error "Please populate it before running updates."
    exit 1
fi

# === LOAD INVENTORY ===
declare -A INVENTORY_STACKS
declare -A INVENTORY_TYPES
INVENTORY_CONTAINERS=()

while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue

    # Count the number of pipe separators to determine format
    pipe_count=$(echo "$line" | tr -cd '|' | wc -c)

    if [[ $pipe_count -eq 2 ]]; then
        # 3-field format: container_name|stack_path|notes
        IFS='|' read -r name stack notes <<< "$line"
        type=""  # Will be auto-detected
    elif [[ $pipe_count -eq 3 ]]; then
        # 4-field format: container_name|stack_path|type|notes
        IFS='|' read -r name stack type notes <<< "$line"
    else
        warn "Invalid inventory line (expected 2 or 3 pipes): $line"
        continue
    fi

    # Trim whitespace
    name=$(echo "$name" | xargs)
    stack=$(echo "$stack" | xargs)
    type=$(echo "$type" | xargs)

    # Auto-detect type if not specified
    if [[ -z "$type" ]]; then
        type=$(detect_stack_type "$stack")
    fi

    INVENTORY_CONTAINERS+=("$name")
    INVENTORY_STACKS["$name"]="$stack"
    INVENTORY_TYPES["$name"]="$type"
done < "$INVENTORY_FILE"

# === VALIDATION ===
log "========================================"
log "Docker Update - $(date)"
log "========================================"
log ""
info "Validating container inventory..."
log ""

# Get currently running containers
RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' | sort)
WARNINGS=0
ERRORS=0

# Check 1: Containers in inventory but NOT running
log "--- Checking inventory containers ---"
for container in "${INVENTORY_CONTAINERS[@]}"; do
    if echo "$RUNNING_CONTAINERS" | grep -q "^${container}$"; then
        success "$container: in inventory and running"
    else
        warn "$container: in inventory but NOT running"
        ((WARNINGS++))
    fi
done

log ""

# Check 2: Running containers NOT in inventory
log "--- Checking for untracked containers ---"
while IFS= read -r running; do
    [[ -z "$running" ]] && continue
    
    found=0
    for inv in "${INVENTORY_CONTAINERS[@]}"; do
        if [[ "$inv" == "$running" ]]; then
            found=1
            break
        fi
    done
    
    if [[ $found -eq 0 ]]; then
        warn "$running: running but NOT in inventory"
        ((WARNINGS++))
    fi
done <<< "$RUNNING_CONTAINERS"

log ""
log "========================================"
log "Validation Summary: $WARNINGS warnings, $ERRORS errors"
log "========================================"
log ""

# === PROMPT TO CONTINUE ===
if [[ $WARNINGS -gt 0 ]]; then
    warn "There are discrepancies between inventory and running state."
    read -p "Continue with update anyway? (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Update cancelled by user."
        exit 0
    fi
fi

# === UPDATE PROCESS ===
log ""
info "Starting update process..."
log ""

# Group containers by stack for efficient updates
declare -A STACKS_TO_UPDATE
for container in "${INVENTORY_CONTAINERS[@]}"; do
    # Only update if container is running
    if echo "$RUNNING_CONTAINERS" | grep -q "^${container}$"; then
        stack="${INVENTORY_STACKS[$container]}"
        type="${INVENTORY_TYPES[$container]}"
        # Mark stack for update (avoid duplicates if multiple containers per stack)
        STACKS_TO_UPDATE["$stack"]="$type"
    fi
done

# Update each stack
for stack in "${!STACKS_TO_UPDATE[@]}"; do
    type="${STACKS_TO_UPDATE[$stack]}"
    
    log "----------------------------------------"
    info "Updating stack: $stack (type: $type)"
    log "----------------------------------------"
    
    if [[ ! -d "$stack" ]]; then
        error "Stack directory not found: $stack"
        ((ERRORS++))
        continue
    fi
    
    cd "$stack"
    
    if [[ "$type" == "build" ]]; then
        # Dockerfile-based stack
        info "Rebuilding from Dockerfile (pulling fresh base images)..."
        if docker compose build --pull 2>&1 | tee -a "$LOG_FILE"; then
            info "Recreating containers..."
            docker compose up -d --build 2>&1 | tee -a "$LOG_FILE"
            success "Stack updated successfully"
        else
            error "Build failed for $stack"
            ((ERRORS++))
        fi
    else
        # Pre-built image stack
        info "Pulling latest images..."
        if docker compose pull 2>&1 | tee -a "$LOG_FILE"; then
            info "Recreating containers..."
            docker compose up -d 2>&1 | tee -a "$LOG_FILE"
            success "Stack updated successfully"
        else
            error "Pull failed for $stack"
            ((ERRORS++))
        fi
    fi
    
    # Brief pause between stacks
    sleep 2
done

# === POST-UPDATE VERIFICATION ===
log ""
log "========================================"
info "Post-update verification"
log "========================================"

sleep 5  # Give containers time to stabilize

FAILED_CONTAINERS=()
for container in "${INVENTORY_CONTAINERS[@]}"; do
    status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
    if [[ "$status" == "running" ]]; then
        success "$container: running"
    else
        error "$container: status=$status"
        FAILED_CONTAINERS+=("$container")
        ((ERRORS++))
    fi
done

# === CLEANUP ===
log ""
info "Cleaning up old images..."
docker image prune -f 2>&1 | tee -a "$LOG_FILE"

# === FINAL SUMMARY ===
log ""
log "========================================"
log "UPDATE COMPLETE - $(date)"
log "========================================"
log "Warnings: $WARNINGS"
log "Errors: $ERRORS"

if [[ ${#FAILED_CONTAINERS[@]} -gt 0 ]]; then
    error "Failed containers: ${FAILED_CONTAINERS[*]}"
    log "Check logs: $LOG_FILE"
    exit 1
fi

if [[ $ERRORS -eq 0 ]]; then
    success "All updates completed successfully!"
else
    warn "Completed with $ERRORS errors. Review log: $LOG_FILE"
fi
